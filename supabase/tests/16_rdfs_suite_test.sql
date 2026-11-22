-- RDFS en suite d'un RDF : mandat RDFS lié, droppé (sans redrop) ou attribué, une seule fois par RDF.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(12);
select tests.seed();

-- Sans rapport RDF reçu : refus
select tests.as_user('b0000000-0000-4000-8000-000000000001');
select is((public.manager_create_rdfs_followup('e0000000-0000-4000-8000-000000000001', 'drop'))->>'ok', 'false',
  'pas de RDFS tant que le rapport RDF n''est pas reçu');

-- Rapport RDF envoyé par l'expert
select tests.as_postgres();
insert into public.rdf_reports (mandate_id, status, created_by, submitted_at)
values ('e0000000-0000-4000-8000-000000000001', 'submitted', 'b0000000-0000-4000-8000-000000000003', now());
update public.mandates set insurer_file_number = 'SIN-2026-0042' where id = 'e0000000-0000-4000-8000-000000000001';

-- Un RDFS ne peut pas lui-même donner un RDFS ; un autre assureur ne peut rien faire
select tests.as_user('b0000000-0000-4000-8000-000000000001');
select is((public.manager_create_rdfs_followup('e0000000-0000-4000-8000-000000000002', 'drop'))->>'ok', 'false',
  'seul un RDF peut donner un RDFS');
select tests.as_user('b0000000-0000-4000-8000-000000000002');
select is((public.manager_create_rdfs_followup('e0000000-0000-4000-8000-000000000001', 'drop'))->>'ok', 'false',
  'un gestionnaire d''une autre organisation est refusé');

-- Drop RDFS
select tests.as_user('b0000000-0000-4000-8000-000000000001');
create temp table r1 as select public.manager_create_rdfs_followup('e0000000-0000-4000-8000-000000000001', 'drop') as r;
select is((select r->>'ok' from r1), 'true', 'le RDFS de suite est créé');
select tests.as_postgres();
select is((select mandate_type::text from public.mandates where id = (select (r->>'mandate_id')::uuid from r1)), 'rdfs', 'type RDFS');
select is((select status::text from public.mandates where id = (select (r->>'mandate_id')::uuid from r1)), 'dropped', 'statut dropped, pas redrop');
select is((select redrop_count from public.mandates where id = (select (r->>'mandate_id')::uuid from r1)), 0, 'aucun redrop compté');
select is((select reference from public.mandates where id = (select (r->>'mandate_id')::uuid from r1)), 'TEST-RDF-S', 'référence fille');
select is((select insurer_file_number from public.mandates where id = (select (r->>'mandate_id')::uuid from r1)), 'SIN-2026-0042',
  'même n° de dossier assureur');
select is((select status::text from public.mandates where id = 'e0000000-0000-4000-8000-000000000001'), 'drop_pending',
  'le RDF d''origine n''est pas modifié');

-- Une seule suite par RDF
select tests.as_user('b0000000-0000-4000-8000-000000000001');
select is((public.manager_create_rdfs_followup('e0000000-0000-4000-8000-000000000001', 'drop'))->>'ok', 'false',
  'un seul RDFS de suite par RDF');

-- Attribution directe (après annulation du premier)
select tests.as_postgres();
update public.mandates set status = 'cancelled' where id = (select (r->>'mandate_id')::uuid from r1);
select tests.as_user('b0000000-0000-4000-8000-000000000001');
select is((select assigned_expert_id from public.mandates
            where id = ((public.manager_create_rdfs_followup('e0000000-0000-4000-8000-000000000001', 'assign',
                                                              'c0000000-0000-4000-8000-000000000001'))->>'mandate_id')::uuid),
          'c0000000-0000-4000-8000-000000000001'::uuid, 'attribution directe du RDFS à un expert de la base');

select * from finish();
rollback;
