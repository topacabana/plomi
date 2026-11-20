-- Séparation stricte des rôles : la vue de la carte expert ne sert plus qu'aux experts.
-- Avant : un gestionnaire connecté à l'app expert voyait sur la carte les mandats de son organisation
-- (branche « is_manager() and insurance_org_id = current_user_organization_id() »).
-- L'app mandataire n'utilise pas cette vue (elle lit mandates sous RLS), rien ne change pour elle.
create or replace view public.available_mandates_for_expert as
 WITH me AS (
         SELECT e.id
           FROM experts e
          WHERE e.user_id = auth.uid()
         LIMIT 1
        )
 SELECT id,
    reference,
    insurance_org_id,
    created_by_user_id,
        CASE
            WHEN assigned_expert_id = (( SELECT me.id
               FROM me)) THEN beneficiary_id
            ELSE NULL::uuid
        END AS beneficiary_id,
    customer_category,
    mandate_type,
    remuneration_mode,
    title,
    description,
    sinister_type,
    priority,
    status,
    visible_on_map,
        CASE
            WHEN assigned_expert_id = (( SELECT me.id
               FROM me)) THEN secondary_contact_first_name
            ELSE NULL::text
        END AS secondary_contact_first_name,
        CASE
            WHEN assigned_expert_id = (( SELECT me.id
               FROM me)) THEN secondary_contact_last_name
            ELSE NULL::text
        END AS secondary_contact_last_name,
        CASE
            WHEN assigned_expert_id = (( SELECT me.id
               FROM me)) THEN secondary_contact_mobile
            ELSE NULL::text
        END AS secondary_contact_mobile,
        CASE
            WHEN assigned_expert_id = (( SELECT me.id
               FROM me)) THEN secondary_contact_phone
            ELSE NULL::text
        END AS secondary_contact_phone,
        CASE
            WHEN assigned_expert_id = (( SELECT me.id
               FROM me)) THEN secondary_contact_role
            ELSE NULL::text
        END AS secondary_contact_role,
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
        CASE
            WHEN assigned_expert_id = (( SELECT me.id
               FROM me)) THEN entry_code
            ELSE NULL::text
        END AS entry_code,
    affected_rooms,
    affected_surfaces,
    defect_type,
    damaged_goods_value,
    covering_type,
    appliance_type,
    installation_type,
    prerequisites,
    sms_alert_enabled,
    comments,
    symptoms,
    incident_date,
    drop_at,
    expiry_at,
    assigned_at,
    closed_at,
    redrop_count,
    NULL::text AS internal_notes,
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
  WHERE NOT (EXISTS ( SELECT 1
           FROM experts e
          WHERE e.user_id = auth.uid() AND e.status_experts = 'suspendu'::expert_status)) AND visible_on_map = true AND (cardinality(target_list_ids) = 0 OR current_expert_matching_list(target_list_ids) IS NOT NULL) AND (auth.role() = 'service_role'::text OR (EXISTS ( SELECT 1
           FROM me)));
