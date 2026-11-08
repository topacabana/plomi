do $mig$
declare d text; n int;
begin
  -- catalogue
  d := pg_get_functiondef('public.kpi_catalog'::regproc);
  d := replace(d, $$'Disponibilité','h','expert',false,1)$$, $$'Disponibilité','h','expert',true,1)$$);
  d := replace(d, $$'Disponibilité','h','expert',false,2)$$, $$'Disponibilité','h','expert',true,2)$$);
  d := replace(d, $$('recrutements','Nombre de recrutement via PLOMI','Compétence et professionnalisme','nb','mandataire',true,50)$$,
$$('recrutements','Nombre de recrutement via PLOMI','Compétence et professionnalisme','nb','mandataire',true,50),
   ('disponibilite','Disponibilité (jours avec connexion, 30 derniers jours max)','Disponibilité','%','expert',true,51),
   ('respect_creneaux','Respect des créneaux (arrivée ≤ 15 min après le créneau)','Traitement','%','expert',true,52),
   ('retard_arrivee','Écart moyen d''arrivée par rapport au créneau','Traitement','min','expert',true,53),
   ('completude','Complétude des dossiers (tous les champs renseignés)','Précision de rapport','%','expert',true,54),
   ('fiabilite','Indice de fiabilité','Compétence et professionnalisme','/100','expert',true,55)$$);
  if position('fiabilite' in d) = 0 then raise exception 'catalogue non modifié'; end if;
  execute d;

  -- kpi_report (experts)
  d := pg_get_functiondef('public.kpi_report'::regproc); n := length(d);
  d := replace(d, $$      ) into v;
      v_rows := v_rows || jsonb_build_object('id', e.id$$,
$$      ) into v;
      v := v || (select jsonb_build_object(
                   'temps_app', q->'temps_app_h', 'amplitude_horaire', q->'amplitude_h', 'disponibilite', q->'disponibilite',
                   'completude', q->'completude', 'fiabilite', q->'fiabilite')
                   from (select public.expert_quality_stats(e.id, t0, t1) q) z)
              || jsonb_build_object(
                   'respect_creneaux', (select round(100.0 * count(*) filter (where m.arrived_at <= coalesce(m.selected_slot_at, m.slot_1_at) + interval '15 minutes') / nullif(count(*), 0))
                                          from public.mandates m where m.assigned_expert_id = e.id and m.insurance_org_id = v_org and m.arrived_at is not null
                                           and coalesce(m.selected_slot_at, m.slot_1_at) is not null and m.arrived_at >= t0 and m.arrived_at < t1),
                   'retard_arrivee', (select round(avg(extract(epoch from m.arrived_at - coalesce(m.selected_slot_at, m.slot_1_at)) / 60)::numeric, 1)
                                          from public.mandates m where m.assigned_expert_id = e.id and m.insurance_org_id = v_org and m.arrived_at is not null
                                           and coalesce(m.selected_slot_at, m.slot_1_at) is not null and m.arrived_at >= t0 and m.arrived_at < t1));
      v_rows := v_rows || jsonb_build_object('id', e.id$$);
  if length(d) = n then raise exception 'kpi_report non modifié'; end if;
  execute d;

  -- recruitment_expert_stats
  d := pg_get_functiondef('public.recruitment_expert_stats(uuid,date,date,text)'::regprocedure); n := length(d);
  d := replace(d, $$'respect_creneaux', ($$,
$$'completude', (public.expert_quality_stats(p_expert_id, t0, t1))->'completude',
    'fiabilite', (public.expert_quality_stats(p_expert_id, t0, t1))->'fiabilite',
    'fiabilite_detail', (public.expert_quality_stats(p_expert_id, t0, t1))->'fiabilite_detail',
    'disponibilite', (public.expert_quality_stats(p_expert_id, t0, t1))->'disponibilite',
    'contract_type', (select contract_type from public.experts where id = p_expert_id),
    'respect_creneaux', ($$);
  d := replace(d, $$jsonb_build_array('Complétude des dossiers',$$, $$jsonb_build_array($$);
  d := replace(d, $$'Note assurance moyenne', 'Valeur moyenne de devis', 'Note PLOMI', 'Indice de fiabilité')$$,
                  $$'Note assurance moyenne', 'Valeur moyenne de devis', 'Note PLOMI')$$);
  if length(d) = n or position('fiabilite_detail' in d) = 0 then raise exception 'recruitment_expert_stats non modifié'; end if;
  execute d;

  -- recruitment_data
  d := pg_get_functiondef('public.recruitment_data'::regproc); n := length(d);
  d := replace(d, $$jsonb_build_array('Complétude des dossiers', 'Indice de fiabilité',
                                      'Type de contrat (AE, SARL…)', 'Note assurance', 'Valeur de devis', 'Note PLOMI')$$,
                  $$jsonb_build_array('Note assurance', 'Valeur de devis', 'Note PLOMI')$$);
  if length(d) = n then raise exception 'recruitment_data non modifié'; end if;
  execute d;

  -- expert_update_profile : type de contrat
  d := pg_get_functiondef('public.expert_update_profile'::regproc); n := length(d);
  d := replace(d, $$  if p_data ? 'postal_code' and$$,
$$  if p_data ? 'contract_type' and nullif(p_data->>'contract_type','') is not null
     and p_data->>'contract_type' not in ('AE','EI','EURL','SARL','SAS','SASU','SA','Autre') then
    raise exception 'Type de contrat invalide'; end if;
  if p_data ? 'postal_code' and$$);
  d := replace(d, $$    phone_2        = case when p_data ? 'phone_2' then nullif(trim(p_data->>'phone_2'),'') else phone_2 end,$$,
$$    phone_2        = case when p_data ? 'phone_2' then nullif(trim(p_data->>'phone_2'),'') else phone_2 end,
    contract_type  = case when p_data ? 'contract_type' then nullif(p_data->>'contract_type','') else contract_type end,$$);
  d := replace(d, $$select civility, first_name, last_name, company_name, address_line_1, address_line_2, postal_code, city, phone, phone_2 from$$,
                  $$select civility, first_name, last_name, company_name, address_line_1, address_line_2, postal_code, city, phone, phone_2, contract_type from$$);
  if length(d) = n or position('contract_type  =' in d) = 0 then raise exception 'expert_update_profile non modifié'; end if;
  execute d;

  -- expert_profile_data : type de contrat
  d := pg_get_functiondef('public.expert_profile_data'::regproc); n := length(d);
  d := replace(d, $$'civility', e.civility, 'first_name', e.first_name,$$, $$'civility', e.civility, 'contract_type', e.contract_type, 'first_name', e.first_name,$$);
  if length(d) = n then raise exception 'expert_profile_data non modifié'; end if;
  execute d;
end $mig$;
