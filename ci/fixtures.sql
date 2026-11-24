-- PLOMI — Jeu de données des tests automatiques (CI).
-- Crée le schéma `tests` avec :
--   tests.seed()            : deux assureurs, deux gestionnaires, deux experts, des mandats ;
--   tests.as_user(uuid)     : prend l'identité d'un compte (jeton simulé) ;
--   tests.as_postgres()     : revient au super-utilisateur.
-- Chaque fichier de test appelle tests.seed() dans sa transaction, puis tout est annulé (rollback).
create schema if not exists tests;

create or replace function tests.as_user(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function tests.as_postgres() returns void language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims', '', true);
end $$;

-- Identifiants fixes, lisibles dans les tests
--   a0..   organisations      b0..   comptes (auth.users / user_profiles)
--   c0..   experts            d0..   bénéficiaires        e0..   mandats
create or replace function tests.seed() returns void language plpgsql as $$
begin
  insert into public.organizations (id, name, type) values
    ('a0000000-0000-4000-8000-000000000001', 'Assureur A (test)', 'insurance'),
    ('a0000000-0000-4000-8000-000000000002', 'Assureur B (test)', 'insurance'),
    ('a0000000-0000-4000-8000-000000000003', 'Cabinet experts (test)', 'expert_company');

  insert into auth.users (id, email, aud, role) values
    ('b0000000-0000-4000-8000-000000000001', 'gestionnaire.a@test.local', 'authenticated', 'authenticated'),
    ('b0000000-0000-4000-8000-000000000002', 'gestionnaire.b@test.local', 'authenticated', 'authenticated'),
    ('b0000000-0000-4000-8000-000000000003', 'expert.cgu@test.local',     'authenticated', 'authenticated'),
    ('b0000000-0000-4000-8000-000000000004', 'expert.sans.cgu@test.local','authenticated', 'authenticated')
  on conflict (id) do nothing;

  -- Les deux gestionnaires de référence sont superviseurs (accès à toutes les fonctions) ;
  -- le test 22 crée un gestionnaire simple pour vérifier les restrictions.
  insert into public.user_profiles (id, email, role, organization_id, is_supervisor) values
    ('b0000000-0000-4000-8000-000000000001', 'gestionnaire.a@test.local', 'gestionnaire_assurance', 'a0000000-0000-4000-8000-000000000001', true),
    ('b0000000-0000-4000-8000-000000000002', 'gestionnaire.b@test.local', 'gestionnaire_assurance', 'a0000000-0000-4000-8000-000000000002', true),
    ('b0000000-0000-4000-8000-000000000003', 'expert.cgu@test.local',     'expert', 'a0000000-0000-4000-8000-000000000003', false),
    ('b0000000-0000-4000-8000-000000000004', 'expert.sans.cgu@test.local','expert', 'a0000000-0000-4000-8000-000000000003', false)
  on conflict (id) do update set role = excluded.role, organization_id = excluded.organization_id, is_supervisor = excluded.is_supervisor;

  insert into public.experts (id, user_id, organization_id, company_name, first_name, last_name, status_experts, cgu_version, cgu_accepted_at) values
    ('c0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000003',
     'Expert CGU SARL', 'Sophie', 'Test', 'connecte', (select version from public.cgu_versions where is_current), now()),
    ('c0000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-000000000004', 'a0000000-0000-4000-8000-000000000003',
     'Expert sans CGU SARL', 'Thierry', 'Test', 'connecte', null, null);

  insert into public.org_experts (organization_id, expert_id) values
    ('a0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000001'),
    ('a0000000-0000-4000-8000-000000000001', 'c0000000-0000-4000-8000-000000000002')
  on conflict do nothing;

  insert into public.beneficiaries (id, organization_id, first_name, last_name, mobile_phone) values
    ('d0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001', 'Jeanne', 'Martin', '0600000001'),
    ('d0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000002', 'Paul', 'Durand', '0600000002');

  insert into public.mandates (id, reference, insurance_org_id, created_by_user_id, beneficiary_id, mandate_type, address_line_1, postal_code, city, status, latitude, longitude) values
    ('e0000000-0000-4000-8000-000000000001', 'TEST-RDF',  'a0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001',
     'd0000000-0000-4000-8000-000000000001', 'rdf',  '1 rue du Test', '78310', 'Coignières', 'drop_pending', 48.75, 1.92),
    ('e0000000-0000-4000-8000-000000000002', 'TEST-RDFS', 'a0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001',
     'd0000000-0000-4000-8000-000000000001', 'rdfs', '1 rue du Test', '78310', 'Coignières', 'drop_pending', 48.75, 1.92),
    ('e0000000-0000-4000-8000-000000000003', 'TEST-B',    'a0000000-0000-4000-8000-000000000002', 'b0000000-0000-4000-8000-000000000002',
     'd0000000-0000-4000-8000-000000000002', 'rdf',  '2 rue du Test', '75001', 'Paris', 'drop_pending', 48.86, 2.34),
    ('e0000000-0000-4000-8000-000000000004', 'TEST-DRAFT','a0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000001',
     'd0000000-0000-4000-8000-000000000001', 'rdf',  '3 rue du Test', '78310', 'Coignières', 'draft', 48.75, 1.92);
end $$;

-- Les tests appellent ces fonctions et pgTAP sous l'identité « authenticated »
grant usage on schema tests to authenticated;
grant execute on all functions in schema tests to authenticated;
