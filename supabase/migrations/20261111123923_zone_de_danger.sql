-- Zone de danger du tableau de bord (superviseur) : suppression d'un expert.
-- Même anonymisation que expert_delete_profile (l'expert supprime son propre profil), mais déclenchée
-- par le superviseur ; l'historique des mandats et des rapports est conservé.
-- Le blocage de la connexion (Supabase Auth) est fait par l'Edge Function manage-manager (action remove_expert).

create or replace function public.supervisor_delete_expert(p_expert_id uuid, p_motif text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_org uuid; v_user uuid; v_name text;
begin
  if not public.is_supervisor() then raise exception 'Accès réservé au superviseur' using errcode = '42501'; end if;
  select organization_id into v_org from user_profiles where id = auth.uid();
  if not exists (select 1 from org_experts where expert_id = p_expert_id and organization_id = v_org) then
    raise exception 'Expert introuvable dans votre base';
  end if;
  if exists (select 1 from mandates where assigned_expert_id = p_expert_id and status::text in ('assigned', 'in_progress', 'waiting_report')) then
    raise exception 'Cet expert a des mandats attribués ou en cours : réattribuez-les avant de le supprimer';
  end if;
  select user_id, trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')) into v_user, v_name from experts where id = p_expert_id;

  delete from expert_list_members where expert_id = p_expert_id;
  delete from expert_profile_assignments where expert_id = p_expert_id;
  delete from org_experts where expert_id = p_expert_id;
  delete from expert_fiche_locks where expert_id = p_expert_id;
  update experts set first_name = 'Expert', last_name = 'supprimé', civility = null, phone = null, phone_2 = null,
         email = null, photo_url = null, address_line_1 = null, address_line_2 = null, siret = null, trade_name = null,
         latitude = null, longitude = null, status_experts = 'suspendu', updated_at = now()
   where id = p_expert_id;
  if v_user is not null then
    update user_profiles set first_name = 'Expert', last_name = 'supprimé', phone = null, account_status = 'banned', updated_at = now()
     where id = v_user;
  end if;
  insert into activity_logs (user_id, organization_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), v_org, 'user', coalesce(v_user, p_expert_id), 'expert_deleted',
          jsonb_build_object('expert_id', p_expert_id, 'name', v_name, 'motif', nullif(trim(coalesce(p_motif, '')), '')));
  return v_user;
end $$;

revoke all on function public.supervisor_delete_expert(uuid, text) from public, anon;
grant execute on function public.supervisor_delete_expert(uuid, text) to authenticated;

do $do$
declare d text := pg_get_functiondef('public.activity_label(text, jsonb, jsonb)'::regprocedure);
begin
  if position('else replace(p_action' in d) = 0 then raise exception 'activity_label : ancre introuvable'; end if;
  d := replace(d, 'else replace(p_action', 'when ''expert_deleted'' then ''Expert supprimé''
    else replace(p_action');
  execute d;
end $do$;
