-- RGPD B3 — effacement complet d'un expert (art. 17).
-- Les deux chemins de suppression (par l'expert lui-même, par le superviseur) appellent désormais
-- une fonction commune, expert_erase, qui :
--  · conserve la fiche experts (id) pour que l'historique des mandats reste cohérent, mais en vide
--    toutes les données personnelles (pseudonymisation : « Expert supprimé ») ;
--  · supprime les données rattachées sans valeur d'historique (listes, KPI, performances, verrous,
--    notifications, sessions, favoris) ;
--  · anonymise le compte de connexion (auth.users) : e-mail factice, téléphone et métadonnées vidés,
--    identités et sessions supprimées, compte banni ;
--  · met en file la suppression de la photo stockée (traitée par l'edge function purge-storage,
--    car Supabase interdit d'effacer un fichier de stockage directement en SQL).
-- Conservé : mandats, rapports et photos de logement (données de l'assureur, durée de conservation
-- propre), temps de trajet agrégés sur les mandats, journal d'activité (sans le nom).

create table if not exists public.storage_purge_queue (
  id bigint generated always as identity primary key,
  bucket text not null,
  path text not null,
  reason text,
  requested_at timestamptz not null default now(),
  done_at timestamptz,
  error text
);
alter table public.storage_purge_queue enable row level security;  -- aucune politique : service uniquement
comment on table public.storage_purge_queue is 'Fichiers de stockage à supprimer (traités par l''edge function purge-storage).';

-- Met en file un fichier de nos buckets à partir de son URL publique ou signée, s'il n'est plus utilisé ailleurs.
create or replace function public.storage_queue_url(p_url text, p_reason text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_bucket text; v_path text;
begin
  if p_url is null then return; end if;
  select m[1], m[2] into v_bucket, v_path
    from regexp_matches(p_url, '/storage/v1/object/(?:public|sign|authenticated)/([^/]+)/([^?]+)') m;
  if v_bucket is null then return; end if;                       -- fichier externe : rien à faire
  v_path := replace(replace(v_path, '%20', ' '), '%28', '(');
  v_path := replace(v_path, '%29', ')');
  if exists (select 1 from experts where photo_url = p_url)
     or exists (select 1 from insurers where logo_url = p_url) then
    return;                                                       -- encore utilisé ailleurs : on garde
  end if;
  insert into storage_purge_queue (bucket, path, reason) values (v_bucket, v_path, p_reason);
end $$;

create or replace function public.expert_erase(p_expert uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_user uuid; v_photo text;
begin
  select user_id, photo_url into v_user, v_photo from experts where id = p_expert;
  if not found then raise exception 'Expert introuvable'; end if;

  -- Données rattachées sans valeur d'historique
  delete from expert_list_members where expert_id = p_expert;
  delete from expert_profile_assignments where expert_id = p_expert;
  delete from org_experts where expert_id = p_expert;
  delete from expert_fiche_locks where expert_id = p_expert;
  delete from expert_kpis where expert_id = p_expert;
  delete from expert_performance_logs where expert_id = p_expert;

  -- Fiche expert pseudonymisée (l'id reste pour l'historique des mandats)
  update experts set first_name = 'Expert', last_name = 'supprimé', civility = null,
         company_name = 'Expert supprimé', trade_name = null, siret = null, specialty = null, coverage_zone = null,
         phone = null, phone_2 = null, email = null, photo_url = null,
         address_line_1 = null, address_line_2 = null, postal_code = null, city = null, country = null,
         latitude = null, longitude = null, geocoded_at = null, geocode_error = null,
         rating = null, agreements = '{}', contract_type = null,
         suspension_reason = null, status_experts = 'suspendu', updated_at = now()
   where id = p_expert;
  perform storage_queue_url(v_photo, 'expert_erase');

  if v_user is not null then
    delete from notifications where user_id = v_user;
    delete from user_sessions where user_id = v_user;
    delete from kpi_favorites where user_id = v_user;
    delete from mandate_locks where user_id = v_user;
    delete from expert_fiche_locks where user_id = v_user;
    update user_profiles set first_name = 'Expert', last_name = 'supprimé', email = null, phone = null,
           account_status = 'banned', presence_status = null, availability_status = null,
           dashboard_card_order = null, removed_at = coalesce(removed_at, now()), updated_at = now()
     where id = v_user;
    -- Compte de connexion : plus d'e-mail réel, plus de moyen de se connecter
    delete from auth.identities where user_id = v_user;
    delete from auth.sessions where user_id = v_user;
    delete from auth.refresh_tokens where user_id = v_user::text;
    delete from auth.mfa_factors where user_id = v_user;
    update auth.users set email = 'supprime-' || id || '@plomi.invalid', phone = null,
           encrypted_password = '', raw_user_meta_data = '{}'::jsonb,
           banned_until = 'infinity', updated_at = now()
     where id = v_user;
  end if;

  return jsonb_build_object('expert_id', p_expert, 'user_id', v_user, 'photo_queued', v_photo is not null);
end $$;

revoke execute on function public.expert_erase(uuid) from public, anon, authenticated;
revoke execute on function public.storage_queue_url(text, text) from public, anon, authenticated;

-- Suppression par l'expert lui-même
create or replace function public.expert_delete_profile()
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_expert uuid := public.current_expert_id(); v_user uuid := auth.uid();
begin
  if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  if exists (select 1 from public.mandates where assigned_expert_id = v_expert and status in ('assigned','in_progress','planning')) then
    raise exception 'Terminez ou abandonnez vos mandats en cours avant de supprimer votre profil';
  end if;
  perform public.expert_erase(v_expert);
  insert into public.activity_logs (user_id, entity_type, entity_id, action, new_values_json)
  values (v_user, 'user', v_user, 'profile_deleted', jsonb_build_object('expert_id', v_expert));
end $$;

-- Suppression par le superviseur (le journal ne garde plus le nom de l'expert)
create or replace function public.supervisor_delete_expert(p_expert_id uuid, p_motif text)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare v_org uuid; v_user uuid;
begin
  if not public.is_supervisor() then raise exception 'Accès réservé au superviseur' using errcode = '42501'; end if;
  select organization_id into v_org from user_profiles where id = auth.uid();
  if not exists (select 1 from org_experts where expert_id = p_expert_id and organization_id = v_org) then
    raise exception 'Expert introuvable dans votre base';
  end if;
  if exists (select 1 from mandates where assigned_expert_id = p_expert_id and status::text in ('assigned', 'in_progress', 'waiting_report')) then
    raise exception 'Cet expert a des mandats attribués ou en cours : réattribuez-les avant de le supprimer';
  end if;
  select user_id into v_user from experts where id = p_expert_id;
  perform public.expert_erase(p_expert_id);
  insert into activity_logs (user_id, organization_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), v_org, 'user', coalesce(v_user, p_expert_id), 'expert_deleted',
          jsonb_build_object('expert_id', p_expert_id, 'motif', nullif(trim(coalesce(p_motif, '')), '')));
  return v_user;
end $$;

-- File de suppression de fichiers : lecture et acquittement par l'edge function (jeton Vault)
create or replace function public.storage_purge_pending(p_token text, p_limit int default 50)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_token is distinct from (select decrypted_secret from vault.decrypted_secrets where name = 'travel_cron_token') then
    raise exception 'Jeton invalide';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'bucket', bucket, 'path', path) order by id)
                     from (select * from storage_purge_queue where done_at is null and error is null order by id limit p_limit) q), '[]');
end $$;

create or replace function public.storage_purge_done(p_token text, p_id bigint, p_error text default null)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_token is distinct from (select decrypted_secret from vault.decrypted_secrets where name = 'travel_cron_token') then
    raise exception 'Jeton invalide';
  end if;
  update storage_purge_queue set done_at = case when p_error is null then now() end, error = p_error where id = p_id;
end $$;

revoke execute on function public.storage_purge_pending(text, int) from public, anon, authenticated;
revoke execute on function public.storage_purge_done(text, bigint, text) from public, anon, authenticated;
grant execute on function public.storage_purge_pending(text, int) to service_role;
grant execute on function public.storage_purge_done(text, bigint, text) to service_role;

-- Passage toutes les heures
select cron.schedule('purge_storage', '41 * * * *', $$
  select net.http_post(
    url := 'https://ybbzfedbdjgcahqajltm.supabase.co/functions/v1/purge-storage',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := jsonb_build_object('token', (select decrypted_secret from vault.decrypted_secrets where name = 'travel_cron_token')),
    timeout_milliseconds := 60000)
$$);
