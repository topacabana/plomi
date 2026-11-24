-- Fiche mandat (gestionnaire) : les 3 créneaux du mandat sont aussi fournis par manager_mandate_logos,
-- car la collection WeWeb de la fiche ne contient pas les colonnes slot_*_at (collections non modifiables).
create or replace function public.manager_mandate_logos()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare v_org uuid := public.current_user_organization_id();
begin
  if not public.is_manager() then raise exception 'Réservé aux gestionnaires'; end if;
  return coalesce((
    select jsonb_object_agg(m.id, jsonb_build_object(
             'logo', coalesce(i.logo_url, nullif(m.requester_logo_url, '')),
             'name', coalesce(i.name, nullif(m.requester_company_name, ''), 'Particulier'),
             'completion', m.completion_status,
             'has_email', coalesce(nullif(btrim(b.email), ''), '') <> '',
             'callback', case when m.completion_status = 'callback_requested'
                              then concat_ws(' · ', m.callback_phone, m.callback_slot) end,
             'callback_note', case when m.completion_status = 'callback_requested' then m.callback_note end,
             'requested_at', m.completion_requested_at,
             'slots', jsonb_build_array(m.slot_1_at, m.slot_2_at, m.slot_3_at),
             'selected_slot', m.selected_slot_at))
      from public.mandates m
      left join public.insurers i on i.id = m.insurer_id
      left join public.beneficiaries b on b.id = m.beneficiary_id
     where m.insurance_org_id = v_org), '{}'::jsonb);
end $function$;
