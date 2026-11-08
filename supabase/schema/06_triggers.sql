-- PLOMI — instantané du schéma de production (projet Supabase « PLOMI »)
-- Généré depuis le catalogue PostgreSQL. Ne pas exécuter tel quel sur une base existante.

CREATE TRIGGER trg_beneficiaries_updated_at BEFORE UPDATE ON beneficiaries FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_force_org BEFORE INSERT ON beneficiaries FOR EACH ROW EXECUTE FUNCTION force_manager_org();
CREATE TRIGGER trg_auto_lists_on_kpis AFTER INSERT OR UPDATE ON expert_kpis FOR EACH STATEMENT EXECUTE FUNCTION trg_refresh_auto_expert_lists();
CREATE TRIGGER trg_auto_lists_on_list AFTER INSERT OR UPDATE OF auto_rule, is_active ON expert_lists FOR EACH STATEMENT EXECUTE FUNCTION trg_refresh_auto_expert_lists();
CREATE TRIGGER set_expert_profiles_updated_at BEFORE UPDATE ON expert_profiles FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
CREATE TRIGGER trg_auto_lists_on_experts AFTER INSERT OR UPDATE OF agreements, rating ON experts FOR EACH STATEMENT EXECUTE FUNCTION trg_refresh_auto_expert_lists();
CREATE TRIGGER trg_experts_updated_at BEFORE UPDATE ON experts FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_interventions_updated_at BEFORE UPDATE ON interventions FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_kpi_on_intervention AFTER UPDATE OF status ON interventions FOR EACH ROW EXECUTE FUNCTION trg_kpi_on_intervention();
CREATE TRIGGER set_investigation_report_status_dates BEFORE UPDATE ON investigation_reports FOR EACH ROW WHEN (old.status IS DISTINCT FROM new.status) EXECUTE FUNCTION update_investigation_report_status_dates();
CREATE TRIGGER set_investigation_reports_updated_at BEFORE UPDATE ON investigation_reports FOR EACH ROW EXECUTE FUNCTION update_investigation_reports_updated_at();
CREATE TRIGGER trg_kpi_on_assignment AFTER INSERT OR UPDATE OF status ON mandate_assignments FOR EACH ROW EXECUTE FUNCTION trg_kpi_on_assignment();
CREATE TRIGGER trg_mandate_assignments_updated_at BEFORE UPDATE ON mandate_assignments FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trigger_log_mandate_assignment AFTER INSERT OR UPDATE ON mandate_assignments FOR EACH ROW EXECUTE FUNCTION log_mandate_assignment_event();
CREATE TRIGGER mandate_expert_names_trigger BEFORE INSERT OR UPDATE ON mandates FOR EACH ROW EXECUTE FUNCTION update_expert_names();
CREATE TRIGGER set_mandate_reference BEFORE INSERT ON mandates FOR EACH ROW WHEN (new.reference IS NULL) EXECUTE FUNCTION generate_mandate_reference();
CREATE TRIGGER set_workflow_stage BEFORE INSERT OR UPDATE OF status ON mandates FOR EACH ROW EXECUTE FUNCTION update_workflow_stage();
CREATE TRIGGER trg_force_org BEFORE INSERT ON mandates FOR EACH ROW EXECUTE FUNCTION force_manager_org();
CREATE TRIGGER trg_increment_redrop_count BEFORE UPDATE ON mandates FOR EACH ROW EXECUTE FUNCTION increment_redrop_count();
CREATE TRIGGER trg_kpi_on_mandate_closed AFTER UPDATE OF status ON mandates FOR EACH ROW WHEN (old.status IS DISTINCT FROM new.status AND (new.status = 'closed'::mandate_status OR old.status = 'closed'::mandate_status)) EXECUTE FUNCTION trg_kpi_on_mandate_closed();
CREATE TRIGGER trg_mandate_visibility BEFORE UPDATE OF status ON mandates FOR EACH ROW EXECUTE FUNCTION sync_mandate_visibility();
CREATE TRIGGER trg_mandates_updated_at BEFORE UPDATE ON mandates FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_validate_report_on_close AFTER UPDATE OF status ON mandates FOR EACH ROW WHEN (old.status IS DISTINCT FROM new.status AND new.status = 'closed'::mandate_status) EXECUTE FUNCTION trg_validate_report_on_close();
CREATE TRIGGER notifications_normaliser BEFORE INSERT OR UPDATE OF mandate_id, entity_id, entity_type ON notifications FOR EACH ROW EXECUTE FUNCTION trg_notifications_normaliser();
CREATE TRIGGER org_experts_refresh AFTER INSERT OR DELETE ON org_experts FOR EACH STATEMENT EXECUTE FUNCTION trg_org_experts_refresh();
CREATE TRIGGER trg_organizations_updated_at BEFORE UPDATE ON organizations FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_kpi_on_rdf_report AFTER INSERT OR UPDATE OF status, rejected_at ON rdf_reports FOR EACH ROW EXECUTE FUNCTION trg_kpi_on_rdf_report();
CREATE TRIGGER trg_user_profiles_updated_at BEFORE UPDATE ON user_profiles FOR EACH ROW EXECUTE FUNCTION set_updated_at();
