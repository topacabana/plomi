-- Fiche mandat : liens RDF ↔ RDFS et possibilité de créer le RDFS.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(7);
select tests.seed();

select tests.as_user('b0000000-0000-4000-8000-000000000001');
create temp table l0 as select public.manager_rdfs_links('e0000000-0000-4000-8000-000000000001') as r;
select is((select r->>'can_create' from l0), 'false', 'sans rapport reçu, pas de RDFS possible');
select is((select r->>'reason' from l0), 'Le rapport RDF doit d''abord être reçu.', 'le motif est donné');

select tests.as_postgres();
insert into public.rdf_reports (mandate_id, status, created_by, submitted_at)
values ('e0000000-0000-4000-8000-000000000001', 'submitted', 'b0000000-0000-4000-8000-000000000003', now());

select tests.as_user('b0000000-0000-4000-8000-000000000001');
create temp table l1 as select public.manager_rdfs_links('e0000000-0000-4000-8000-000000000001') as r;
select is((select r->>'can_create' from l1), 'true', 'rapport reçu : RDFS possible');
create temp table c1 as select public.manager_create_rdfs_followup('e0000000-0000-4000-8000-000000000001', 'drop') as r;
create temp table l2 as select public.manager_rdfs_links('e0000000-0000-4000-8000-000000000001') as r;
select is((select r->'child'->>'reference' from l2), 'TEST-RDF-S', 'le RDF pointe vers son RDFS');
select is((select r->>'can_create' from l2), 'false', 'un seul RDFS par RDF');
create temp table l3 as select public.manager_rdfs_links((select (r->>'mandate_id')::uuid from c1)) as r;
select is((select r->'parent'->>'reference' from l3), 'TEST-RDF', 'le RDFS pointe vers son RDF');

select tests.as_user('b0000000-0000-4000-8000-000000000002');
select throws_ok($$ select public.manager_rdfs_links('e0000000-0000-4000-8000-000000000001') $$,
  'Mandat introuvable dans votre organisation', 'autre organisation refusée');

select * from finish();
rollback;
