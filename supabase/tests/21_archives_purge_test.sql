-- PG-21 — Archives : suppression après téléchargement, durée minimale de conservation de 5 ans.
--   mode « older5 » : seules les archives clôturées depuis plus de 5 ans sont supprimées ;
--   mode « all »    : toutes les archives demandées sont supprimées (choix explicite du gestionnaire) ;
--   réservé aux gestionnaires, limité à leur organisation et aux mandats clôturés ou annulés ;
--   l'opération est tracée (archives_purged).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(10);
select tests.seed();

-- Deux archives de l'assureur A : TEST-DRAFT clôturé aujourd'hui, TEST-RDFS clôturé il y a 6 ans.
-- TEST-RDF reste en liste de drop (non archivé) ; TEST-B appartient à l'assureur B.
update public.mandates set status = 'closed', closed_at = now()
 where id = 'e0000000-0000-4000-8000-000000000004';
update public.mandates set status = 'closed', closed_at = now() - interval '6 years'
 where id = 'e0000000-0000-4000-8000-000000000002';
update public.mandates set status = 'closed', closed_at = now() - interval '6 years'
 where id = 'e0000000-0000-4000-8000-000000000003';

-- Un expert ne peut pas purger
select tests.as_user('b0000000-0000-4000-8000-000000000003');
select throws_ok($$ select public.manager_archives_purge(array['e0000000-0000-4000-8000-000000000002']::uuid[], 'all') $$,
  '42501', 'Action réservée aux gestionnaires', 'un expert ne peut pas supprimer d''archives');

select tests.as_user('b0000000-0000-4000-8000-000000000001');
select throws_ok($$ select public.manager_archives_purge(array['e0000000-0000-4000-8000-000000000002']::uuid[], 'tout') $$,
  'Mode inconnu (all ou older5)', 'mode inconnu : refusé');

-- Mode « plus de 5 ans » : l'archive récente est conservée, l'ancienne supprimée ;
-- le mandat non archivé et celui de l'assureur B sont ignorés.
create temp table r1 as select public.manager_archives_purge(array[
  'e0000000-0000-4000-8000-000000000002', 'e0000000-0000-4000-8000-000000000004',
  'e0000000-0000-4000-8000-000000000001', 'e0000000-0000-4000-8000-000000000003']::uuid[], 'older5') r;
select is((select (r->>'deleted')::int from r1), 1, 'older5 : une archive de plus de 5 ans supprimée');
select is((select (r->>'kept')::int from r1), 2, 'older5 : l''archive récente et le mandat en cours sont conservés');

select tests.as_postgres();
select ok(not exists(select 1 from public.mandates where id = 'e0000000-0000-4000-8000-000000000002'),
  'l''archive de 6 ans n''existe plus');
select ok(exists(select 1 from public.mandates where id = 'e0000000-0000-4000-8000-000000000004'),
  'l''archive de moins de 5 ans est toujours là');
select ok(exists(select 1 from public.mandates where id = 'e0000000-0000-4000-8000-000000000001' and status::text = 'drop_pending'),
  'un mandat non archivé n''est jamais supprimé');
select ok(exists(select 1 from public.mandates where id = 'e0000000-0000-4000-8000-000000000003'),
  'l''archive d''un autre assureur n''est jamais supprimée');

-- Mode « toutes » : l'archive récente est supprimée sur choix explicite
select tests.as_user('b0000000-0000-4000-8000-000000000001');
select is((public.manager_archives_purge(array['e0000000-0000-4000-8000-000000000004']::uuid[], 'all'))->>'deleted', '1',
  'all : l''archive de moins de 5 ans est supprimée');

select tests.as_postgres();
select is((select count(*)::int from public.activity_logs
            where action = 'archives_purged' and user_id = 'b0000000-0000-4000-8000-000000000001'), 2,
  'chaque suppression est tracée dans le journal');

select * from finish();
rollback;
