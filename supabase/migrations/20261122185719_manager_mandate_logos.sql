-- Logo et nom du donneur d'ordre (assureur, ou entreprise tierce) de chaque mandat de l'organisation,
-- pour l'afficher en tête de ligne dans les listes du gestionnaire.
create or replace function public.manager_mandate_logos()
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_org uuid := public.current_user_organization_id();
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  return coalesce((
    select jsonb_object_agg(m.id, jsonb_build_object(
             'logo', coalesce(i.logo_url, nullif(m.requester_logo_url, '')),
             'name', coalesce(i.name, nullif(m.requester_company_name, ''), 'Particulier')))
      from public.mandates m left join public.insurers i on i.id = m.insurer_id
     where m.insurance_org_id = v_org and m.workflow_stage <> 'archived'), '{}'::jsonb);
end $function$;
revoke all on function public.manager_mandate_logos() from public, anon;
grant execute on function public.manager_mandate_logos() to authenticated;
