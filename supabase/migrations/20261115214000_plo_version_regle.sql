-- PLO : chaque sélection garde la version de la règle avec laquelle elle a été décidée.
-- v1 (avant le 15/11/2026 18:51 UTC) : un critère sans donnée écartait l'expert, même avec un seuil à 0.
-- v2 : un seuil à 0 ignore le critère.
-- L'explication montrée à l'expert suit la règle de la sélection, pas la règle actuelle.
alter table public.plo_decisions add column if not exists rule_version smallint not null default 2;
update public.plo_decisions set rule_version = 1 where created_at < '2026-11-15 18:51:19+00';

do $d$
declare v text;
begin
  v := pg_get_functiondef('public.expert_plo_decisions()'::regprocedure);
  v := replace(v, $a$case when coalesce((d.thresholds->>'precision')::int, 0) <= 0 then null$a$,
                  $a$case when d.rule_version >= 2 and coalesce((d.thresholds->>'precision')::int, 0) <= 0 then null$a$);
  v := replace(v, $a$case when coalesce((d.thresholds->>'reactivite')::int, 0) <= 0 then null$a$,
                  $a$case when d.rule_version >= 2 and coalesce((d.thresholds->>'reactivite')::int, 0) <= 0 then null$a$);
  v := replace(v, $a$case when coalesce((d.thresholds->>'rapidite')::int, 0) <= 0 then null$a$,
                  $a$case when d.rule_version >= 2 and coalesce((d.thresholds->>'rapidite')::int, 0) <= 0 then null$a$);
  v := replace(v, $a$case when coalesce((d.thresholds->>'avis_client')::int, 0) <= 0 then null$a$,
                  $a$case when d.rule_version >= 2 and coalesce((d.thresholds->>'avis_client')::int, 0) <= 0 then null$a$);
  if v !~ $r$d\.rule_version >= 2 and coalesce\(\(d\.thresholds->>'avis_client'\)$r$ then raise exception 'remplacement non appliqué'; end if;
  execute v;
end $d$;
