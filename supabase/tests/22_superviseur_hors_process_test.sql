-- PG-22 — Séparation gestionnaire / superviseur.
--   Le gestionnaire simple garde le traitement normal du dossier (drop, attribution, redrop) ;
--   les actions hors process sont réservées au superviseur : KPIs, recrutement, purge des archives,
--   réattribution, listes d'experts, et les transitions demandées directement par l'application
--   (suppression, pause, retrait du drop).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(13);
select tests.seed();

-- Un gestionnaire simple (non superviseur) dans l'organisation A
insert into auth.users (id, email, aud, role)
values ('b0000000-0000-4000-8000-0000000000c1', 'gestionnaire.simple@test.local', 'authenticated', 'authenticated');
insert into public.user_profiles (id, email, role, organization_id, is_supervisor)
values ('b0000000-0000-4000-8000-0000000000c1', 'gestionnaire.simple@test.local', 'gestionnaire_assurance',
        'a0000000-0000-4000-8000-000000000001', false)
on conflict (id) do update set role = excluded.role, organization_id = excluded.organization_id, is_supervisor = false;

select tests.as_user('b0000000-0000-4000-8000-0000000000c1');

-- Fonctions réservées au superviseur
select throws_ok($$ select public.kpi_page_data() $$, '42501', 'Réservé au superviseur',
  'KPIs : refusés au gestionnaire simple');
select throws_ok($$ select public.recruit_experts(array[]::uuid[]) $$, '42501', 'Réservé au superviseur',
  'recrutement : refusé au gestionnaire simple');
select throws_ok($$ select public.manager_archives_purge(array['e0000000-0000-4000-8000-000000000004']::uuid[], 'all') $$,
  '42501', 'Réservé au superviseur', 'purge des archives : refusée au gestionnaire simple');
select is((public.manager_reassign_mandate('e0000000-0000-4000-8000-000000000001', null, 'test'))->>'error',
  'Réservé au superviseur.', 'réattribution : refusée au gestionnaire simple');

-- Listes d'experts : lecture oui, écriture directe non
select lives_ok($$ select count(*) from public.expert_lists $$, 'listes d''experts : lecture autorisée');
select throws_ok($$ insert into public.expert_lists (organization_id, name)
                    values ('a0000000-0000-4000-8000-000000000001', 'Liste interdite') $$,
  '42501', null, 'listes d''experts : création directe refusée au gestionnaire simple');

-- Le tableau de bord indique le rôle à l'application
select is((public.dashboard_bundle())->>'is_supervisor', 'false', 'dashboard_bundle : gestionnaire simple');

-- Transitions demandées par l'application (simulation de l'appel RPC)
select set_config('request.path', '/rpc/transition_mandate_status', true);
select lives_ok($$ select public.transition_mandate_status('e0000000-0000-4000-8000-000000000001', 'dropped') $$,
  'traitement normal : le gestionnaire simple droppe le mandat');
select throws_ok($$ select public.transition_mandate_status('e0000000-0000-4000-8000-000000000001', 'drop_pending') $$,
  '42501', null, 'retirer du drop : refusé au gestionnaire simple');
select throws_ok($$ select public.transition_mandate_status('e0000000-0000-4000-8000-000000000001', 'suspended', null, 'pause') $$,
  '42501', null, 'mettre en pause : refusé au gestionnaire simple');
select throws_ok($$ select public.transition_mandate_status('e0000000-0000-4000-8000-000000000001', 'cancelled') $$,
  '42501', null, 'supprimer : refusé au gestionnaire simple');

-- Le superviseur garde toutes les fonctions
select tests.as_postgres();
delete from public.mandate_locks where mandate_id = 'e0000000-0000-4000-8000-000000000001';
select tests.as_user('b0000000-0000-4000-8000-000000000001');
select set_config('request.path', '/rpc/transition_mandate_status', true);
select lives_ok($$ select public.transition_mandate_status('e0000000-0000-4000-8000-000000000001', 'drop_pending') $$,
  'retirer du drop : autorisé au superviseur');
select is((public.dashboard_bundle())->>'is_supervisor', 'true', 'dashboard_bundle : superviseur');

select * from finish();
rollback;
