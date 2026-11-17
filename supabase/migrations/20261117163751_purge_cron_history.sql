-- Purge nocturne de l'historique pg_cron (> 7 jours) pour limiter les écritures disque.
select cron.unschedule(jobid) from cron.job where jobname = 'purge_cron_history';
select cron.schedule(
  'purge_cron_history',
  '29 3 * * *',
  $$delete from cron.job_run_details where end_time < now() - interval '7 days'$$
);
-- Première purge immédiate.
delete from cron.job_run_details where end_time < now() - interval '7 days';
