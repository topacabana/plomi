create or replace function public.mandate_status_label(s text)
 returns text language sql immutable as $$
  select case s
    when 'draft' then 'Brouillon' when 'new' then 'Nouveau'
    when 'drop_pending' then 'Liste de drop' when 'dropped' then 'Sur la carte'
    when 'redrop' then 'Redrop' when 'assigned' then 'Attribué'
    when 'in_progress' then 'En cours' when 'waiting_report' then 'En attente de validation'
    when 'suspended' then 'Suspendu' when 'closed' then 'Clôturé'
    when 'cancelled' then 'Annulé' else s end $$;

create or replace view public.mandate_history as
with ev as (
  select l.*, l.entity_id as mandate_id from public.activity_logs l where l.entity_type = 'mandate'
  union all
  select l.*, r.mandate_id from public.activity_logs l
    join public.rdf_reports r on r.id = l.entity_id where l.entity_type = 'report'
  union all
  select l.*, a.mandate_id from public.activity_logs l
    join public.mandate_assignments a on a.id = l.entity_id where l.entity_type = 'assignment'
  union all
  select l.*, (x.id)::uuid from public.activity_logs l
    cross join lateral jsonb_array_elements_text(coalesce(l.new_values_json->'mandate_ids','[]'::jsonb)) as x(id)
   where l.entity_type in ('broadcast','document')
)
select
  ev.id,
  ev.mandate_id,
  ev.created_at,
  ev.action,
  case
    when ev.action = 'status_transition' then
      case ev.new_values_json->>'status'
        when 'drop_pending' then 'Mis en liste de drop'
        when 'dropped' then 'Diffusé sur la carte'
        when 'redrop' then 'Mis en redrop'
        when 'assigned' then 'Attribué à un expert'
        when 'in_progress' then 'Intervention démarrée'
        when 'waiting_report' then 'Rapport envoyé'
        when 'suspended' then 'Suspendu'
        when 'closed' then 'Validé et clôturé'
        when 'cancelled' then 'Annulé'
        else 'Changement de statut' end
    when ev.action = 'group_message' then 'Message groupé (' || coalesce(ev.new_values_json->>'type','') || ')'
    when ev.action = 'mandates_pdf_export' then 'Export PDF'
    when ev.action = 'mandate_created' then 'Mandat créé'
    when ev.action = 'mandate_updated' then 'Mandat modifié'
    when ev.action in ('drop_simple','drop_list') then 'Diffusé sur la carte'
    when ev.action = 'redrop' then 'Mis en redrop'
    when ev.action = 'mandate_withdrawn_from_cloud' then 'Retiré de la carte'
    when ev.action = 'manual_assignment' then 'Attribution manuelle'
    when ev.action = 'assignment_accepted' then 'Attribution acceptée'
    when ev.action = 'assignment_refused' then 'Attribution refusée'
    when ev.action = 'report_submitted' then 'Rapport envoyé'
    when ev.action = 'report_validated' then 'Rapport validé'
    else ev.action end                                        as action_label,
  ev.old_values_json->>'status'                               as status_from,
  coalesce(ev.new_values_json->>'status',
           case when ev.action = 'mandate_withdrawn_from_cloud' then 'drop_pending' end) as status_to,
  public.mandate_status_label(ev.old_values_json->>'status')  as status_from_label,
  public.mandate_status_label(ev.new_values_json->>'status')  as status_to_label,
  coalesce(nullif(ev.new_values_json->>'motif',''),
           nullif(ev.new_values_json->>'comment',''),
           case when ev.action = 'group_message' then ev.new_values_json->>'message' end) as motif,
  op.op_id                                                    as operator_id,
  coalesce(nullif(trim(coalesce(up.first_name,'') || ' ' || coalesce(up.last_name,'')),''),
           nullif(trim(coalesce(ex.first_name,'') || ' ' || coalesce(ex.last_name,'')),''),
           case when op.op_id is null then 'Système' else 'Utilisateur inconnu' end) as operator_name,
  case when up.id is not null then 'Gestionnaire'
       when ex.id is not null then 'Expert' else 'Système' end  as operator_role
from ev
cross join lateral (
  select coalesce(ev.user_id,
                  case when (ev.new_values_json->>'by') ~ '^[0-9a-f-]{36}$'
                       then (ev.new_values_json->>'by')::uuid end) as op_id
) op
left join public.user_profiles up on up.id = op.op_id
left join lateral (select * from public.experts_with_profiles e where e.user_id = op.op_id and up.id is null limit 1) ex on true;

grant select on public.mandate_history to authenticated;
