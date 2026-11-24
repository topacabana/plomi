-- manager_mandate_prefill : ajoute insurer_name, affiché « Organisme demandeur enregistré » sur la création pré-remplie.
create or replace function public.manager_mandate_prefill(p_mandate_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v jsonb;
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  select to_jsonb(p) || jsonb_build_object(
           'insurer_id', m.insurer_id, 'insurer_name', i.name, 'requester_type', m.requester_type,
           'requester_company_name', m.requester_company_name, 'requester_trade_name', m.requester_trade_name,
           'requester_siret', m.requester_siret, 'requester_contact_first_name', m.requester_contact_first_name,
           'requester_contact_last_name', m.requester_contact_last_name, 'requester_contact_phone', m.requester_contact_phone,
           'requester_contact_email', m.requester_contact_email, 'requester_logo_url', m.requester_logo_url,
           'completion_status', m.completion_status)
    into v
    from public.pending_mandates_with_beneficiaries p
    join public.mandates m on m.id = p.id
    left join public.insurers i on i.id = m.insurer_id
   where p.id = p_mandate_id and m.insurance_org_id = public.current_user_organization_id();
  if v is null then raise exception 'Mandat introuvable ou plus modifiable depuis ce formulaire'; end if;
  return v;
end $function$;
