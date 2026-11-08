-- PLOMI — instantané du schéma de production (projet Supabase « PLOMI »)
-- Généré depuis le catalogue PostgreSQL. Ne pas exécuter tel quel sur une base existante.

CREATE POLICY "expert read own logs" ON public.activity_logs AS PERMISSIVE FOR SELECT TO public
  USING ((is_expert() AND (user_id = auth.uid())));

CREATE POLICY "insurance read own org logs" ON public.activity_logs AS PERMISSIVE FOR SELECT TO public
  USING ((is_manager() AND (organization_id = current_user_organization_id())));

CREATE POLICY "Allow public read appliance_types" ON public.appliance_types AS PERMISSIVE FOR SELECT TO anon, authenticated
  USING (true);

CREATE POLICY "expert : bénéficiaires de ses mandats" ON public.beneficiaries AS PERMISSIVE FOR SELECT TO authenticated
  USING ((is_expert() AND (EXISTS ( SELECT 1
   FROM mandates m
  WHERE ((m.beneficiary_id = beneficiaries.id) AND ((m.assigned_expert_id = current_expert_id()) OR expert_has_assignment(m.id)))))));

CREATE POLICY "gestionnaire : bénéficiaires de son organisation" ON public.beneficiaries AS PERMISSIVE FOR ALL TO authenticated
  USING ((is_manager() AND (organization_id = current_user_organization_id())))
  WITH CHECK ((is_manager() AND (organization_id = current_user_organization_id())));

CREATE POLICY "Allow public read defect_types" ON public.defect_types AS PERMISSIVE FOR SELECT TO anon, authenticated
  USING (true);

CREATE POLICY "Allow public read deterioration_values" ON public.deterioration_values AS PERMISSIVE FOR SELECT TO anon, authenticated
  USING (true);

CREATE POLICY "expert insert own documents" ON public.documents AS PERMISSIVE FOR INSERT TO public
  WITH CHECK ((uploaded_by_user_id = auth.uid()));

CREATE POLICY "expert read own documents" ON public.documents AS PERMISSIVE FOR SELECT TO public
  USING ((is_expert() AND ((EXISTS ( SELECT 1
   FROM rdf_reports r
  WHERE ((r.id = documents.report_id) AND (r.created_by = auth.uid())))) OR (EXISTS ( SELECT 1
   FROM ((mandates m
     JOIN mandate_assignments ma ON ((ma.mandate_id = m.id)))
     JOIN experts e ON ((e.id = ma.expert_id)))
  WHERE ((m.id = documents.mandate_id) AND (e.user_id = auth.uid()) AND (ma.status = ANY (ARRAY['pending'::assignment_status, 'accepted'::assignment_status]))))))));

CREATE POLICY "insurance insert own documents" ON public.documents AS PERMISSIVE FOR INSERT TO public
  WITH CHECK (((uploaded_by_user_id = auth.uid()) AND is_manager()));

CREATE POLICY "insurance read documents of own mandates" ON public.documents AS PERMISSIVE FOR SELECT TO public
  USING ((is_manager() AND (EXISTS ( SELECT 1
   FROM mandates m
  WHERE ((m.id = documents.mandate_id) AND (m.insurance_org_id = current_user_organization_id()))))));

CREATE POLICY "expert : ses KPI" ON public.expert_kpis AS PERMISSIVE FOR SELECT TO authenticated
  USING ((expert_id = current_expert_id()));

CREATE POLICY "gestionnaire : KPI des experts" ON public.expert_kpis AS PERMISSIVE FOR SELECT TO authenticated
  USING ((is_manager() AND in_my_base(expert_id)));

CREATE POLICY "org members manage their expert list members" ON public.expert_list_members AS PERMISSIVE FOR ALL TO public
  USING ((EXISTS ( SELECT 1
   FROM expert_lists l
  WHERE ((l.id = expert_list_members.list_id) AND (l.organization_id = current_user_organization_id())))))
  WITH CHECK ((EXISTS ( SELECT 1
   FROM expert_lists l
  WHERE ((l.id = expert_list_members.list_id) AND (l.organization_id = current_user_organization_id())))));

CREATE POLICY "org members manage their expert lists" ON public.expert_lists AS PERMISSIVE FOR ALL TO public
  USING ((organization_id = current_user_organization_id()))
  WITH CHECK ((organization_id = current_user_organization_id()));

CREATE POLICY "Authenticated users can view logs" ON public.expert_performance_logs AS PERMISSIVE FOR SELECT TO authenticated
  USING ((is_manager() OR (expert_id = current_expert_id())));

CREATE POLICY "expert read own profile assignments" ON public.expert_profile_assignments AS PERMISSIVE FOR SELECT TO public
  USING ((is_expert() AND (EXISTS ( SELECT 1
   FROM experts e
  WHERE ((e.id = expert_profile_assignments.expert_id) AND (e.user_id = auth.uid()))))));

CREATE POLICY "org manages profile assignments of its experts" ON public.expert_profile_assignments AS PERMISSIVE FOR ALL TO public
  USING ((is_manager() AND (EXISTS ( SELECT 1
   FROM experts e
  WHERE ((e.id = expert_profile_assignments.expert_id) AND (e.organization_id = current_user_organization_id()))))))
  WITH CHECK ((is_manager() AND (EXISTS ( SELECT 1
   FROM experts e
  WHERE ((e.id = expert_profile_assignments.expert_id) AND (e.organization_id = current_user_organization_id()))))));

CREATE POLICY "Allow public read expert_profiles" ON public.expert_profiles AS PERMISSIVE FOR SELECT TO anon, authenticated
  USING (true);

CREATE POLICY "expert read own expert record" ON public.experts AS PERMISSIVE FOR SELECT TO public
  USING ((user_id = auth.uid()));

CREATE POLICY "expert update own expert record" ON public.experts AS PERMISSIVE FOR UPDATE TO public
  USING ((user_id = auth.uid()));

CREATE POLICY "insurance read experts" ON public.experts AS PERMISSIVE FOR SELECT TO authenticated
  USING ((is_manager() AND in_my_base(id)));

CREATE POLICY "Allow public read installation_types" ON public.installation_types AS PERMISSIVE FOR SELECT TO anon, authenticated
  USING (true);

CREATE POLICY "expert read own interventions" ON public.interventions AS PERMISSIVE FOR SELECT TO public
  USING ((is_expert() AND (EXISTS ( SELECT 1
   FROM experts e
  WHERE ((e.id = interventions.expert_id) AND (e.user_id = auth.uid()))))));

CREATE POLICY "expert update own interventions" ON public.interventions AS PERMISSIVE FOR UPDATE TO public
  USING ((is_expert() AND (EXISTS ( SELECT 1
   FROM experts e
  WHERE ((e.id = interventions.expert_id) AND (e.user_id = auth.uid()))))));

CREATE POLICY "insurance create interventions of own mandates" ON public.interventions AS PERMISSIVE FOR INSERT TO public
  WITH CHECK ((is_manager() AND (EXISTS ( SELECT 1
   FROM mandates m
  WHERE ((m.id = interventions.mandate_id) AND (m.insurance_org_id = current_user_organization_id()))))));

CREATE POLICY "insurance read interventions of own mandates" ON public.interventions AS PERMISSIVE FOR SELECT TO public
  USING ((is_manager() AND (EXISTS ( SELECT 1
   FROM mandates m
  WHERE ((m.id = interventions.mandate_id) AND (m.insurance_org_id = current_user_organization_id()))))));

CREATE POLICY "insurance update interventions of own mandates" ON public.interventions AS PERMISSIVE FOR UPDATE TO public
  USING ((is_manager() AND (EXISTS ( SELECT 1
   FROM mandates m
  WHERE ((m.id = interventions.mandate_id) AND (m.insurance_org_id = current_user_organization_id()))))));

CREATE POLICY "kpi_favorites : les miens" ON public.kpi_favorites AS PERMISSIVE FOR ALL TO authenticated
  USING ((user_id = auth.uid()))
  WITH CHECK ((user_id = auth.uid()));

CREATE POLICY "expert read own assignments" ON public.mandate_assignments AS PERMISSIVE FOR SELECT TO public
  USING ((is_expert() AND (EXISTS ( SELECT 1
   FROM experts e
  WHERE ((e.id = mandate_assignments.expert_id) AND (e.user_id = auth.uid()))))));

CREATE POLICY "expert update own assignments" ON public.mandate_assignments AS PERMISSIVE FOR UPDATE TO public
  USING ((is_expert() AND (EXISTS ( SELECT 1
   FROM experts e
  WHERE ((e.id = mandate_assignments.expert_id) AND (e.user_id = auth.uid()))))));

CREATE POLICY "insurance manage assignments on own mandates" ON public.mandate_assignments AS PERMISSIVE FOR ALL TO public
  USING ((is_manager() AND (EXISTS ( SELECT 1
   FROM mandates m
  WHERE ((m.id = mandate_assignments.mandate_id) AND (m.insurance_org_id = current_user_organization_id()))))))
  WITH CHECK ((is_manager() AND (EXISTS ( SELECT 1
   FROM mandates m
  WHERE ((m.id = mandate_assignments.mandate_id) AND (m.insurance_org_id = current_user_organization_id()))))));

CREATE POLICY "read locks" ON public.mandate_locks AS PERMISSIVE FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "Allow public read" ON public.mandate_types AS PERMISSIVE FOR SELECT TO anon, authenticated
  USING (true);

CREATE POLICY "expert : mandats sur la carte ou attribués" ON public.mandates AS PERMISSIVE FOR SELECT TO authenticated
  USING ((is_expert() AND ((assigned_expert_id = current_expert_id()) OR expert_has_assignment(id) OR (visible_on_map AND ((COALESCE(cardinality(target_list_ids), 0) = 0) OR (current_expert_matching_list(target_list_ids) IS NOT NULL))))));

CREATE POLICY "gestionnaire : mandats de son organisation" ON public.mandates AS PERMISSIVE FOR ALL TO authenticated
  USING ((is_manager() AND (insurance_org_id = current_user_organization_id())))
  WITH CHECK ((is_manager() AND (insurance_org_id = current_user_organization_id())));

CREATE POLICY "read own notifications" ON public.notifications AS PERMISSIVE FOR SELECT TO public
  USING ((user_id = auth.uid()));

CREATE POLICY "update own notifications" ON public.notifications AS PERMISSIVE FOR UPDATE TO public
  USING ((user_id = auth.uid()));

CREATE POLICY "gestionnaire : base de son org" ON public.org_experts AS PERMISSIVE FOR SELECT TO authenticated
  USING ((is_manager() AND (organization_id = current_user_organization_id())));

CREATE POLICY "read own organization" ON public.organizations AS PERMISSIVE FOR SELECT TO public
  USING ((id = current_user_organization_id()));

CREATE POLICY "plo : modèles et stratégies de mon organisation" ON public.plo_strategies AS PERMISSIVE FOR SELECT TO authenticated
  USING ((is_manager() AND ((organization_id IS NULL) OR (organization_id = current_user_organization_id()))));

CREATE POLICY "Allow public read prerequisite_types" ON public.prerequisite_types AS PERMISSIVE FOR SELECT TO anon, authenticated
  USING (true);

CREATE POLICY "expert : pièces de ses rapports" ON public.rdf_report_rooms AS PERMISSIVE FOR SELECT TO authenticated
  USING ((is_expert() AND (EXISTS ( SELECT 1
   FROM rdf_reports r
  WHERE ((r.id = rdf_report_rooms.report_id) AND (r.created_by = auth.uid()))))));

CREATE POLICY "gestionnaire : pièces des rapports de son organisation" ON public.rdf_report_rooms AS PERMISSIVE FOR SELECT TO authenticated
  USING ((is_manager() AND (EXISTS ( SELECT 1
   FROM mandates m
  WHERE ((m.id = rdf_report_rooms.mandate_id) AND (m.insurance_org_id = current_user_organization_id()))))));

CREATE POLICY "expert : ses rapports" ON public.rdf_reports AS PERMISSIVE FOR SELECT TO authenticated
  USING ((is_expert() AND (created_by = auth.uid())));

CREATE POLICY "gestionnaire : rapports de son organisation" ON public.rdf_reports AS PERMISSIVE FOR SELECT TO authenticated
  USING ((is_manager() AND (EXISTS ( SELECT 1
   FROM mandates m
  WHERE ((m.id = rdf_reports.mandate_id) AND (m.insurance_org_id = current_user_organization_id()))))));

CREATE POLICY "report_media : expert propriétaire" ON public.report_media AS PERMISSIVE FOR SELECT TO authenticated
  USING ((expert_id = current_expert_id()));

CREATE POLICY "report_media : gestionnaire du mandat" ON public.report_media AS PERMISSIVE FOR SELECT TO authenticated
  USING ((is_manager() AND (EXISTS ( SELECT 1
   FROM mandates m
  WHERE ((m.id = report_media.mandate_id) AND (m.insurance_org_id = current_user_organization_id()))))));

CREATE POLICY "Allow public read room_types" ON public.room_types AS PERMISSIVE FOR SELECT TO anon, authenticated
  USING (true);

CREATE POLICY "Allow public read surface_types" ON public.surface_types AS PERMISSIVE FOR SELECT TO anon, authenticated
  USING (true);

CREATE POLICY "read own profile" ON public.user_profiles AS PERMISSIVE FOR SELECT TO public
  USING ((id = auth.uid()));

CREATE POLICY "update own profile" ON public.user_profiles AS PERMISSIVE FOR UPDATE TO public
  USING ((id = auth.uid()));

CREATE POLICY "Allow public read wall_types" ON public.wall_types AS PERMISSIVE FOR SELECT TO anon, authenticated
  USING (true);

CREATE POLICY "documents : lecture (auteur, gestionnaire du mandat, ses export" ON storage.objects AS PERMISSIVE FOR SELECT TO authenticated
  USING (((bucket_id = 'documents'::text) AND ((((storage.foldername(name))[1] = 'rapports'::text) AND ((owner = auth.uid()) OR (is_manager() AND (EXISTS ( SELECT 1
   FROM mandates m
  WHERE (((m.id)::text = (storage.foldername(objects.name))[2]) AND (m.insurance_org_id = current_user_organization_id()))))))) OR (((storage.foldername(name))[1] = 'exports'::text) AND ((storage.foldername(name))[2] = (auth.uid())::text)))));

CREATE POLICY "documents : remplacement de ses propres photos" ON storage.objects AS PERMISSIVE FOR UPDATE TO authenticated
  USING (((bucket_id = 'documents'::text) AND ((storage.foldername(name))[1] = 'rapports'::text) AND (owner = auth.uid())))
  WITH CHECK (((bucket_id = 'documents'::text) AND ((storage.foldername(name))[1] = 'rapports'::text) AND (owner = auth.uid())));

CREATE POLICY "documents : upload des photos de rapport par un expert" ON storage.objects AS PERMISSIVE FOR INSERT TO authenticated
  WITH CHECK (((bucket_id = 'documents'::text) AND ((storage.foldername(name))[1] = 'rapports'::text) AND is_expert()));
