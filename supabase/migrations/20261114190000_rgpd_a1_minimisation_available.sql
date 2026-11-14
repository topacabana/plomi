-- RGPD A1 — minimisation : avant attribution, un expert ne voit ni le code d'accès,
-- ni les notes internes, ni le contact secondaire, ni l'identifiant du bénéficiaire.
-- Colonnes conservées (même ordre) pour ne rien casser côté front : elles valent NULL
-- tant que le mandat n'est pas attribué à l'expert connecté.
create or replace view public.available_mandates_for_expert as
with me as (select e.id from public.experts e where e.user_id = auth.uid() limit 1)
select m.id, m.reference, m.insurance_org_id, m.created_by_user_id,
  case when m.assigned_expert_id = (select id from me) then m.beneficiary_id end as beneficiary_id,
  m.customer_category, m.mandate_type, m.remuneration_mode, m.title, m.description, m.sinister_type,
  m.priority, m.status, m.visible_on_map,
  case when m.assigned_expert_id = (select id from me) then m.secondary_contact_first_name end as secondary_contact_first_name,
  case when m.assigned_expert_id = (select id from me) then m.secondary_contact_last_name end as secondary_contact_last_name,
  case when m.assigned_expert_id = (select id from me) then m.secondary_contact_mobile end as secondary_contact_mobile,
  case when m.assigned_expert_id = (select id from me) then m.secondary_contact_phone end as secondary_contact_phone,
  case when m.assigned_expert_id = (select id from me) then m.secondary_contact_role end as secondary_contact_role,
  m.preferred_date, m.preferred_time, m.address_line_1, m.address_line_2, m.postal_code, m.city, m.country,
  m.latitude, m.longitude, m.location_type, m.residence_type, m.floor,
  case when m.assigned_expert_id = (select id from me) then m.entry_code end as entry_code,
  m.affected_rooms, m.affected_surfaces, m.defect_type, m.damaged_goods_value, m.covering_type,
  m.appliance_type, m.installation_type, m.prerequisites, m.sms_alert_enabled, m.comments, m.symptoms,
  m.incident_date, m.drop_at, m.expiry_at, m.assigned_at, m.closed_at, m.redrop_count,
  null::text as internal_notes,
  m.created_at, m.updated_at, m.scheduled_date, m.scheduled_time_slot, m.scheduled_date_2, m.scheduled_date_3,
  m.workflow_stage, m.assigned_expert_id, m.motif_abandon, m.date_abandon, m.expert_first_name, m.expert_last_name,
  m.started_at, m.dropped_by, m.slot_1_at, m.slot_2_at, m.slot_3_at, m.selected_slot_at, m.target_list_ids
from public.mandates m
where not exists (select 1 from public.experts e where e.user_id = auth.uid() and e.status_experts = 'suspendu'::expert_status)
  and m.visible_on_map = true
  and (cardinality(m.target_list_ids) = 0 or public.current_expert_matching_list(m.target_list_ids) is not null);
