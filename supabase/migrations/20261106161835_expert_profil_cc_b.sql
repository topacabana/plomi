alter table public.experts add column if not exists civility text, add column if not exists phone_2 text;
alter table public.experts drop constraint if exists experts_civility_check;
alter table public.experts add constraint experts_civility_check check (civility is null or civility in ('M.','Mme'));

create or replace function public.expert_profile_data()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_expert uuid := public.current_expert_id(); e public.experts%rowtype; s record;
        v_cre numeric; v_axes jsonb := '[]'::jsonb;
begin
  if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  select * into e from public.experts where id = v_expert;
  select * into s from public.plo_expert_scores() p where p.expert_id = v_expert;
  select round(100.0 * count(*) filter (where m.arrived_at <= coalesce(m.selected_slot_at, m.slot_1_at) + interval '15 minutes') / nullif(count(*),0))
    into v_cre
    from public.mandates m
   where m.assigned_expert_id = v_expert and m.arrived_at is not null and coalesce(m.selected_slot_at, m.slot_1_at) is not null;

  if s.precision_score is not null and s.precision_score < 50 then
    v_axes := v_axes || jsonb_build_array('Précision : ajoutez plus de photos par pièce et détaillez commentaires et conclusions.'); end if;
  if s.reactivite_score is not null and s.reactivite_score < 50 then
    v_axes := v_axes || jsonb_build_array('Réactivité : positionnez-vous plus rapidement sur les nouveaux mandats.'); end if;
  if s.rapidite_score is not null and s.rapidite_score < 50 then
    v_axes := v_axes || jsonb_build_array('Rapidité : réduisez le délai entre le lancement de l''intervention et l''envoi du rapport.'); end if;
  if v_cre is not null and v_cre < 50 then
    v_axes := v_axes || jsonb_build_array('Respect des créneaux : arrivez au plus tard 15 minutes après le créneau prévu.'); end if;

  return jsonb_build_object(
    'civility', e.civility, 'first_name', e.first_name, 'last_name', e.last_name,
    'company_name', e.company_name, 'address_line_1', e.address_line_1, 'address_line_2', e.address_line_2,
    'postal_code', e.postal_code, 'city', e.city,
    'address', concat_ws(', ', e.address_line_1, e.address_line_2, concat_ws(' ', e.postal_code, e.city)),
    'phone', e.phone, 'phone_2', e.phone_2,
    'email', coalesce((select email from auth.users where id = auth.uid()), e.email),
    'photo_url', e.photo_url,
    'rapidite', s.rapidite_score, 'reactivite', s.reactivite_score, 'precision', s.precision_score, 'respect_creneaux', v_cre,
    'axes', v_axes,
    'nb_telechargements', (select count(*) from public.activity_logs where user_id = auth.uid() and action = 'stats_report_downloaded'),
    'nb_modifications', (select count(*) from public.activity_logs where user_id = auth.uid() and action = 'profile_updated'));
end $$;

create or replace function public.log_expert_profile_event(p_action text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.current_expert_id() is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  if p_action not in ('stats_report_downloaded') then raise exception 'Action inconnue'; end if;
  insert into public.activity_logs (user_id, entity_type, entity_id, action) values (auth.uid(), 'user', auth.uid(), p_action);
end $$;

create or replace function public.expert_update_profile(p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_expert uuid := public.current_expert_id(); v_old jsonb; v_new jsonb;
        f text; v text;
begin
  if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  foreach f in array array['first_name','last_name','company_name','address_line_1','postal_code','city','phone'] loop
    if p_data ? f and nullif(trim(coalesce(p_data->>f,'')),'') is null then
      raise exception 'Champ obligatoire manquant : %', f; end if;
  end loop;
  if p_data ? 'civility' and nullif(p_data->>'civility','') is not null and p_data->>'civility' not in ('M.','Mme') then
    raise exception 'Civilité invalide'; end if;
  if p_data ? 'postal_code' and (p_data->>'postal_code') !~ '^[0-9]{5}$' then raise exception 'Code postal invalide (5 chiffres)'; end if;
  foreach f in array array['phone','phone_2'] loop
    v := regexp_replace(coalesce(p_data->>f,''), '[^0-9+]', '', 'g');
    if p_data ? f and v <> '' and v !~ '^(\+33|0)[1-9][0-9]{8}$' then raise exception 'Numéro de téléphone invalide : %', p_data->>f; end if;
  end loop;

  select to_jsonb(x) into v_old from (select civility, first_name, last_name, company_name, address_line_1, address_line_2, postal_code, city, phone, phone_2 from public.experts where id = v_expert) x;

  update public.experts set
    civility       = case when p_data ? 'civility' then nullif(p_data->>'civility','') else civility end,
    first_name     = case when p_data ? 'first_name' then trim(p_data->>'first_name') else first_name end,
    last_name      = case when p_data ? 'last_name' then trim(p_data->>'last_name') else last_name end,
    company_name   = case when p_data ? 'company_name' then trim(p_data->>'company_name') else company_name end,
    address_line_1 = case when p_data ? 'address_line_1' then trim(p_data->>'address_line_1') else address_line_1 end,
    address_line_2 = case when p_data ? 'address_line_2' then nullif(trim(p_data->>'address_line_2'),'') else address_line_2 end,
    postal_code    = case when p_data ? 'postal_code' then p_data->>'postal_code' else postal_code end,
    city           = case when p_data ? 'city' then trim(p_data->>'city') else city end,
    phone          = case when p_data ? 'phone' then trim(p_data->>'phone') else phone end,
    phone_2        = case when p_data ? 'phone_2' then nullif(trim(p_data->>'phone_2'),'') else phone_2 end,
    updated_at = now()
  where id = v_expert;

  update public.user_profiles set
    first_name = coalesce(nullif(trim(p_data->>'first_name'),''), first_name),
    last_name  = coalesce(nullif(trim(p_data->>'last_name'),''), last_name),
    phone      = coalesce(nullif(trim(p_data->>'phone'),''), phone),
    updated_at = now()
  where id = auth.uid();

  select to_jsonb(x) into v_new from (select civility, first_name, last_name, company_name, address_line_1, address_line_2, postal_code, city, phone, phone_2 from public.experts where id = v_expert) x;
  if v_new is distinct from v_old then
    insert into public.activity_logs (user_id, entity_type, entity_id, action, old_values_json, new_values_json)
    values (auth.uid(), 'user', auth.uid(), 'profile_updated', v_old, v_new);
  end if;
  return v_new;
end $$;

create or replace function public.expert_delete_profile()
returns void language plpgsql security definer set search_path = public as $$
declare v_expert uuid := public.current_expert_id();
begin
  if v_expert is null then raise exception 'Aucun profil expert trouvé pour cet utilisateur'; end if;
  if exists (select 1 from public.mandates where assigned_expert_id = v_expert and status in ('assigned','in_progress','planning')) then
    raise exception 'Terminez ou abandonnez vos mandats en cours avant de supprimer votre profil';
  end if;
  delete from public.expert_list_members where expert_id = v_expert;
  delete from public.expert_profile_assignments where expert_id = v_expert;
  delete from public.org_experts where expert_id = v_expert;
  delete from public.expert_fiche_locks where expert_id = v_expert;
  delete from public.expert_kpis where expert_id = v_expert;
  delete from public.expert_performance_logs where expert_id = v_expert;
  update public.experts set first_name = 'Expert', last_name = 'supprimé', civility = null, phone = null, phone_2 = null,
         email = null, photo_url = null, address_line_1 = null, address_line_2 = null, siret = null, trade_name = null,
         latitude = null, longitude = null, rating = null, status_experts = 'suspendu', updated_at = now()
   where id = v_expert;
  update public.user_profiles set first_name = 'Expert', last_name = 'supprimé', phone = null,
         account_status = 'banned', updated_at = now()
   where id = auth.uid();
  insert into public.activity_logs (user_id, entity_type, entity_id, action) values (auth.uid(), 'user', auth.uid(), 'profile_deleted');
end $$;

create or replace function public.sync_user_email()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.email is distinct from old.email then
    update public.user_profiles set email = new.email, updated_at = now() where id = new.id;
    update public.experts set email = new.email, updated_at = now() where user_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists on_auth_email_change on auth.users;
create trigger on_auth_email_change after update of email on auth.users
  for each row execute function public.sync_user_email();

revoke all on function public.expert_profile_data(), public.log_expert_profile_event(text), public.expert_update_profile(jsonb),
  public.expert_delete_profile(), public.sync_user_email() from public, anon;
grant execute on function public.expert_profile_data(), public.log_expert_profile_event(text), public.expert_update_profile(jsonb),
  public.expert_delete_profile() to authenticated;
