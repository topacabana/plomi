-- Sécurité (complément A5) : les vues du schéma public s'exécutent avec les droits de leur propriétaire.
-- Les droits d'écriture (INSERT, UPDATE, DELETE, TRUNCATE) accordés par défaut à anon et authenticated
-- permettaient en théorie de modifier les tables sous-jacentes en contournant leurs règles d'accès.
-- Aucune app n'écrit à travers une vue : on ne laisse que la lecture.
do $d$
declare r record;
begin
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind = 'v' loop
    execute format('revoke insert, update, delete, truncate, references, trigger on public.%I from public, anon, authenticated', r.relname);
  end loop;
end $d$;
