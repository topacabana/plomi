-- La collection WeWeb « maps » ne demande plus network_available : on retire la colonne de secours.
-- PostgreSQL ne permet pas de retirer une colonne d'une vue par CREATE OR REPLACE : drop + create
-- dans la même transaction (aucun objet ne dépend de la vue).
-- Droits resserrés : la vue s'exécute avec les droits de son propriétaire, elle ne doit donc être
-- accessible qu'en lecture, et seulement aux utilisateurs connectés (avant : écriture ouverte à
-- anon et authenticated).
do $d$
declare v text;
begin
  v := pg_get_viewdef('public.available_mandates_for_expert'::regclass);
  v := replace(v, E'    target_list_ids,\n    NULL::boolean AS network_available\n   FROM mandates m', E'    target_list_ids\n   FROM mandates m');
  if v ~ 'network_available' then raise exception 'colonne de secours toujours présente'; end if;
  execute 'drop view public.available_mandates_for_expert';
  execute 'create view public.available_mandates_for_expert as ' || v;
end $d$;
revoke all on public.available_mandates_for_expert from public, anon, authenticated;
grant select on public.available_mandates_for_expert to authenticated, service_role;
