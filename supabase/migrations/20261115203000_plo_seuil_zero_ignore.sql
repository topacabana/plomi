-- PLO : un seuil à 0 signifie « critère ignoré », même si l'expert n'a pas encore de donnée.
-- Un seuil > 0 exige une donnée qui l'atteint, sauf si « inclure les experts sans historique » est coché.
-- Mise à jour par réécriture des deux fonctions concernées (plo_select et expert_plo_decisions).
do $d$
declare v text;
begin
  -- plo_select : filtre
  v := pg_get_functiondef('public.plo_select(integer,integer,integer,integer,boolean,uuid)'::regprocedure);
  v := replace(v, $a$(case when s.precision_score   is null then coalesce(p_include_no_data, false) else s.precision_score   >= coalesce(p_precision, 0) end)$a$,
                  $a$(coalesce(p_precision, 0) <= 0 or (case when s.precision_score is null then coalesce(p_include_no_data, false) else s.precision_score >= p_precision end))$a$);
  v := replace(v, $a$(case when s.reactivite_score  is null then coalesce(p_include_no_data, false) else s.reactivite_score  >= coalesce(p_reactivite, 0) end)$a$,
                  $a$(coalesce(p_reactivite, 0) <= 0 or (case when s.reactivite_score is null then coalesce(p_include_no_data, false) else s.reactivite_score >= p_reactivite end))$a$);
  v := replace(v, $a$(case when s.rapidite_score    is null then coalesce(p_include_no_data, false) else s.rapidite_score    >= coalesce(p_rapidite, 0) end)$a$,
                  $a$(coalesce(p_rapidite, 0) <= 0 or (case when s.rapidite_score is null then coalesce(p_include_no_data, false) else s.rapidite_score >= p_rapidite end))$a$);
  v := replace(v, $a$(case when s.avis_client_score is null then coalesce(p_include_no_data, false) else s.avis_client_score >= coalesce(p_avis_client, 0) end)$a$,
                  $a$(coalesce(p_avis_client, 0) <= 0 or (case when s.avis_client_score is null then coalesce(p_include_no_data, false) else s.avis_client_score >= p_avis_client end))$a$);
  if v !~ 'coalesce\(p_avis_client, 0\) <= 0' then raise exception 'plo_select : remplacement non appliqué'; end if;
  execute v;

  -- expert_plo_decisions : explication (un critère à seuil 0 n'est jamais cité)
  v := pg_get_functiondef('public.expert_plo_decisions()'::regprocedure);
  v := replace(v, $a$case when de.precision_score   is null and not d.include_no_data then$a$,
                  $a$case when coalesce((d.thresholds->>'precision')::int, 0) <= 0 then null when de.precision_score   is null and not d.include_no_data then$a$);
  v := replace(v, $a$case when de.reactivite_score  is null and not d.include_no_data then$a$,
                  $a$case when coalesce((d.thresholds->>'reactivite')::int, 0) <= 0 then null when de.reactivite_score  is null and not d.include_no_data then$a$);
  v := replace(v, $a$case when de.rapidite_score    is null and not d.include_no_data then$a$,
                  $a$case when coalesce((d.thresholds->>'rapidite')::int, 0) <= 0 then null when de.rapidite_score    is null and not d.include_no_data then$a$);
  v := replace(v, $a$case when de.avis_client_score is null and not d.include_no_data then$a$,
                  $a$case when coalesce((d.thresholds->>'avis_client')::int, 0) <= 0 then null when de.avis_client_score is null and not d.include_no_data then$a$);
  if v !~ $r$thresholds->>'avis_client'\)::int, 0\) <= 0 then null$r$ then raise exception 'expert_plo_decisions : remplacement non appliqué'; end if;
  execute v;
end $d$;
