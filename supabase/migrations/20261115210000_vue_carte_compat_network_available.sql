-- La collection WeWeb « maps » (app expert) demande encore network_available, supprimée le 11/11
-- (migration suppression_network_available). PostgREST refusait toute la requête (400) :
-- carte vide pour tous les experts. Colonne de compatibilité, toujours NULL, ajoutée en fin de vue.
-- À retirer quand le champ aura été décoché dans la collection WeWeb.
do $d$
declare v text;
begin
  v := pg_get_viewdef('public.available_mandates_for_expert'::regclass);
  v := replace(v, E'    target_list_ids\n   FROM mandates m', E'    target_list_ids,\n    NULL::boolean AS network_available\n   FROM mandates m');
  if v !~ 'network_available' then raise exception 'remplacement non appliqué'; end if;
  execute 'create or replace view public.available_mandates_for_expert as ' || v;
end $d$;
revoke select on public.available_mandates_for_expert from anon;
