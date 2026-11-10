-- Gestion de l'équipe par le superviseur : modifier / retirer un gestionnaire.
-- La création passe par l'Edge Function manage-manager (invitation Supabase Auth).
-- Un gestionnaire retiré n'est pas effacé : compte bloqué (account_status = banned), historique conservé.

alter table public.user_profiles add column if not exists removed_at timestamptz;

create or replace function public.supervisor_save_manager(
  p_id uuid, p_first_name text, p_last_name text, p_phone text, p_is_supervisor boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  if not public.is_supervisor() then raise exception 'Accès réservé au superviseur' using errcode = '42501'; end if;
  select organization_id into v_org from user_profiles where id = auth.uid();
  if not exists (select 1 from user_profiles where id = p_id and organization_id = v_org and role::text = 'gestionnaire_assurance') then
    raise exception 'Gestionnaire introuvable dans votre équipe';
  end if;
  if coalesce(trim(p_first_name), '') = '' or coalesce(trim(p_last_name), '') = '' then
    raise exception 'Le prénom et le nom sont obligatoires';
  end if;
  if p_id = auth.uid() and not coalesce(p_is_supervisor, false) then
    raise exception 'Vous ne pouvez pas retirer votre propre accès superviseur';
  end if;
  update user_profiles set
    first_name = trim(p_first_name), last_name = trim(p_last_name),
    phone = nullif(trim(coalesce(p_phone, '')), ''),
    is_supervisor = coalesce(p_is_supervisor, false), updated_at = now()
  where id = p_id;
  insert into activity_logs (user_id, organization_id, entity_type, entity_id, action, new_values_json)
  values (auth.uid(), v_org, 'user', p_id, 'manager_updated',
          jsonb_build_object('first_name', p_first_name, 'last_name', p_last_name, 'is_supervisor', p_is_supervisor));
end $$;

create or replace function public.supervisor_remove_manager(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_org uuid;
begin
  if not public.is_supervisor() then raise exception 'Accès réservé au superviseur' using errcode = '42501'; end if;
  if p_id = auth.uid() then raise exception 'Vous ne pouvez pas retirer votre propre compte'; end if;
  select organization_id into v_org from user_profiles where id = auth.uid();
  if not exists (select 1 from user_profiles where id = p_id and organization_id = v_org and role::text = 'gestionnaire_assurance') then
    raise exception 'Gestionnaire introuvable dans votre équipe';
  end if;
  update user_profiles set account_status = 'banned', removed_at = now(), is_supervisor = false,
         presence_status = 'offline', updated_at = now()
  where id = p_id;
  delete from mandate_locks where user_id = p_id;   -- libère ses dossiers ouverts à l'écran
  insert into activity_logs (user_id, organization_id, entity_type, entity_id, action)
  values (auth.uid(), v_org, 'user', p_id, 'manager_removed');
end $$;

revoke all on function public.supervisor_save_manager(uuid, text, text, text, boolean) from public, anon;
revoke all on function public.supervisor_remove_manager(uuid) from public, anon;
grant execute on function public.supervisor_save_manager(uuid, text, text, text, boolean) to authenticated;
grant execute on function public.supervisor_remove_manager(uuid) to authenticated;

-- supervision_dashboard : masque les gestionnaires retirés, expose les champs du formulaire de modification
do $do$
declare d text := pg_get_functiondef('public.supervision_dashboard()'::regprocedure);
begin
  if position('u.role::text = ''gestionnaire_assurance''' in d) = 0 or position('''email'', m.email,' in d) = 0
     or position('u.email, u.is_supervisor,' in d) = 0 then
    raise exception 'supervision_dashboard : ancre introuvable';
  end if;
  d := replace(d, 'u.role::text = ''gestionnaire_assurance''',
                  'u.role::text = ''gestionnaire_assurance'' and u.removed_at is null');
  d := replace(d, 'u.email, u.is_supervisor,', 'u.email, u.phone, u.is_supervisor,');
  d := replace(d, '''email'', m.email,',
                  '''email'', m.email, ''first_name'', m.first_name, ''last_name'', m.last_name, ''phone'', m.phone,');
  execute d;
end $do$;

do $do$
declare d text := pg_get_functiondef('public.activity_label(text, jsonb, jsonb)'::regprocedure);
begin
  if position('else replace(p_action' in d) = 0 then raise exception 'activity_label : ancre introuvable'; end if;
  d := replace(d, 'else replace(p_action',
    'when ''manager_created'' then ''Gestionnaire créé'' when ''manager_updated'' then ''Gestionnaire modifié'' when ''manager_removed'' then ''Gestionnaire retiré''
    else replace(p_action');
  execute d;
end $do$;
