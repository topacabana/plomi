create or replace function public.save_mandate_form(p_mandate_id uuid, p_data jsonb, p_drop boolean default false)
 returns uuid language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_org uuid := public.current_user_organization_id();
  v_id uuid := p_mandate_id;
  v_data jsonb;
  v_cols text;
  v_editable text[] := array[
    'beneficiary_id','mandate_type','priority','address_line_1','address_line_2','postal_code','city',
    'comments','description','sinister_type','defect_type','affected_rooms','covering_type','appliance_type',
    'installation_type','prerequisites','scheduled_date','slot_1_at','slot_2_at','slot_3_at',
    'secondary_contact_first_name','secondary_contact_last_name','secondary_contact_mobile','secondary_contact_phone',
    'location_type','residence_type','floor','entry_code','sms_alert_enabled'];
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;

  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_data
    from jsonb_each(coalesce(p_data, '{}'::jsonb))
   where key = any(v_editable) and value not in ('null'::jsonb, '""'::jsonb);

  if v_id is null then
    if v_data->>'mandate_type' is null then raise exception 'Le type de mandat est obligatoire'; end if;
    if v_data->>'address_line_1' is null then raise exception 'L''adresse est obligatoire'; end if;
    if v_data->>'beneficiary_id' is null then raise exception 'Le bénéficiaire est obligatoire'; end if;
    select string_agg(quote_ident(k), ', ') into v_cols from jsonb_object_keys(v_data) k;
    execute format(
      'insert into public.mandates (%1$s, insurance_org_id, created_by_user_id, status)
       select %1$s, $2, auth.uid(), ''draft'' from jsonb_populate_record(null::public.mandates, $1)
       returning id', v_cols)
      into v_id using v_data, v_org;
  else
    if not exists (select 1 from public.mandates where id = v_id and insurance_org_id = v_org) then
      raise exception 'Mandat introuvable dans votre organisation';
    end if;
    if not exists (select 1 from public.mandates where id = v_id and status in ('draft','new','drop_pending')) then
      raise exception 'Ce mandat n''est plus modifiable depuis ce formulaire';
    end if;
    if v_data <> '{}'::jsonb then
      select string_agg(quote_ident(k), ', ') into v_cols from jsonb_object_keys(v_data) k;
      execute format(
        'update public.mandates m set (%1$s) = (select %1$s from jsonb_populate_record(m, $1)) where m.id = $2', v_cols)
        using v_data, v_id;
    end if;
  end if;

  if p_drop then perform public.drop_mandate(v_id); end if;
  return v_id;
end $function$;

grant execute on function public.save_mandate_form(uuid, jsonb, boolean) to authenticated;

create or replace function public.force_manager_org()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  if public.is_manager() then
    if tg_table_name = 'mandates' then
      new.insurance_org_id := public.current_user_organization_id();
    else
      new.organization_id := public.current_user_organization_id();
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_force_org on public.mandates;
create trigger trg_force_org before insert on public.mandates
  for each row execute function public.force_manager_org();
drop trigger if exists trg_force_org on public.beneficiaries;
create trigger trg_force_org before insert on public.beneficiaries
  for each row execute function public.force_manager_org();

drop policy if exists "Allow authenticated read beneficiaries" on public.beneficiaries;
drop policy if exists "Allow authenticated insert beneficiaries" on public.beneficiaries;
drop policy if exists "Allow authenticated update beneficiaries" on public.beneficiaries;
drop policy if exists "insurance read own beneficiaries" on public.beneficiaries;
drop policy if exists "insurance insert own beneficiaries" on public.beneficiaries;
drop policy if exists "insurance update own beneficiaries" on public.beneficiaries;
drop policy if exists "expert read beneficiaries from assigned mandates" on public.beneficiaries;
create policy "gestionnaire : bénéficiaires de son organisation" on public.beneficiaries
  for all to authenticated
  using (public.is_manager() and organization_id = public.current_user_organization_id())
  with check (public.is_manager() and organization_id = public.current_user_organization_id());
create policy "expert : bénéficiaires de ses mandats" on public.beneficiaries
  for select to authenticated
  using (public.is_expert() and exists (
    select 1 from public.mandates m
     where m.beneficiary_id = beneficiaries.id
       and (m.assigned_expert_id = public.current_expert_id() or public.expert_has_assignment(m.id))));
