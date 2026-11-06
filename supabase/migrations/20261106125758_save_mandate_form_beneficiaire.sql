-- CC K : le formulaire envoie le bénéficiaire (p_data.beneficiary) ; la base le retrouve dans l'org
-- (même prénom + nom) ou le crée. Plus de recherche / création côté WeWeb.
create or replace function public.resolve_beneficiary(p_b jsonb)
 returns uuid language plpgsql security definer set search_path to 'public'
as $$
declare v_org uuid := public.current_user_organization_id(); v_id uuid;
        v_fn text := nullif(trim(coalesce(p_b->>'first_name', '')), '');
        v_ln text := nullif(trim(coalesce(p_b->>'last_name', '')), '');
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  if v_fn is null or v_ln is null then raise exception 'Le nom et le prénom du bénéficiaire sont obligatoires'; end if;
  select id into v_id from public.beneficiaries
   where organization_id = v_org and lower(first_name) = lower(v_fn) and lower(last_name) = lower(v_ln)
   order by created_at desc limit 1;
  if v_id is null then
    insert into public.beneficiaries (organization_id, first_name, last_name, mobile_phone, landline_phone, email)
    values (v_org, v_fn, v_ln, nullif(trim(coalesce(p_b->>'mobile_phone', '')), ''),
            nullif(trim(coalesce(p_b->>'landline_phone', '')), ''), nullif(lower(trim(coalesce(p_b->>'email', ''))), ''))
    returning id into v_id;
  else
    update public.beneficiaries
       set mobile_phone = coalesce(nullif(trim(coalesce(p_b->>'mobile_phone', '')), ''), mobile_phone),
           landline_phone = coalesce(nullif(trim(coalesce(p_b->>'landline_phone', '')), ''), landline_phone),
           email = coalesce(nullif(lower(trim(coalesce(p_b->>'email', ''))), ''), email),
           updated_at = now()
     where id = v_id;
  end if;
  return v_id;
end $$;
revoke execute on function public.resolve_beneficiary(jsonb) from public, anon, authenticated;

do $$ declare d text; begin
  d := pg_get_functiondef('public.save_mandate_form(uuid, jsonb, boolean, uuid[], boolean)'::regprocedure);
  d := replace(d, $r$   where key = any(v_editable) and value not in ('null'::jsonb, '""'::jsonb);
$r$, $r$   where key = any(v_editable) and value not in ('null'::jsonb, '""'::jsonb);

  if v_data->>'beneficiary_id' is null and jsonb_typeof(p_data->'beneficiary') = 'object' then
    v_data := v_data || jsonb_build_object('beneficiary_id', public.resolve_beneficiary(p_data->'beneficiary'));
  end if;
$r$);
  execute d;
end $$;
