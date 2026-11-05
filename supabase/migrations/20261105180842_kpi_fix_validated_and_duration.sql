do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('public.recalculate_expert_kpis(uuid)'::regprocedure);
  n := d;
  -- 1. Les rapports clôturés passent désormais en 'validated' : les compter
  n := replace(n, $r$count(*) filter (where r.status in ('submitted', 'completed')),$r$,
                  $r$count(*) filter (where r.status in ('submitted', 'completed', 'validated')),$r$);
  n := replace(n, $r$count(*) filter (where r.status in ('submitted', 'completed') and m.status = 'closed'),$r$,
                  $r$count(*) filter (where r.status in ('validated', 'completed') or (r.status = 'submitted' and m.status = 'closed')),$r$);
  -- 2. Durée d'intervention : démarrage du rapport -> envoi (flux actuel), sinon table interventions
  n := replace(n, $r$  select coalesce(rating, 0) into v_avg_rating$r$,
                  $r$  if v_avg_intervention_duration_min = 0 then
    select coalesce(avg(extract(epoch from (r.submitted_at - m.started_at)) / 60), 0)
      into v_avg_intervention_duration_min
      from public.rdf_reports r
      join public.experts e on e.user_id = r.created_by
      join public.mandates m on m.id = r.mandate_id
     where e.id = p_expert_id and r.submitted_at is not null and m.started_at is not null
       and r.submitted_at > m.started_at;
  end if;

  select coalesce(rating, 0) into v_avg_rating$r$);
  if n = d or (length(n) - length(d)) < 300 then raise exception 'motifs introuvables'; end if;
  execute n;
end $mig$;

select public.recalculate_all_expert_kpis();
