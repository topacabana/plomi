select cron.schedule('travel_times', '*/15 * * * *', $c$
  select net.http_post(
    url := 'https://ybbzfedbdjgcahqajltm.supabase.co/functions/v1/travel-times',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := jsonb_build_object('token', (select decrypted_secret from vault.decrypted_secrets where name = 'travel_cron_token')),
    timeout_milliseconds := 60000)
$c$) where not exists (select 1 from cron.job where jobname = 'travel_times');

do $mig$
declare d text; n int;
begin
  d := pg_get_functiondef('public.kpi_catalog'::regproc);
  d := replace(d, $$'Traitement','min','expert',false,4)$$, $$'Traitement','min','expert',true,4)$$);
  execute d;

  d := pg_get_functiondef('public.kpi_report'::regproc); n := length(d);
  d := replace(d, $$                   'respect_creneaux', (select round(100.0$$,
$$                   'temps_deplacement', (select round(avg(m.travel_time_min)::numeric, 1) from public.mandates m
                                          where m.id in (select mandate_id from a) and m.travel_expert_id = e.id and m.travel_time_min is not null),
                   'respect_creneaux', (select round(100.0$$);
  if length(d) = n then raise exception 'kpi_report non modifié'; end if;
  execute d;

  d := pg_get_functiondef('public.recruitment_expert_stats(uuid,date,date,text)'::regprocedure); n := length(d);
  d := replace(d, $$'respect_creneaux', ($$,
$$'temps_deplacement_min', (select round(avg(m.travel_time_min)) from public.mandates m
                               where m.travel_expert_id = p_expert_id and m.travel_time_min is not null
                                 and coalesce(m.assigned_at, m.created_at) >= t0 and coalesce(m.assigned_at, m.created_at) < t1),
    'respect_creneaux', ($$);
  if length(d) = n then raise exception 'recruitment_expert_stats non modifié'; end if;
  execute d;
end $mig$;
