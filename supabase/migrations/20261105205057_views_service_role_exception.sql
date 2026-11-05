-- Les fonctions Edge (clé service) lisent ces vues pour les PDF : exception service_role.
do $v$
declare d text; n text; v text;
begin
  foreach v in array array['experts_with_profiles','vw_expert_kpis_dashboard'] loop
    d := rtrim(pg_get_viewdef(('public.'||v)::regclass), '; ');
    n := replace(d, 'WHERE (is_manager() OR (e.user_id = auth.uid()))',
                    'WHERE ((auth.role() = ''service_role'') OR is_manager() OR (e.user_id = auth.uid()))');
    if n = d then raise exception 'motif introuvable dans %', v; end if;
    execute format('create or replace view public.%I as ', v) || n;
  end loop;
end $v$;
