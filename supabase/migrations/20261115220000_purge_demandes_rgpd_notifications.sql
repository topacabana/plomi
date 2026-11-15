-- Conservation (registre C1, points à trancher validés le 15/11/2026) :
-- - registre des demandes RGPD : 5 ans après la clôture (preuve de la réponse) ;
-- - notifications in-app : 12 mois, aligné sur le journal d'activité.
-- Purge mensuelle, le 3 du mois à 04:47 UTC. Les demandes encore ouvertes ne sont jamais supprimées.
select cron.schedule('purge_rgpd_notifications', '47 4 3 * *', $c$
  delete from public.rgpd_requests where status <> 'ouverte' and closed_at < now() - interval '5 years';
  delete from public.notifications where created_at < now() - interval '12 months';
$c$);
