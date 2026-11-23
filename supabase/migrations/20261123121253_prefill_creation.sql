-- Page de création ouverte sur un mandat existant (?m=<id>, pastille « Incomplet » / « Compléter par téléphone ») :
-- renvoie la ligne de la vue des brouillons + l'organisme demandeur (absent de la vue et de la collection WeWeb),
-- pour pré-remplir tout le formulaire, organisme compris (obligatoire à l'enregistrement).
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
           'insurer_id', m.insurer_id, 'requester_type', m.requester_type,
           'requester_company_name', m.requester_company_name, 'requester_trade_name', m.requester_trade_name,
           'requester_siret', m.requester_siret, 'requester_contact_first_name', m.requester_contact_first_name,
           'requester_contact_last_name', m.requester_contact_last_name, 'requester_contact_phone', m.requester_contact_phone,
           'requester_contact_email', m.requester_contact_email, 'requester_logo_url', m.requester_logo_url,
           'completion_status', m.completion_status)
    into v
    from public.pending_mandates_with_beneficiaries p
    join public.mandates m on m.id = p.id
   where p.id = p_mandate_id and m.insurance_org_id = public.current_user_organization_id();
  if v is null then raise exception 'Mandat introuvable ou plus modifiable depuis ce formulaire'; end if;
  return v;
end $function$;
revoke all on function public.manager_mandate_prefill(uuid) from public, anon;
grant execute on function public.manager_mandate_prefill(uuid) to authenticated;
