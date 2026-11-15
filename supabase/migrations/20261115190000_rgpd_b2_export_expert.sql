-- RGPD B2 : droit d'accès (art. 15) et portabilité (art. 20) pour l'expert.
-- L'expert connecté télécharge en JSON toutes les données qui le concernent.
-- Les données des assurés (tiers) ne sont pas incluses : seuls la référence,
-- le type, la ville et les dates des mandats sont exportés.
-- Chaque export est tracé dans activity_logs (sans contenu).

create or replace function public.expert_export_my_data()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_expert experts%rowtype;
  v_out jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'Connexion requise.');
  end if;

  select * into v_expert from experts where user_id = v_uid limit 1;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Aucune fiche expert rattachée à ce compte.');
  end if;

  v_out := jsonb_build_object(
    'ok', true,
    'export', jsonb_build_object(
      'genere_le', now(),
      'base_legale', 'Articles 15 et 20 du RGPD',
      'responsable', 'PLOMI — [raison sociale, adresse et contact du DPO à compléter]',
      'compte', (select to_jsonb(p) - 'dashboard_card_order'
                   from user_profiles p where p.id = v_uid),
      'fiche_expert', to_jsonb(v_expert),
      'organisations', coalesce((select jsonb_agg(jsonb_build_object(
                          'organisation', o.name, 'source', oe.source, 'ajoute_le', oe.added_at))
                        from org_experts oe left join organizations o on o.id = oe.organization_id
                        where oe.expert_id = v_expert.id), '[]'::jsonb),
      'profils_attribues', coalesce((select jsonb_agg(jsonb_build_object(
                          'profil_id', a.profile_id, 'attribue_le', a.assigned_at))
                        from expert_profile_assignments a where a.expert_id = v_expert.id), '[]'::jsonb),
      'mandats', coalesce((select jsonb_agg(jsonb_build_object(
                          'reference', m.reference, 'type', m.mandate_type, 'ville', m.city,
                          'code_postal', m.postal_code, 'statut', m.status,
                          'cree_le', m.created_at, 'clos_le', m.closed_at) order by m.created_at)
                        from mandates m where m.assigned_expert_id = v_expert.id), '[]'::jsonb),
      'attributions', coalesce((select jsonb_agg(jsonb_build_object(
                          'mandat', m.reference, 'type', ma.assignment_type, 'statut', ma.status,
                          'attribue_le', ma.assigned_at, 'accepte_le', ma.accepted_at,
                          'refuse_le', ma.refused_at, 'annule_le', ma.cancelled_at,
                          'commentaire', ma.comment) order by ma.assigned_at)
                        from mandate_assignments ma left join mandates m on m.id = ma.mandate_id
                        where ma.expert_id = v_expert.id), '[]'::jsonb),
      'interventions', coalesce((select jsonb_agg(jsonb_build_object(
                          'mandat', m.reference, 'type', i.intervention_type, 'statut', i.status,
                          'prevue_debut', i.scheduled_start_at, 'prevue_fin', i.scheduled_end_at,
                          'debut', i.actual_start_at, 'fin', i.actual_end_at,
                          'synthese', i.result_summary) order by i.created_at)
                        from interventions i left join mandates m on m.id = i.mandate_id
                        where i.expert_id = v_expert.id), '[]'::jsonb),
      'medias_rapports', coalesce((select jsonb_agg(jsonb_build_object(
                          'mandat', m.reference, 'etape', r.step, 'piece', r.room,
                          'type', r.media_type, 'fichier', r.file_url, 'commentaire', r.comment,
                          'cree_le', r.created_at) order by r.created_at)
                        from report_media r left join mandates m on m.id = r.mandate_id
                        where r.expert_id = v_expert.id), '[]'::jsonb),
      'indicateurs', (select to_jsonb(k) from expert_kpis k where k.expert_id = v_expert.id limit 1),
      'historique_performance', coalesce((select jsonb_agg(jsonb_build_object(
                          'evenement', l.event_type, 'donnees', l.event_data, 'le', l.created_at)
                          order by l.created_at)
                        from expert_performance_logs l where l.expert_id = v_expert.id), '[]'::jsonb),
      'notifications', coalesce((select jsonb_agg(jsonb_build_object(
                          'titre', n.title, 'message', n.body, 'canal', n.channel,
                          'envoyee_le', n.sent_at, 'lue_le', n.read_at) order by n.created_at)
                        from notifications n where n.user_id = v_uid), '[]'::jsonb),
      'journal_activite_12_mois', coalesce((select jsonb_agg(jsonb_build_object(
                          'action', a.action, 'objet', a.entity_type, 'le', a.created_at)
                          order by a.created_at)
                        from activity_logs a where a.user_id = v_uid
                          and a.created_at > now() - interval '12 months'), '[]'::jsonb)
    )
  );

  insert into activity_logs (user_id, organization_id, entity_type, entity_id, action, new_values_json)
  values (v_uid, v_expert.organization_id, 'user', v_uid, 'rgpd_export_self',
          jsonb_build_object('motif', 'Export de ses données par l''expert (art. 15 et 20)'));

  return v_out;
end;
$$;

revoke execute on function public.expert_export_my_data() from public, anon;
grant execute on function public.expert_export_my_data() to authenticated, service_role;
