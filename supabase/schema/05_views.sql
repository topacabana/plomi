-- PLOMI — instantané du schéma de production (projet Supabase « PLOMI »)
-- Généré depuis le catalogue PostgreSQL. Ne pas exécuter tel quel sur une base existante.

CREATE OR REPLACE VIEW public.available_mandates_for_expert WITH (security_invoker=true) AS
 SELECT id,
    reference,
    insurance_org_id,
    created_by_user_id,
    beneficiary_id,
    customer_category,
    mandate_type,
    remuneration_mode,
    title,
    description,
    sinister_type,
    priority,
    status,
    visible_on_map,
    secondary_contact_first_name,
    secondary_contact_last_name,
    secondary_contact_mobile,
    secondary_contact_phone,
    secondary_contact_role,
    preferred_date,
    preferred_time,
    address_line_1,
    address_line_2,
    postal_code,
    city,
    country,
    latitude,
    longitude,
    location_type,
    residence_type,
    floor,
    entry_code,
    affected_rooms,
    affected_surfaces,
    defect_type,
    damaged_goods_value,
    covering_type,
    appliance_type,
    installation_type,
    prerequisites,
    sms_alert_enabled,
    network_available,
    comments,
    symptoms,
    incident_date,
    drop_at,
    expiry_at,
    assigned_at,
    closed_at,
    redrop_count,
    internal_notes,
    created_at,
    updated_at,
    scheduled_date,
    scheduled_time_slot,
    scheduled_date_2,
    scheduled_date_3,
    workflow_stage,
    assigned_expert_id,
    motif_abandon,
    date_abandon,
    expert_first_name,
    expert_last_name,
    started_at,
    dropped_by,
    slot_1_at,
    slot_2_at,
    slot_3_at,
    selected_slot_at,
    target_list_ids
   FROM mandates m
  WHERE visible_on_map = true AND (cardinality(target_list_ids) = 0 OR current_expert_matching_list(target_list_ids) IS NOT NULL);

CREATE OR REPLACE VIEW public.expert_lists_with_counts WITH (security_invoker=true) AS
 SELECT id,
    organization_id,
    name,
    description,
    color,
    is_active,
    created_at,
    (( SELECT count(*) AS count
           FROM expert_list_members m
          WHERE m.list_id = l.id))::integer AS member_count
   FROM expert_lists l
  WHERE COALESCE(is_active, true);

CREATE OR REPLACE VIEW public.experts_with_profiles AS
 SELECT e.id,
    e.user_id,
    e.organization_id,
    e.company_name,
    e.trade_name,
    e.siret,
    e.specialty,
    e.coverage_zone,
    e.rating,
    e.phone,
    e.email,
    e.address_line_1,
    e.address_line_2,
    e.postal_code,
    e.city,
    e.country,
    e.latitude,
    e.longitude,
    e.created_at,
    e.updated_at,
    e.photo_url,
    e.status_experts,
    e.first_name,
    e.last_name,
    COALESCE(json_agg(json_build_object('id', ep.id, 'code', ep.code, 'label', ep.label, 'icon', ep.icon, 'color', ep.color) ORDER BY ep.sort_order) FILTER (WHERE ep.id IS NOT NULL), '[]'::json)::jsonb AS profiles,
    count(ep.id) AS profile_count,
    up.last_seen_at,
    COALESCE(up.last_seen_at > (now() - '00:05:00'::interval), false) AS is_online,
    oe.added_at AS base_added_at,
        CASE
            WHEN oe.id IS NULL THEN NULL::text
            WHEN (EXISTS ( SELECT 1
               FROM mandate_assignments a
                 JOIN mandates m ON m.id = a.mandate_id
              WHERE a.expert_id = e.id AND m.insurance_org_id = oe.organization_id)) THEN 'actif'::text
            ELSE 'new'::text
        END AS base_status
   FROM experts e
     LEFT JOIN expert_profile_assignments epa ON e.id = epa.expert_id
     LEFT JOIN expert_profiles ep ON epa.profile_id = ep.id AND ep.is_active = true
     LEFT JOIN user_profiles up ON up.id = e.user_id
     LEFT JOIN org_experts oe ON oe.expert_id = e.id AND oe.organization_id = current_user_organization_id()
  WHERE auth.role() = 'service_role'::text OR is_manager() AND oe.id IS NOT NULL OR e.user_id = auth.uid()
  GROUP BY e.id, up.last_seen_at, oe.id, oe.added_at, oe.organization_id;

CREATE OR REPLACE VIEW public.mandate_history AS
 WITH ev AS (
         SELECT l.id,
            l.user_id,
            l.organization_id,
            l.entity_type,
            l.entity_id,
            l.action,
            l.old_values_json,
            l.new_values_json,
            l.ip_address,
            l.user_agent,
            l.created_at,
            l.entity_id AS mandate_id
           FROM activity_logs l
          WHERE l.entity_type = 'mandate'::entity_type
        UNION ALL
         SELECT l.id,
            l.user_id,
            l.organization_id,
            l.entity_type,
            l.entity_id,
            l.action,
            l.old_values_json,
            l.new_values_json,
            l.ip_address,
            l.user_agent,
            l.created_at,
            r.mandate_id
           FROM activity_logs l
             JOIN rdf_reports r ON r.id = l.entity_id
          WHERE l.entity_type = 'report'::entity_type
        UNION ALL
         SELECT l.id,
            l.user_id,
            l.organization_id,
            l.entity_type,
            l.entity_id,
            l.action,
            l.old_values_json,
            l.new_values_json,
            l.ip_address,
            l.user_agent,
            l.created_at,
            a.mandate_id
           FROM activity_logs l
             JOIN mandate_assignments a ON a.id = l.entity_id
          WHERE l.entity_type = 'assignment'::entity_type
        UNION ALL
         SELECT l.id,
            l.user_id,
            l.organization_id,
            l.entity_type,
            l.entity_id,
            l.action,
            l.old_values_json,
            l.new_values_json,
            l.ip_address,
            l.user_agent,
            l.created_at,
            x.id::uuid AS id
           FROM activity_logs l
             CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(l.new_values_json -> 'mandate_ids'::text, '[]'::jsonb)) x(id)
          WHERE l.entity_type = ANY (ARRAY['broadcast'::entity_type, 'document'::entity_type])
        )
 SELECT ev.id,
    ev.mandate_id,
    ev.created_at,
    ev.action,
        CASE
            WHEN ev.action = 'status_transition'::text THEN
            CASE ev.new_values_json ->> 'status'::text
                WHEN 'drop_pending'::text THEN 'Mis en liste de drop'::text
                WHEN 'dropped'::text THEN 'Diffusé sur la carte'::text
                WHEN 'redrop'::text THEN 'Mis en redrop'::text
                WHEN 'assigned'::text THEN 'Attribué à un expert'::text
                WHEN 'in_progress'::text THEN 'Intervention démarrée'::text
                WHEN 'waiting_report'::text THEN 'Rapport envoyé'::text
                WHEN 'suspended'::text THEN 'Suspendu'::text
                WHEN 'closed'::text THEN 'Validé et clôturé'::text
                WHEN 'cancelled'::text THEN 'Annulé'::text
                ELSE 'Changement de statut'::text
            END
            WHEN ev.action = 'group_message'::text THEN ('Message groupé ('::text || COALESCE(ev.new_values_json ->> 'type'::text, ''::text)) || ')'::text
            WHEN ev.action = 'mandates_pdf_export'::text THEN 'Export PDF'::text
            WHEN ev.action = 'mandate_created'::text THEN 'Mandat créé'::text
            WHEN ev.action = 'mandate_updated'::text THEN 'Mandat modifié'::text
            WHEN ev.action = ANY (ARRAY['drop_simple'::text, 'drop_list'::text]) THEN 'Diffusé sur la carte'::text
            WHEN ev.action = 'redrop'::text THEN 'Mis en redrop'::text
            WHEN ev.action = 'mandate_withdrawn_from_cloud'::text THEN 'Retiré de la carte'::text
            WHEN ev.action = 'manual_assignment'::text THEN 'Attribution manuelle'::text
            WHEN ev.action = 'assignment_accepted'::text THEN 'Attribution acceptée'::text
            WHEN ev.action = 'assignment_refused'::text THEN 'Attribution refusée'::text
            WHEN ev.action = 'report_submitted'::text THEN 'Rapport envoyé'::text
            WHEN ev.action = 'report_validated'::text THEN 'Rapport validé'::text
            ELSE ev.action
        END AS action_label,
    ev.old_values_json ->> 'status'::text AS status_from,
    COALESCE(ev.new_values_json ->> 'status'::text,
        CASE
            WHEN ev.action = 'mandate_withdrawn_from_cloud'::text THEN 'drop_pending'::text
            ELSE NULL::text
        END) AS status_to,
    mandate_status_label(ev.old_values_json ->> 'status'::text) AS status_from_label,
    mandate_status_label(ev.new_values_json ->> 'status'::text) AS status_to_label,
    COALESCE(NULLIF(ev.new_values_json ->> 'motif'::text, ''::text), NULLIF(ev.new_values_json ->> 'comment'::text, ''::text),
        CASE
            WHEN ev.action = 'group_message'::text THEN ev.new_values_json ->> 'message'::text
            ELSE NULL::text
        END) AS motif,
    op.op_id AS operator_id,
    COALESCE(NULLIF(TRIM(BOTH FROM (COALESCE(up.first_name, ''::text) || ' '::text) || COALESCE(up.last_name, ''::text)), ''::text), NULLIF(TRIM(BOTH FROM (COALESCE(ex.first_name, ''::text) || ' '::text) || COALESCE(ex.last_name, ''::text)), ''::text),
        CASE
            WHEN op.op_id IS NULL THEN 'Système'::text
            ELSE 'Utilisateur inconnu'::text
        END) AS operator_name,
        CASE
            WHEN up.id IS NOT NULL THEN 'Gestionnaire'::text
            WHEN ex.id IS NOT NULL THEN 'Expert'::text
            ELSE 'Système'::text
        END AS operator_role
   FROM ev
     CROSS JOIN LATERAL ( SELECT COALESCE(ev.user_id,
                CASE
                    WHEN (ev.new_values_json ->> 'by'::text) ~ '^[0-9a-f-]{36}$'::text THEN (ev.new_values_json ->> 'by'::text)::uuid
                    ELSE NULL::uuid
                END) AS op_id) op
     LEFT JOIN user_profiles up ON up.id = op.op_id
     LEFT JOIN LATERAL ( SELECT e.id,
            e.user_id,
            e.organization_id,
            e.company_name,
            e.trade_name,
            e.siret,
            e.specialty,
            e.coverage_zone,
            e.rating,
            e.phone,
            e.email,
            e.address_line_1,
            e.address_line_2,
            e.postal_code,
            e.city,
            e.country,
            e.latitude,
            e.longitude,
            e.created_at,
            e.updated_at,
            e.photo_url,
            e.status_experts,
            e.first_name,
            e.last_name,
            e.profiles,
            e.profile_count
           FROM experts_with_profiles e
          WHERE e.user_id = op.op_id AND up.id IS NULL
         LIMIT 1) ex ON true
  WHERE auth.role() = 'service_role'::text OR is_manager() AND (EXISTS ( SELECT 1
           FROM mandates mm
          WHERE mm.id = ev.mandate_id AND mm.insurance_org_id = current_user_organization_id()));

CREATE OR REPLACE VIEW public.mandate_lock_status WITH (security_invoker=true) AS
 SELECT l.mandate_id,
    m.reference,
    l.user_id,
    lock_holder_name(l.user_id) AS holder_name,
    l.user_id = auth.uid() AS is_mine,
    l.locked_at,
    l.expires_at
   FROM mandate_locks l
     JOIN mandates m ON m.id = l.mandate_id
  WHERE l.expires_at > now();

CREATE OR REPLACE VIEW public.my_active_mandates WITH (security_invoker=true) AS
 SELECT id,
    reference,
    insurance_org_id,
    created_by_user_id,
    beneficiary_id,
    customer_category,
    mandate_type,
    remuneration_mode,
    title,
    description,
    sinister_type,
    priority,
    status,
    visible_on_map,
    secondary_contact_first_name,
    secondary_contact_last_name,
    secondary_contact_mobile,
    secondary_contact_phone,
    secondary_contact_role,
    preferred_date,
    preferred_time,
    address_line_1,
    address_line_2,
    postal_code,
    city,
    country,
    latitude,
    longitude,
    location_type,
    residence_type,
    floor,
    entry_code,
    affected_rooms,
    affected_surfaces,
    defect_type,
    damaged_goods_value,
    covering_type,
    appliance_type,
    installation_type,
    prerequisites,
    sms_alert_enabled,
    network_available,
    comments,
    symptoms,
    incident_date,
    drop_at,
    expiry_at,
    assigned_at,
    closed_at,
    redrop_count,
    internal_notes,
    created_at,
    updated_at,
    scheduled_date,
    scheduled_time_slot,
    scheduled_date_2,
    scheduled_date_3,
    workflow_stage,
    assigned_expert_id,
    motif_abandon,
    date_abandon,
    expert_first_name,
    expert_last_name,
    started_at,
    dropped_by,
    slot_1_at,
    slot_2_at,
    slot_3_at,
    selected_slot_at,
    target_list_ids
   FROM mandates m
  WHERE assigned_expert_id = current_expert_id() AND (status = ANY (ARRAY['assigned'::mandate_status, 'in_progress'::mandate_status]));

CREATE OR REPLACE VIEW public.pending_mandates_with_beneficiaries WITH (security_invoker=true) AS
 SELECT m.id,
    m.reference,
    m.insurance_org_id,
    m.created_by_user_id,
    m.beneficiary_id,
    m.customer_category,
    m.mandate_type,
    m.remuneration_mode,
    m.title,
    m.description,
    m.sinister_type,
    m.priority,
    m.status,
    m.visible_on_map,
    m.secondary_contact_first_name,
    m.secondary_contact_last_name,
    m.secondary_contact_mobile,
    m.secondary_contact_phone,
    m.secondary_contact_role,
    m.preferred_date,
    m.preferred_time,
    m.address_line_1,
    m.address_line_2,
    m.postal_code,
    m.city,
    m.country,
    m.latitude,
    m.longitude,
    m.location_type,
    m.residence_type,
    m.floor,
    m.entry_code,
    m.affected_rooms,
    m.affected_surfaces,
    m.defect_type,
    m.damaged_goods_value,
    m.covering_type,
    m.appliance_type,
    m.installation_type,
    m.prerequisites,
    m.sms_alert_enabled,
    m.network_available,
    m.comments,
    m.symptoms,
    m.incident_date,
    m.drop_at,
    m.expiry_at,
    m.assigned_at,
    m.closed_at,
    m.redrop_count,
    m.internal_notes,
    m.created_at,
    m.updated_at,
    m.scheduled_date,
    m.scheduled_time_slot,
    m.scheduled_date_2,
    m.scheduled_date_3,
    m.workflow_stage,
    m.assigned_expert_id,
    b.id AS beneficiary_id_full,
    b.organization_id AS beneficiary_organization_id,
    b.first_name AS beneficiary_first_name,
    b.last_name AS beneficiary_last_name,
    b.mobile_phone AS beneficiary_mobile_phone,
    b.landline_phone AS beneficiary_landline_phone,
    b.email AS beneficiary_email,
    b.created_at AS beneficiary_created_at,
    b.updated_at AS beneficiary_updated_at,
    m.slot_1_at,
    m.slot_2_at,
    m.slot_3_at
   FROM mandates m
     LEFT JOIN beneficiaries b ON m.beneficiary_id = b.id
  WHERE m.workflow_stage = 'pending'::workflow_stage;

CREATE OR REPLACE VIEW public.vw_expert_kpis_dashboard AS
 SELECT e.id AS expert_id,
    (up.first_name || ' '::text) || up.last_name AS expert_name,
    e.company_name,
    e.status_experts AS expert_status,
    k.total_mandates,
    k.mandates_in_progress,
    k.mandates_completed,
    k.mandates_refused,
    k.redrop_caused,
    round(k.avg_response_time_min::numeric, 2) AS avg_response_time_min,
    round(k.avg_intervention_duration_min::numeric, 2) AS avg_intervention_duration_min,
    round(k.avg_rating::numeric, 2) AS avg_rating,
    k.reports_submitted,
    k.reports_validated,
    k.reports_rejected,
    round(k.report_validation_rate::numeric, 2) AS report_validation_rate,
    k.mandates_last_30d,
    k.reports_last_30d,
    k.last_activity_at,
    k.last_calculated_at,
        CASE
            WHEN k.total_mandates > 0 THEN round(k.mandates_completed::numeric / k.total_mandates::numeric * 100::numeric, 2)
            ELSE 0::numeric
        END AS completion_rate,
        CASE
            WHEN k.total_mandates > 0 THEN round(k.mandates_refused::numeric / k.total_mandates::numeric * 100::numeric, 2)
            ELSE 0::numeric
        END AS refusal_rate
   FROM expert_kpis k
     JOIN experts e ON e.id = k.expert_id
     JOIN user_profiles up ON up.id = e.user_id
  WHERE auth.role() = 'service_role'::text OR is_manager() OR e.user_id = auth.uid()
  ORDER BY k.total_mandates DESC;
