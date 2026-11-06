-- CC K (validé le 06/11/2026)
-- 1. Doublon : mandat non clôturé de l'org avec le même prénom de bénéficiaire ET (même adresse OU même téléphone)
create or replace function public.mandate_open_duplicate(p_first_name text, p_address text, p_phone text, p_exclude uuid default null)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare v jsonb; v_phone text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if nullif(trim(coalesce(p_first_name, '')), '') is null then return null; end if;
  select jsonb_build_object('id', m.id, 'reference', m.reference, 'status', m.status,
                            'beneficiary', trim(concat_ws(' ', b.first_name, b.last_name)), 'address', m.address_line_1)
    into v
    from public.mandates m join public.beneficiaries b on b.id = m.beneficiary_id
   where m.insurance_org_id = public.current_user_organization_id()
     and m.status not in ('closed', 'cancelled')
     and m.id is distinct from p_exclude
     and lower(trim(b.first_name)) = lower(trim(p_first_name))
     and ((nullif(trim(coalesce(p_address, '')), '') is not null and lower(trim(m.address_line_1)) = lower(trim(p_address)))
          or (length(v_phone) >= 6 and v_phone in (regexp_replace(coalesce(b.mobile_phone, ''), '\D', '', 'g'),
                                                    regexp_replace(coalesce(b.landline_phone, ''), '\D', '', 'g'))))
   order by m.created_at desc limit 1;
  return v;
end $$;
revoke execute on function public.mandate_open_duplicate(text, text, text, uuid) from public, anon;
grant execute on function public.mandate_open_duplicate(text, text, text, uuid) to authenticated;

-- 2. save_mandate_form : + drop en liste (p_list_ids) et + « ajouter à la liste de drop » (p_pending)
drop function if exists public.save_mandate_form(uuid, jsonb, boolean);
create or replace function public.save_mandate_form(p_mandate_id uuid, p_data jsonb, p_drop boolean default false,
                                                    p_list_ids uuid[] default null, p_pending boolean default false)
 returns uuid language plpgsql security definer set search_path to 'public'
as $$
declare
  v_org uuid := public.current_user_organization_id();
  v_id uuid := p_mandate_id;
  v_data jsonb;
  v_cols text;
  v_status text;
  v_editable text[] := array[
    'beneficiary_id','mandate_type','priority','address_line_1','address_line_2','postal_code','city',
    'comments','description','sinister_type','defect_type','affected_rooms','covering_type','appliance_type',
    'installation_type','prerequisites','scheduled_date','slot_1_at','slot_2_at','slot_3_at',
    'secondary_contact_first_name','secondary_contact_last_name','secondary_contact_mobile','secondary_contact_phone',
    'location_type','residence_type','floor','entry_code','sms_alert_enabled','network_available','symptoms'];
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

  if cardinality(coalesce(p_list_ids, '{}')) > 0 then
    if exists (select 1 from unnest(p_list_ids) x
                where not exists (select 1 from public.expert_lists l where l.id = x and l.organization_id = v_org and l.is_active)) then
      raise exception 'Liste introuvable dans votre organisation';
    end if;
    perform public.drop_mandate(v_id, p_list_ids);
  elsif coalesce(p_drop, false) then
    perform public.drop_mandate(v_id);
  elsif coalesce(p_pending, false) then
    select status into v_status from public.mandates where id = v_id;
    if v_status in ('draft', 'new') then perform public.transition_mandate_status(v_id, 'drop_pending'); end if;
  end if;
  return v_id;
end $$;
revoke execute on function public.save_mandate_form(uuid, jsonb, boolean, uuid[], boolean) from public, anon;
grant execute on function public.save_mandate_form(uuid, jsonb, boolean, uuid[], boolean) to authenticated;
