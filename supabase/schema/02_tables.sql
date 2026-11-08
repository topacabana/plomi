-- PLOMI — instantané du schéma de production (projet Supabase « PLOMI »)
-- Généré depuis le catalogue PostgreSQL. Ne pas exécuter tel quel sur une base existante.

CREATE TABLE public.activity_logs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid,
  organization_id uuid,
  entity_type entity_type NOT NULL,
  entity_id uuid NOT NULL,
  action text NOT NULL,
  old_values_json jsonb,
  new_values_json jsonb,
  ip_address inet,
  user_agent text,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.activity_logs ADD CONSTRAINT activity_logs_pkey PRIMARY KEY (id);
ALTER TABLE public.activity_logs ADD CONSTRAINT activity_logs_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE SET NULL;
ALTER TABLE public.activity_logs ADD CONSTRAINT activity_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES user_profiles(id) ON DELETE SET NULL;
ALTER TABLE public.activity_logs ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.appliance_types (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL,
  label text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.appliance_types ADD CONSTRAINT appliance_types_code_key UNIQUE (code);
ALTER TABLE public.appliance_types ADD CONSTRAINT appliance_types_pkey PRIMARY KEY (id);
ALTER TABLE public.appliance_types ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.beneficiaries (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  first_name text NOT NULL,
  last_name text NOT NULL,
  mobile_phone text,
  landline_phone text,
  email text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.beneficiaries ADD CONSTRAINT beneficiaries_org_phone_key UNIQUE (organization_id, mobile_phone);
ALTER TABLE public.beneficiaries ADD CONSTRAINT beneficiaries_pkey PRIMARY KEY (id);
ALTER TABLE public.beneficiaries ADD CONSTRAINT beneficiaries_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE public.beneficiaries ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.defect_types (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL,
  label text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.defect_types ADD CONSTRAINT defect_types_code_key UNIQUE (code);
ALTER TABLE public.defect_types ADD CONSTRAINT defect_types_pkey PRIMARY KEY (id);
ALTER TABLE public.defect_types ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.deterioration_values (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL,
  label text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.deterioration_values ADD CONSTRAINT deterioration_values_code_key UNIQUE (code);
ALTER TABLE public.deterioration_values ADD CONSTRAINT deterioration_values_pkey PRIMARY KEY (id);
ALTER TABLE public.deterioration_values ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.documents (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  mandate_id uuid,
  report_id uuid,
  uploaded_by_user_id uuid NOT NULL,
  document_type document_type NOT NULL,
  file_name text NOT NULL,
  file_path text NOT NULL,
  mime_type text,
  file_size bigint,
  is_public boolean NOT NULL DEFAULT false,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.documents ADD CONSTRAINT documents_pkey PRIMARY KEY (id);
ALTER TABLE public.documents ADD CONSTRAINT documents_mandate_id_fkey FOREIGN KEY (mandate_id) REFERENCES mandates(id) ON DELETE CASCADE;
ALTER TABLE public.documents ADD CONSTRAINT documents_report_id_fkey FOREIGN KEY (report_id) REFERENCES rdf_reports(id) ON DELETE SET NULL;
ALTER TABLE public.documents ADD CONSTRAINT documents_uploaded_by_user_id_fkey FOREIGN KEY (uploaded_by_user_id) REFERENCES user_profiles(id) ON DELETE RESTRICT;
ALTER TABLE public.documents ADD CONSTRAINT chk_document_owner CHECK (((mandate_id IS NOT NULL) OR (report_id IS NOT NULL)));
ALTER TABLE public.documents ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.expert_fiche_locks (
  expert_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  user_id uuid NOT NULL,
  expires_at timestamp with time zone NOT NULL
);
ALTER TABLE public.expert_fiche_locks ADD CONSTRAINT expert_fiche_locks_pkey PRIMARY KEY (expert_id, organization_id);
ALTER TABLE public.expert_fiche_locks ADD CONSTRAINT expert_fiche_locks_expert_id_fkey FOREIGN KEY (expert_id) REFERENCES experts(id) ON DELETE CASCADE;
ALTER TABLE public.expert_fiche_locks ADD CONSTRAINT expert_fiche_locks_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE public.expert_fiche_locks ADD CONSTRAINT expert_fiche_locks_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE public.expert_fiche_locks ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.expert_kpis (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  expert_id uuid NOT NULL,
  total_mandates integer NOT NULL DEFAULT 0,
  mandates_in_progress integer NOT NULL DEFAULT 0,
  mandates_completed integer NOT NULL DEFAULT 0,
  mandates_refused integer NOT NULL DEFAULT 0,
  redrop_caused integer NOT NULL DEFAULT 0,
  avg_response_time_min numeric(10,2),
  avg_intervention_duration_min numeric(10,2),
  avg_rating numeric(3,2),
  reports_submitted integer NOT NULL DEFAULT 0,
  reports_validated integer NOT NULL DEFAULT 0,
  reports_rejected integer NOT NULL DEFAULT 0,
  report_validation_rate numeric(5,2),
  mandates_last_30d integer NOT NULL DEFAULT 0,
  reports_last_30d integer NOT NULL DEFAULT 0,
  last_activity_at timestamp with time zone,
  last_calculated_at timestamp with time zone NOT NULL DEFAULT now(),
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  user_id uuid
);
ALTER TABLE public.expert_kpis ADD CONSTRAINT expert_kpis_expert_id_key UNIQUE (expert_id);
ALTER TABLE public.expert_kpis ADD CONSTRAINT expert_kpis_pkey PRIMARY KEY (id);
ALTER TABLE public.expert_kpis ADD CONSTRAINT expert_kpis_expert_id_fkey FOREIGN KEY (expert_id) REFERENCES experts(id) ON DELETE CASCADE;
ALTER TABLE public.expert_kpis ADD CONSTRAINT expert_kpis_user_id_fkey FOREIGN KEY (user_id) REFERENCES user_profiles(id) ON DELETE CASCADE;
ALTER TABLE public.expert_kpis ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.expert_list_members (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  list_id uuid NOT NULL,
  expert_id uuid NOT NULL,
  added_by_user_id uuid,
  added_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.expert_list_members ADD CONSTRAINT expert_list_members_list_id_expert_id_key UNIQUE (list_id, expert_id);
ALTER TABLE public.expert_list_members ADD CONSTRAINT expert_list_members_pkey PRIMARY KEY (id);
ALTER TABLE public.expert_list_members ADD CONSTRAINT expert_list_members_added_by_user_id_fkey FOREIGN KEY (added_by_user_id) REFERENCES user_profiles(id);
ALTER TABLE public.expert_list_members ADD CONSTRAINT expert_list_members_expert_id_fkey FOREIGN KEY (expert_id) REFERENCES experts(id) ON DELETE CASCADE;
ALTER TABLE public.expert_list_members ADD CONSTRAINT expert_list_members_list_id_fkey FOREIGN KEY (list_id) REFERENCES expert_lists(id) ON DELETE CASCADE;
ALTER TABLE public.expert_list_members ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE public.expert_list_members IS 'Association many-to-many entre expert_lists et experts, meme pattern que expert_profile_assignments.';

CREATE TABLE public.expert_lists (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  name text NOT NULL,
  description text,
  color text,
  is_active boolean NOT NULL DEFAULT true,
  created_by_user_id uuid,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  auto_rule text
);
ALTER TABLE public.expert_lists ADD CONSTRAINT expert_lists_pkey PRIMARY KEY (id);
ALTER TABLE public.expert_lists ADD CONSTRAINT expert_lists_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES user_profiles(id);
ALTER TABLE public.expert_lists ADD CONSTRAINT expert_lists_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE public.expert_lists ADD CONSTRAINT expert_lists_auto_rule_check CHECK ((auto_rule = ANY (ARRAY['new_recruits'::text, 'confirmed'::text, 'agr_visio'::text, 'agr_rdf'::text, 'agr_rdfs'::text, 'agr_full'::text, 'top_reactivity'::text, 'top_speed'::text, 'top_precision'::text, 'top_rating'::text])));
ALTER TABLE public.expert_lists ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE public.expert_lists IS 'F14/F32 - Listes d''experts nommees, gerees par organisation (agence mandataire), pour le drop liste et l''attribution groupee.';

CREATE TABLE public.expert_performance_logs (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  expert_id uuid NOT NULL,
  event_type text NOT NULL,
  event_data jsonb,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  mandate_id uuid,
  metadata jsonb
);
ALTER TABLE public.expert_performance_logs ADD CONSTRAINT expert_performance_logs_pkey PRIMARY KEY (id);
ALTER TABLE public.expert_performance_logs ADD CONSTRAINT expert_performance_logs_expert_id_fkey FOREIGN KEY (expert_id) REFERENCES experts(id) ON DELETE CASCADE;
ALTER TABLE public.expert_performance_logs ADD CONSTRAINT expert_performance_logs_mandate_id_fkey FOREIGN KEY (mandate_id) REFERENCES mandates(id) ON DELETE CASCADE;
ALTER TABLE public.expert_performance_logs ADD CONSTRAINT expert_performance_logs_event_type_check CHECK ((event_type = ANY (ARRAY['mandate_assigned'::text, 'mandate_accepted'::text, 'mandate_refused'::text, 'mandate_expired'::text, 'mandate_completed'::text, 'redrop_caused'::text, 'intervention_started'::text, 'intervention_completed'::text, 'report_submitted'::text, 'report_validated'::text, 'report_rejected'::text, 'arrived_on_site'::text])));
ALTER TABLE public.expert_performance_logs ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE public.expert_performance_logs IS 'Log des événements de performance des experts pour calcul des KPIs';

CREATE TABLE public.expert_profile_assignments (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  expert_id uuid NOT NULL,
  profile_id uuid NOT NULL,
  assigned_at timestamp with time zone DEFAULT now(),
  assigned_by_user_id uuid,
  notes text,
  created_at timestamp with time zone DEFAULT now()
);
ALTER TABLE public.expert_profile_assignments ADD CONSTRAINT unique_expert_profile UNIQUE (expert_id, profile_id);
ALTER TABLE public.expert_profile_assignments ADD CONSTRAINT expert_profile_assignments_pkey PRIMARY KEY (id);
ALTER TABLE public.expert_profile_assignments ADD CONSTRAINT expert_profile_assignments_assigned_by_user_id_fkey FOREIGN KEY (assigned_by_user_id) REFERENCES user_profiles(id);
ALTER TABLE public.expert_profile_assignments ADD CONSTRAINT expert_profile_assignments_expert_id_fkey FOREIGN KEY (expert_id) REFERENCES experts(id) ON DELETE CASCADE;
ALTER TABLE public.expert_profile_assignments ADD CONSTRAINT expert_profile_assignments_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES expert_profiles(id) ON DELETE CASCADE;
ALTER TABLE public.expert_profile_assignments ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE public.expert_profile_assignments IS 'Association entre experts et profils (table de liaison)';

CREATE TABLE public.expert_profiles (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL,
  label text NOT NULL,
  description text,
  icon text,
  color text,
  is_active boolean DEFAULT true,
  sort_order integer DEFAULT 0,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now()
);
ALTER TABLE public.expert_profiles ADD CONSTRAINT expert_profiles_code_key UNIQUE (code);
ALTER TABLE public.expert_profiles ADD CONSTRAINT expert_profiles_pkey PRIMARY KEY (id);
ALTER TABLE public.expert_profiles ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE public.expert_profiles IS 'Profils d''experts (Rapidité, Mobilité, Disponibilité, Complétion)';

CREATE TABLE public.experts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  organization_id uuid NOT NULL,
  company_name text NOT NULL,
  trade_name text,
  siret text,
  specialty text,
  coverage_zone text,
  rating numeric(3,2),
  phone text,
  email text,
  address_line_1 text,
  address_line_2 text,
  postal_code text,
  city text,
  country text DEFAULT 'France'::text,
  latitude numeric(10,7),
  longitude numeric(10,7),
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  photo_url text,
  status_experts expert_status DEFAULT 'new'::expert_status,
  first_name text,
  last_name text,
  agreements text[] NOT NULL DEFAULT '{}'::text[],
  civility text,
  phone_2 text,
  contract_type text
);
ALTER TABLE public.experts ADD CONSTRAINT experts_user_id_key UNIQUE (user_id);
ALTER TABLE public.experts ADD CONSTRAINT experts_pkey PRIMARY KEY (id);
ALTER TABLE public.experts ADD CONSTRAINT experts_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE public.experts ADD CONSTRAINT experts_user_id_fkey FOREIGN KEY (user_id) REFERENCES user_profiles(id) ON DELETE CASCADE;
ALTER TABLE public.experts ADD CONSTRAINT chk_experts_agreements CHECK ((agreements <@ ARRAY['visio'::text, 'rdf'::text, 'rdfs'::text]));
ALTER TABLE public.experts ADD CONSTRAINT experts_civility_check CHECK (((civility IS NULL) OR (civility = ANY (ARRAY['M.'::text, 'Mme'::text]))));
ALTER TABLE public.experts ADD CONSTRAINT experts_contract_type_check CHECK (((contract_type IS NULL) OR (contract_type = ANY (ARRAY['AE'::text, 'EI'::text, 'EURL'::text, 'SARL'::text, 'SAS'::text, 'SASU'::text, 'SA'::text, 'Autre'::text]))));
ALTER TABLE public.experts ADD CONSTRAINT experts_rating_check CHECK (((rating IS NULL) OR ((rating >= (0)::numeric) AND (rating <= (5)::numeric))));
ALTER TABLE public.experts ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.installation_types (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL,
  label text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.installation_types ADD CONSTRAINT installation_types_code_key UNIQUE (code);
ALTER TABLE public.installation_types ADD CONSTRAINT installation_types_pkey PRIMARY KEY (id);
ALTER TABLE public.installation_types ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.interventions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  mandate_id uuid NOT NULL,
  expert_id uuid NOT NULL,
  intervention_type intervention_type NOT NULL,
  status intervention_status NOT NULL DEFAULT 'scheduled'::intervention_status,
  scheduled_start_at timestamp with time zone,
  scheduled_end_at timestamp with time zone,
  actual_start_at timestamp with time zone,
  actual_end_at timestamp with time zone,
  result_summary text,
  customer_feedback text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.interventions ADD CONSTRAINT interventions_pkey PRIMARY KEY (id);
ALTER TABLE public.interventions ADD CONSTRAINT interventions_expert_id_fkey FOREIGN KEY (expert_id) REFERENCES experts(id) ON DELETE RESTRICT;
ALTER TABLE public.interventions ADD CONSTRAINT interventions_mandate_id_fkey FOREIGN KEY (mandate_id) REFERENCES mandates(id) ON DELETE CASCADE;
ALTER TABLE public.interventions ADD CONSTRAINT chk_intervention_actual_dates CHECK (((actual_end_at IS NULL) OR (actual_start_at IS NULL) OR (actual_end_at >= actual_start_at)));
ALTER TABLE public.interventions ADD CONSTRAINT chk_intervention_dates CHECK (((scheduled_end_at IS NULL) OR (scheduled_start_at IS NULL) OR (scheduled_end_at >= scheduled_start_at)));
ALTER TABLE public.interventions ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.investigation_reports (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  mandate_id uuid NOT NULL,
  created_by_user_id uuid NOT NULL,
  rapport_pdf_url text,
  devis_pdf_url text,
  status investigation_report_status NOT NULL DEFAULT 'editer'::investigation_report_status,
  rapport_page_count integer,
  devis_page_count integer,
  rapport_file_size bigint,
  devis_file_size bigint,
  submitted_at timestamp with time zone,
  transmitted_at timestamp with time zone,
  accepted_at timestamp with time zone,
  refused_at timestamp with time zone,
  refusal_reason text,
  internal_notes text,
  expert_comments text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.investigation_reports ADD CONSTRAINT investigation_reports_pkey PRIMARY KEY (id);
ALTER TABLE public.investigation_reports ADD CONSTRAINT investigation_reports_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES user_profiles(id);
ALTER TABLE public.investigation_reports ADD CONSTRAINT investigation_reports_mandate_id_fkey FOREIGN KEY (mandate_id) REFERENCES mandates(id) ON DELETE CASCADE;
ALTER TABLE public.investigation_reports ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE public.investigation_reports IS 'Rapports d''investigation et devis (PDF) associés aux mandats. Permet plusieurs rapports par mandat (redrop).';

CREATE TABLE public.kpi_favorites (
  user_id uuid NOT NULL,
  kpi_code text NOT NULL,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.kpi_favorites ADD CONSTRAINT kpi_favorites_pkey PRIMARY KEY (user_id, kpi_code);
ALTER TABLE public.kpi_favorites ADD CONSTRAINT kpi_favorites_user_id_fkey FOREIGN KEY (user_id) REFERENCES user_profiles(id) ON DELETE CASCADE;
ALTER TABLE public.kpi_favorites ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.mandate_assignments (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  mandate_id uuid NOT NULL,
  expert_id uuid NOT NULL,
  assignment_type assignment_type NOT NULL,
  assigned_by_user_id uuid,
  status assignment_status NOT NULL DEFAULT 'pending'::assignment_status,
  assigned_at timestamp with time zone NOT NULL DEFAULT now(),
  accepted_at timestamp with time zone,
  refused_at timestamp with time zone,
  cancelled_at timestamp with time zone,
  comment text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  list_id uuid
);
ALTER TABLE public.mandate_assignments ADD CONSTRAINT mandate_assignments_pkey PRIMARY KEY (id);
ALTER TABLE public.mandate_assignments ADD CONSTRAINT mandate_assignments_assigned_by_user_id_fkey FOREIGN KEY (assigned_by_user_id) REFERENCES user_profiles(id) ON DELETE SET NULL;
ALTER TABLE public.mandate_assignments ADD CONSTRAINT mandate_assignments_expert_id_fkey FOREIGN KEY (expert_id) REFERENCES experts(id) ON DELETE CASCADE;
ALTER TABLE public.mandate_assignments ADD CONSTRAINT mandate_assignments_list_id_fkey FOREIGN KEY (list_id) REFERENCES expert_lists(id);
ALTER TABLE public.mandate_assignments ADD CONSTRAINT mandate_assignments_mandate_id_fkey FOREIGN KEY (mandate_id) REFERENCES mandates(id) ON DELETE CASCADE;
ALTER TABLE public.mandate_assignments ADD CONSTRAINT chk_assignment_dates CHECK (((accepted_at IS NULL) OR (accepted_at >= assigned_at)));
ALTER TABLE public.mandate_assignments ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.mandate_locks (
  mandate_id uuid NOT NULL,
  user_id uuid NOT NULL,
  locked_at timestamp with time zone NOT NULL DEFAULT now(),
  expires_at timestamp with time zone NOT NULL
);
ALTER TABLE public.mandate_locks ADD CONSTRAINT mandate_locks_pkey PRIMARY KEY (mandate_id);
ALTER TABLE public.mandate_locks ADD CONSTRAINT mandate_locks_mandate_id_fkey FOREIGN KEY (mandate_id) REFERENCES mandates(id) ON DELETE CASCADE;
ALTER TABLE public.mandate_locks ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.mandate_types (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  label text NOT NULL,
  value text NOT NULL,
  is_active boolean DEFAULT true,
  sort_order integer DEFAULT 0
);
ALTER TABLE public.mandate_types ADD CONSTRAINT mandate_types_pkey PRIMARY KEY (id);
ALTER TABLE public.mandate_types ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.mandates (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  reference text NOT NULL,
  insurance_org_id uuid NOT NULL,
  created_by_user_id uuid NOT NULL,
  beneficiary_id uuid NOT NULL,
  customer_category text,
  mandate_type mandate_type NOT NULL,
  remuneration_mode text,
  title text,
  description text,
  sinister_type text[],
  priority priority_level NOT NULL DEFAULT 'medium'::priority_level,
  status mandate_status NOT NULL DEFAULT 'draft'::mandate_status,
  visible_on_map boolean NOT NULL DEFAULT false,
  secondary_contact_first_name text,
  secondary_contact_last_name text,
  secondary_contact_mobile text,
  secondary_contact_phone text,
  secondary_contact_role text,
  preferred_date date,
  preferred_time time without time zone,
  address_line_1 text NOT NULL,
  address_line_2 text,
  postal_code text,
  city text,
  country text DEFAULT 'France'::text,
  latitude numeric(10,7),
  longitude numeric(10,7),
  location_type text,
  residence_type text,
  floor text,
  entry_code text,
  affected_rooms text[],
  affected_surfaces text[],
  defect_type text,
  damaged_goods_value numeric(12,2),
  covering_type text[],
  appliance_type text[],
  installation_type text[],
  prerequisites text[],
  sms_alert_enabled boolean NOT NULL DEFAULT false,
  network_available boolean,
  comments text,
  symptoms text,
  incident_date timestamp with time zone,
  drop_at timestamp with time zone,
  expiry_at timestamp with time zone,
  assigned_at timestamp with time zone,
  closed_at timestamp with time zone,
  redrop_count integer NOT NULL DEFAULT 0,
  internal_notes text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  scheduled_date date,
  scheduled_time_slot text,
  scheduled_date_2 date,
  scheduled_date_3 date,
  workflow_stage workflow_stage DEFAULT 'pending'::workflow_stage,
  assigned_expert_id uuid,
  motif_abandon text,
  date_abandon timestamp with time zone,
  expert_first_name text,
  expert_last_name text,
  started_at timestamp with time zone,
  dropped_by uuid,
  slot_1_at timestamp with time zone,
  slot_2_at timestamp with time zone,
  slot_3_at timestamp with time zone,
  selected_slot_at timestamp with time zone,
  target_list_ids uuid[] NOT NULL DEFAULT '{}'::uuid[],
  arrived_at timestamp with time zone,
  email_alert_enabled boolean NOT NULL DEFAULT false,
  travel_time_min integer,
  travel_distance_km numeric(7,1),
  travel_expert_id uuid,
  travel_computed_at timestamp with time zone,
  travel_error text
);
ALTER TABLE public.mandates ADD CONSTRAINT mandates_reference_key UNIQUE (reference);
ALTER TABLE public.mandates ADD CONSTRAINT mandates_pkey PRIMARY KEY (id);
ALTER TABLE public.mandates ADD CONSTRAINT mandates_assigned_expert_id_fkey FOREIGN KEY (assigned_expert_id) REFERENCES experts(id);
ALTER TABLE public.mandates ADD CONSTRAINT mandates_beneficiary_id_fkey FOREIGN KEY (beneficiary_id) REFERENCES beneficiaries(id) ON DELETE RESTRICT;
ALTER TABLE public.mandates ADD CONSTRAINT mandates_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES user_profiles(id) ON DELETE RESTRICT;
ALTER TABLE public.mandates ADD CONSTRAINT mandates_dropped_by_fkey FOREIGN KEY (dropped_by) REFERENCES user_profiles(id) ON DELETE SET NULL;
ALTER TABLE public.mandates ADD CONSTRAINT mandates_insurance_org_id_fkey FOREIGN KEY (insurance_org_id) REFERENCES organizations(id) ON DELETE RESTRICT;
ALTER TABLE public.mandates ADD CONSTRAINT chk_assigned_expert_required CHECK ((((status = ANY (ARRAY['assigned'::mandate_status, 'in_progress'::mandate_status, 'waiting_report'::mandate_status, 'planning'::mandate_status])) AND (assigned_expert_id IS NOT NULL)) OR (status <> ALL (ARRAY['assigned'::mandate_status, 'in_progress'::mandate_status, 'waiting_report'::mandate_status, 'planning'::mandate_status]))));
ALTER TABLE public.mandates ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.notifications (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  mandate_id uuid,
  type notification_type NOT NULL,
  title text NOT NULL,
  body text,
  channel notification_channel NOT NULL DEFAULT 'in_app'::notification_channel,
  is_read boolean NOT NULL DEFAULT false,
  sent_at timestamp with time zone NOT NULL DEFAULT now(),
  read_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  entity_type text,
  entity_id uuid,
  target_type notification_target_type
);
ALTER TABLE public.notifications ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);
ALTER TABLE public.notifications ADD CONSTRAINT notifications_mandate_id_fkey FOREIGN KEY (mandate_id) REFERENCES mandates(id) ON DELETE CASCADE;
ALTER TABLE public.notifications ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES user_profiles(id) ON DELETE CASCADE;
ALTER TABLE public.notifications ADD CONSTRAINT chk_notification_read CHECK (((read_at IS NULL) OR (read_at >= sent_at)));
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.org_experts (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL,
  expert_id uuid NOT NULL,
  source text NOT NULL DEFAULT 'recrutement'::text,
  added_by uuid,
  added_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.org_experts ADD CONSTRAINT org_experts_organization_id_expert_id_key UNIQUE (organization_id, expert_id);
ALTER TABLE public.org_experts ADD CONSTRAINT org_experts_pkey PRIMARY KEY (id);
ALTER TABLE public.org_experts ADD CONSTRAINT org_experts_added_by_fkey FOREIGN KEY (added_by) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE public.org_experts ADD CONSTRAINT org_experts_expert_id_fkey FOREIGN KEY (expert_id) REFERENCES experts(id) ON DELETE CASCADE;
ALTER TABLE public.org_experts ADD CONSTRAINT org_experts_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE public.org_experts ADD CONSTRAINT org_experts_source_check CHECK ((source = ANY (ARRAY['initial'::text, 'recrutement'::text, 'creation'::text])));
ALTER TABLE public.org_experts ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.organizations (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  name text NOT NULL,
  type organization_type NOT NULL,
  siret text,
  email text,
  phone text,
  address_line_1 text,
  address_line_2 text,
  postal_code text,
  city text,
  country text DEFAULT 'France'::text,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  logo_url text
);
ALTER TABLE public.organizations ADD CONSTRAINT organizations_pkey PRIMARY KEY (id);
ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.plo_strategies (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  organization_id uuid,
  code text,
  name text NOT NULL,
  description text,
  precision_min integer NOT NULL,
  reactivite_min integer NOT NULL,
  rapidite_min integer NOT NULL,
  avis_client_min integer NOT NULL,
  include_no_data boolean NOT NULL DEFAULT false,
  created_by_user_id uuid,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.plo_strategies ADD CONSTRAINT plo_strategies_code_key UNIQUE (code);
ALTER TABLE public.plo_strategies ADD CONSTRAINT plo_strategies_pkey PRIMARY KEY (id);
ALTER TABLE public.plo_strategies ADD CONSTRAINT plo_strategies_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE;
ALTER TABLE public.plo_strategies ADD CONSTRAINT plo_strategies_avis_client_min_check CHECK (((avis_client_min >= 0) AND (avis_client_min <= 100)));
ALTER TABLE public.plo_strategies ADD CONSTRAINT plo_strategies_precision_min_check CHECK (((precision_min >= 0) AND (precision_min <= 100)));
ALTER TABLE public.plo_strategies ADD CONSTRAINT plo_strategies_rapidite_min_check CHECK (((rapidite_min >= 0) AND (rapidite_min <= 100)));
ALTER TABLE public.plo_strategies ADD CONSTRAINT plo_strategies_reactivite_min_check CHECK (((reactivite_min >= 0) AND (reactivite_min <= 100)));
ALTER TABLE public.plo_strategies ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.prerequisite_types (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL,
  label text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.prerequisite_types ADD CONSTRAINT prerequisite_types_code_key UNIQUE (code);
ALTER TABLE public.prerequisite_types ADD CONSTRAINT prerequisite_types_pkey PRIMARY KEY (id);
ALTER TABLE public.prerequisite_types ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.rdf_report_rooms (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  report_id uuid NOT NULL,
  mandate_id uuid NOT NULL,
  step smallint NOT NULL,
  "position" smallint NOT NULL DEFAULT 1,
  room text NOT NULL,
  wall text,
  matiere text,
  infiltration boolean,
  moisissure boolean,
  peinture_endommagee boolean,
  gaz_detecte boolean,
  sonde_type text,
  sonde_percent numeric,
  commentaire text,
  photos text[] NOT NULL DEFAULT '{}'::text[],
  created_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.rdf_report_rooms ADD CONSTRAINT rdf_report_rooms_pkey PRIMARY KEY (id);
ALTER TABLE public.rdf_report_rooms ADD CONSTRAINT rdf_report_rooms_mandate_id_fkey FOREIGN KEY (mandate_id) REFERENCES mandates(id) ON DELETE CASCADE;
ALTER TABLE public.rdf_report_rooms ADD CONSTRAINT rdf_report_rooms_report_id_fkey FOREIGN KEY (report_id) REFERENCES rdf_reports(id) ON DELETE CASCADE;
ALTER TABLE public.rdf_report_rooms ADD CONSTRAINT rdf_report_rooms_sonde_percent_check CHECK (((sonde_percent >= (0)::numeric) AND (sonde_percent <= (100)::numeric)));
ALTER TABLE public.rdf_report_rooms ADD CONSTRAINT rdf_report_rooms_sonde_type_check CHECK ((sonde_type = ANY (ARRAY['picot'::text, 'boule'::text])));
ALTER TABLE public.rdf_report_rooms ADD CONSTRAINT rdf_report_rooms_step_check CHECK (((step >= 1) AND (step <= 4)));
ALTER TABLE public.rdf_report_rooms ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE public.rdf_report_rooms IS 'Pièces investiguées d''un rapport RDF : une ligne par pièce et par étape (1 inspection, 2 colorant/fluorine, 3 gaz traceur, 4 relevé de sonde).';

CREATE TABLE public.rdf_reports (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  mandate_id uuid NOT NULL,
  inspection_piece_investigee text,
  infiltration_constatee boolean DEFAULT false,
  infiltration_non_constatee boolean DEFAULT false,
  presence_moisissure boolean DEFAULT false,
  peinture_revetement_endommage boolean DEFAULT false,
  inspection_photos text[],
  inspection_commentaires text,
  colorant_piece_investigee text,
  colorant_infiltration_constatee boolean DEFAULT false,
  colorant_infiltration_non_constatee boolean DEFAULT false,
  colorant_test_date date,
  colorant_result text,
  colorant_comment text,
  colorant_photos text[],
  fluorine_test_date date,
  fluorine_result text,
  fluorine_comment text,
  fluorine_photos text[],
  colorant_fluorine_commentaires text,
  gaz_traceur_piece_investigee text,
  gaz_detecte boolean DEFAULT false,
  gaz_non_detecte boolean DEFAULT false,
  gaz_traceur_test_date date,
  gaz_traceur_result text,
  gaz_traceur_comment text,
  gaz_traceur_photos text[],
  gaz_traceur_commentaires text,
  sonde_piece_investigee text,
  sonde_type_parole text,
  sonde_matiere text,
  sonde_a_picot_1 boolean DEFAULT false,
  sonde_a_picot_1_percent numeric,
  sonde_a_picot_2 boolean DEFAULT false,
  sonde_a_picot_2_percent numeric,
  sonde_reading numeric,
  sonde_unit character varying(50),
  sonde_location text,
  sonde_comment text,
  sonde_photos text[],
  rapport_conclusions text,
  status character varying(50) DEFAULT 'draft'::character varying,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now(),
  created_by uuid,
  submitted_at timestamp with time zone,
  validated_at timestamp with time zone,
  validated_by_user_id uuid,
  rejected_at timestamp with time zone,
  rejection_reason text,
  pdf_url text,
  hypotheses text[] NOT NULL DEFAULT '{}'::text[],
  preconisations_reserves text
);
ALTER TABLE public.rdf_reports ADD CONSTRAINT rdf_reports_pkey PRIMARY KEY (id);
ALTER TABLE public.rdf_reports ADD CONSTRAINT rdf_reports_mandate_id_fkey FOREIGN KEY (mandate_id) REFERENCES mandates(id) ON DELETE CASCADE;
ALTER TABLE public.rdf_reports ADD CONSTRAINT rdf_reports_validated_by_user_id_fkey FOREIGN KEY (validated_by_user_id) REFERENCES user_profiles(id) ON DELETE SET NULL;
ALTER TABLE public.rdf_reports ADD CONSTRAINT check_status CHECK (((status)::text = ANY (ARRAY['draft'::text, 'submitted'::text, 'completed'::text, 'validated'::text])));
ALTER TABLE public.rdf_reports ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE public.rdf_reports IS 'Rapports RDF - Inspection visuelle, colorant/fluorine, gaz traceur, relevé de sonde';

CREATE TABLE public.report_media (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  mandate_id uuid NOT NULL,
  expert_id uuid NOT NULL,
  step smallint,
  room text,
  file_url text NOT NULL,
  media_type text NOT NULL,
  comment text,
  annex_title text,
  target_x numeric,
  target_y numeric,
  duplicated_from uuid,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.report_media ADD CONSTRAINT report_media_pkey PRIMARY KEY (id);
ALTER TABLE public.report_media ADD CONSTRAINT report_media_duplicated_from_fkey FOREIGN KEY (duplicated_from) REFERENCES report_media(id) ON DELETE SET NULL;
ALTER TABLE public.report_media ADD CONSTRAINT report_media_expert_id_fkey FOREIGN KEY (expert_id) REFERENCES experts(id) ON DELETE CASCADE;
ALTER TABLE public.report_media ADD CONSTRAINT report_media_mandate_id_fkey FOREIGN KEY (mandate_id) REFERENCES mandates(id) ON DELETE CASCADE;
ALTER TABLE public.report_media ADD CONSTRAINT report_media_check CHECK (((target_x IS NULL) = (target_y IS NULL)));
ALTER TABLE public.report_media ADD CONSTRAINT report_media_media_type_check CHECK ((media_type = ANY (ARRAY['photo'::text, 'video'::text])));
ALTER TABLE public.report_media ADD CONSTRAINT report_media_step_check CHECK (((step >= 1) AND (step <= 4)));
ALTER TABLE public.report_media ADD CONSTRAINT report_media_target_x_check CHECK (((target_x >= (0)::numeric) AND (target_x <= (100)::numeric)));
ALTER TABLE public.report_media ADD CONSTRAINT report_media_target_y_check CHECK (((target_y >= (0)::numeric) AND (target_y <= (100)::numeric)));
ALTER TABLE public.report_media ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.room_types (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL,
  label text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.room_types ADD CONSTRAINT room_types_code_key UNIQUE (code);
ALTER TABLE public.room_types ADD CONSTRAINT room_types_pkey PRIMARY KEY (id);
ALTER TABLE public.room_types ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.surface_types (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL,
  label text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.surface_types ADD CONSTRAINT surface_types_code_key UNIQUE (code);
ALTER TABLE public.surface_types ADD CONSTRAINT surface_types_pkey PRIMARY KEY (id);
ALTER TABLE public.surface_types ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.user_profiles (
  id uuid NOT NULL,
  organization_id uuid,
  first_name text,
  last_name text,
  email text,
  phone text,
  role app_role NOT NULL,
  account_status expert_account_status,
  presence_status presence_status DEFAULT 'offline'::presence_status,
  availability_status availability_status,
  last_login_at timestamp with time zone,
  created_at timestamp with time zone NOT NULL DEFAULT now(),
  updated_at timestamp with time zone NOT NULL DEFAULT now(),
  last_seen_at timestamp with time zone
);
ALTER TABLE public.user_profiles ADD CONSTRAINT user_profiles_email_key UNIQUE (email);
ALTER TABLE public.user_profiles ADD CONSTRAINT user_profiles_pkey PRIMARY KEY (id);
ALTER TABLE public.user_profiles ADD CONSTRAINT user_profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE public.user_profiles ADD CONSTRAINT chk_expert_status_logic CHECK (((role = 'expert'::app_role) OR ((role = 'gestionnaire_assurance'::app_role) AND (account_status IS NULL) AND (availability_status IS NULL))));
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.user_sessions (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  started_at timestamp with time zone NOT NULL DEFAULT now(),
  last_seen_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.user_sessions ADD CONSTRAINT user_sessions_pkey PRIMARY KEY (id);
ALTER TABLE public.user_sessions ADD CONSTRAINT user_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE public.user_sessions ENABLE ROW LEVEL SECURITY;

CREATE TABLE public.wall_types (
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL,
  label text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamp with time zone NOT NULL DEFAULT now()
);
ALTER TABLE public.wall_types ADD CONSTRAINT wall_types_code_key UNIQUE (code);
ALTER TABLE public.wall_types ADD CONSTRAINT wall_types_pkey PRIMARY KEY (id);
ALTER TABLE public.wall_types ENABLE ROW LEVEL SECURITY;
