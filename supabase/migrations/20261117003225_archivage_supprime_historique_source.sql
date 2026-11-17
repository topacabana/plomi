-- Correctif signalé par l'analyse statique de la CI (supabase db lint) :
-- supervisor_archive_mandates supprimait dans la vue mandate_history, ce qui échoue
-- (vue non modifiable). On supprime désormais les lignes d'origine de cette vue dans
-- activity_logs : événements du mandat, de ses rapports et de ses attributions.
-- Les journaux groupés (message groupé, export) qui citent plusieurs mandats sont conservés.
do $mig$
declare d text;
begin
  d := pg_get_functiondef('public.supervisor_archive_mandates(timestamptz, boolean)'::regprocedure);
  if position('delete from mandate_history where mandate_id = any(v_ids);' in d) = 0 then
    raise exception 'supervisor_archive_mandates : instruction à corriger introuvable';
  end if;
  d := replace(d, 'delete from mandate_history where mandate_id = any(v_ids);',
$r$delete from activity_logs l
   where (l.entity_type = 'mandate' and l.entity_id = any(v_ids))
      or (l.entity_type = 'report' and l.entity_id in (select r.id from rdf_reports r where r.mandate_id = any(v_ids)))
      or (l.entity_type = 'assignment' and l.entity_id in (select a.id from mandate_assignments a where a.mandate_id = any(v_ids)));$r$);
  execute d;
end
$mig$;
