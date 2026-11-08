-- PLOMI — instantané du schéma de production (projet Supabase « PLOMI »)
-- Généré depuis le catalogue PostgreSQL. Ne pas exécuter tel quel sur une base existante.

CREATE TYPE public.app_role AS ENUM ('gestionnaire_assurance', 'expert');
CREATE TYPE public.assignment_status AS ENUM ('pending', 'accepted', 'refused', 'expired', 'cancelled');
CREATE TYPE public.assignment_type AS ENUM ('automatic', 'manual', 'redrop', 'redrop_list');
CREATE TYPE public.availability_status AS ENUM ('available', 'busy', 'paused');
CREATE TYPE public.document_type AS ENUM ('photo', 'pdf', 'invoice', 'quote', 'attachment', 'other', 'devis', 'photo_sinistre', 'rapport_expertise', 'facture');
CREATE TYPE public.entity_type AS ENUM ('mandate', 'assignment', 'intervention', 'report', 'document', 'user', 'broadcast');
CREATE TYPE public.expert_account_status AS ENUM ('pending_validation', 'active', 'banned');
CREATE TYPE public.expert_status AS ENUM ('new', 'connecte', 'deconnecte', 'suspendu');
CREATE TYPE public.intervention_status AS ENUM ('scheduled', 'in_progress', 'completed', 'cancelled');
CREATE TYPE public.intervention_type AS ENUM ('visio', 'on_site', 'rdf', 'rdfs');
CREATE TYPE public.investigation_report_status AS ENUM ('editer', 'transmis', 'en_attente', 'accepter', 'refuser');
CREATE TYPE public.kpi_event_type AS ENUM ('mandate_accepted', 'mandate_refused', 'mandate_expired', 'mandate_completed', 'intervention_started', 'intervention_completed', 'report_submitted', 'report_validated', 'report_rejected', 'redrop_caused');
CREATE TYPE public.mandate_status AS ENUM ('draft', 'new', 'drop_pending', 'dropped', 'assigned', 'in_progress', 'waiting_report', 'closed', 'cancelled', 'suspended', 'planning', 'redrop');
CREATE TYPE public.mandate_type AS ENUM ('visio', 'rdf', 'rdfs');
CREATE TYPE public.notification_channel AS ENUM ('in_app', 'email', 'sms');
CREATE TYPE public.notification_target_type AS ENUM ('mandate', 'expert', 'report', 'intervention', 'drop_pending', 'expert_details', 'mandate_details', 'dashboard');
CREATE TYPE public.notification_type AS ENUM ('new_assignment', 'status_change', 'new_report', 'message', 'system');
CREATE TYPE public.organization_type AS ENUM ('insurance', 'expert_company');
CREATE TYPE public.presence_status AS ENUM ('online', 'offline');
CREATE TYPE public.priority_level AS ENUM ('low', 'medium', 'high', 'critical');
CREATE TYPE public.report_status AS ENUM ('draft', 'submitted', 'validated', 'rejected', 'archived');
CREATE TYPE public.report_type AS ENUM ('rdf', 'rdfs', 'visio');
CREATE TYPE public.workflow_stage AS ENUM ('pending', 'active', 'archived');
