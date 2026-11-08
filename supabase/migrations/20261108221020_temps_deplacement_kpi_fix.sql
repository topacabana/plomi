do $mig$
declare d text; n int;
begin
  d := pg_get_functiondef('public.kpi_report'::regproc); n := length(d);
  d := replace(d, $$where m.id in (select mandate_id from a) and m.travel_expert_id = e.id and m.travel_time_min is not null),$$,
$$where m.travel_expert_id = e.id and m.insurance_org_id = v_org and m.travel_time_min is not null
                                            and exists (select 1 from public.mandate_assignments ma where ma.mandate_id = m.id and ma.expert_id = e.id
                                                          and ma.assigned_at >= t0 and ma.assigned_at < t1)),$$);
  if length(d) = n then raise exception 'non modifié'; end if;
  execute d;
end $mig$;
