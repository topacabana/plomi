-- La fonction Edge generate-history-pdf lit la vue avec la clé service (pas d'utilisateur) :
-- elle contrôle elle-même l'organisation du gestionnaire avant la lecture.
do $v$
declare d text; n text;
begin
  d := rtrim(pg_get_viewdef('public.mandate_history'::regclass), '; ');
  n := replace(d, 'WHERE (is_manager() AND (EXISTS',
                  'WHERE (auth.role() = ''service_role'') OR (is_manager() AND (EXISTS');
  if n = d then raise exception 'motif introuvable'; end if;
  execute 'create or replace view public.mandate_history as ' || n;
end $v$;
