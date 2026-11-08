do $mig$
declare d text; n int;
begin
  -- 1. Catalogue : 4 KPI deviennent calculables
  d := pg_get_functiondef('public.kpi_catalog'::regproc);
  d := replace(d, $$'vidéos','expert',false,17)$$, $$'vidéos','expert',true,17)$$);
  d := replace(d, $$'Réactivité','h','mandataire',false,39)$$, $$'Réactivité','h','mandataire',true,39)$$);
  d := replace(d, $$'Traitement','h','mandataire',false,40)$$, $$'Traitement','h','mandataire',true,40)$$);
  d := replace(d, $$'nb','mandataire',false,50)$$, $$'nb','mandataire',true,50)$$);
  execute d;

  -- 2. kpi_report : calculs
  d := pg_get_functiondef('public.kpi_report'::regproc);
  n := length(d);
  d := replace(d, $$'photos_rapport', (select round(avg(photos), 1) from rep),$$,
$$'photos_rapport', (select round(avg(photos), 1) from rep),
        'videos_rapport', (select round(avg((select count(*) from public.report_media rm
                                              where rm.mandate_id = rep.mandate_id and rm.expert_id = e.id and rm.media_type = 'video')), 1) from rep),$$);
  d := replace(d, $$'nb_listes', (select count(*) from public.expert_lists where organization_id = v_org and is_active),$$,
$$'nb_listes', (select count(*) from public.expert_lists where organization_id = v_org and is_active),
      'temps_suspension', (select round(avg(extract(epoch from fin - debut) / 3600)::numeric, 1) from (
                             select h.created_at debut,
                                    (select min(h2.created_at) from public.mandate_history h2
                                      where h2.mandate_id = h.mandate_id and h2.created_at > h.created_at
                                        and h2.status_to is not null and h2.status_to <> 'suspended') fin
                               from public.mandate_history h join public.mandates mm on mm.id = h.mandate_id and mm.insurance_org_id = v_org
                              where h.status_to = 'suspended' and h.created_at >= t0 and h.created_at < t1) s where fin is not null),
      'temps_reattribution', (select round(avg(extract(epoch from fin - debut) / 3600)::numeric, 1) from (
                             select h.created_at debut,
                                    (select min(h2.created_at) from public.mandate_history h2
                                      where h2.mandate_id = h.mandate_id and h2.created_at > h.created_at and h2.status_to = 'assigned') fin
                               from public.mandate_history h join public.mandates mm on mm.id = h.mandate_id and mm.insurance_org_id = v_org
                              where h.status_from in ('assigned','in_progress','suspended') and h.status_to in ('redrop','dropped','drop_pending')
                                and h.created_at >= t0 and h.created_at < t1) s where fin is not null),
      'recrutements', (select count(*) from public.org_experts oe where oe.organization_id = v_org and oe.source = 'recrutement'
                         and oe.added_at >= t0 and oe.added_at < t1),$$);
  if length(d) = n or position('temps_reattribution' in d) = 0 or position('videos_rapport' in d) = 0 then
    raise exception 'kpi_report : remplacement non appliqué';
  end if;
  execute d;

  -- 3. recruitment_expert_stats : respect des créneaux + écart d'arrivée
  d := pg_get_functiondef('public.recruitment_expert_stats(uuid,date,date,text)'::regprocedure);
  n := length(d);
  d := replace(d, $$'reactivite_min', (select round(avg_response_time_min) from public.expert_kpis where expert_id = p_expert_id),$$,
$$'reactivite_min', (select round(avg_response_time_min) from public.expert_kpis where expert_id = p_expert_id),
    'respect_creneaux', (select round(100.0 * count(*) filter (where m.arrived_at <= coalesce(m.selected_slot_at, m.slot_1_at) + interval '15 minutes') / nullif(count(*), 0))
                           from public.mandates m where m.assigned_expert_id = p_expert_id and m.arrived_at is not null
                            and coalesce(m.selected_slot_at, m.slot_1_at) is not null and m.arrived_at >= t0 and m.arrived_at < t1),
    'ecart_arrivee_min', (select round(avg(extract(epoch from m.arrived_at - coalesce(m.selected_slot_at, m.slot_1_at)) / 60)::numeric)
                           from public.mandates m where m.assigned_expert_id = p_expert_id and m.arrived_at is not null
                            and coalesce(m.selected_slot_at, m.slot_1_at) is not null and m.arrived_at >= t0 and m.arrived_at < t1),$$);
  d := replace(d, $$jsonb_build_array('Respect des créneaux horaires', 'Complétude des dossiers', 'Temps moyen d''arrivée à domicile',$$,
                  $$jsonb_build_array('Complétude des dossiers',$$);
  if length(d) = n or position('ecart_arrivee_min' in d) = 0 then raise exception 'recruitment_expert_stats : remplacement non appliqué'; end if;
  execute d;

  -- 4. recruitment_data : liste des non collectés
  d := pg_get_functiondef('public.recruitment_data'::regproc);
  n := length(d);
  d := replace(d, $$jsonb_build_array('Respect des créneaux', 'Complétude des dossiers', 'Temps moyen d''arrivée', 'Indice de fiabilité',$$,
                  $$jsonb_build_array('Complétude des dossiers', 'Indice de fiabilité',$$);
  if length(d) = n then raise exception 'recruitment_data : remplacement non appliqué'; end if;
  execute d;
end $mig$;
