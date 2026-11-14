-- RGPD A5 — vues SECURITY DEFINER : elles restent en definer (le pool d'experts est partagé
-- entre organisations, security_invoker casserait la carte et le pool), mais :
--  1. available_mandates_for_expert : un gestionnaire ne voit plus les mandats des autres organisations ;
--  2. aucune des 4 vues n'est lisible par anon ;
--  3. search_path figé sur les 22 fonctions qui n'en avaient pas.
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
  and (cardinality(m.target_list_ids) = 0 or public.current_expert_matching_list(m.target_list_ids) is not null)
  -- pool partagé pour les experts ; un gestionnaire ne voit que son organisation
  and (auth.role() = 'service_role'
       or exists (select 1 from me)
       or (public.is_manager() and m.insurance_org_id = public.current_user_organization_id()));

revoke select on public.available_mandates_for_expert, public.experts_with_profiles,
  public.mandate_history, public.vw_expert_kpis_dashboard from anon;

alter function public.activity_label(text,jsonb,jsonb) set search_path = public, extensions;
alter function public.coverage_zone_departments(text) set search_path = public, extensions;
alter function public.current_user_organization_id() set search_path = public, extensions;
alter function public.current_user_role() set search_path = public, extensions;
alter function public.escalate_mandate_priority() set search_path = public, extensions;
alter function public.generate_mandate_reference() set search_path = public, extensions;
alter function public.geo_km(numeric,numeric,numeric,numeric) set search_path = public, extensions;
alter function public.get_complete_schema() set search_path = public, extensions;
alter function public.get_experts_by_profile(text) set search_path = public, extensions;
alter function public.increment_redrop_count() set search_path = public, extensions;
alter function public.log_mandate_assignment_event() set search_path = public, extensions;
alter function public.mandate_status_label(text) set search_path = public, extensions;
alter function public.recalculate_all_expert_kpis() set search_path = public, extensions;
alter function public.search_fold(text) set search_path = public, extensions;
alter function public.search_match(text,text) set search_path = public, extensions;
alter function public.set_updated_at() set search_path = public, extensions;
alter function public.sync_mandate_visibility() set search_path = public, extensions;
alter function public.update_expert_names() set search_path = public, extensions;
alter function public.update_investigation_report_status_dates() set search_path = public, extensions;
alter function public.update_investigation_reports_updated_at() set search_path = public, extensions;
alter function public.update_updated_at_column() set search_path = public, extensions;
alter function public.update_workflow_stage() set search_path = public, extensions;
