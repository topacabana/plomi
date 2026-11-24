-- PG-19 — Interruption d'intervention : le motif « Autre » doit être expliqué (10 caractères minimum).
-- Refusé sans explication ou avec une explication trop courte ; accepté avec une vraie explication,
-- reprise dans la notification « Anomalie » envoyée aux gestionnaires.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(6);
select tests.seed();

-- Le gestionnaire A attribue le mandat e…01 à l'expert c…01 (CGU acceptées)
select tests.as_user('b0000000-0000-4000-8000-000000000001');
select public.manual_assign_mandates('[{"mandate_id":"e0000000-0000-4000-8000-000000000001","expert_id":"c0000000-0000-4000-8000-000000000001"}]');

select tests.as_user('b0000000-0000-4000-8000-000000000003');
select throws_ok($$ select public.expert_quit_intervention('e0000000-0000-4000-8000-000000000001', 'Autre', null) $$,
  'Motif « Autre » : expliquez la raison dans le champ Détails (10 caractères minimum)',
  'motif « Autre » sans explication : refusé');
select throws_ok($$ select public.expert_quit_intervention('e0000000-0000-4000-8000-000000000001', 'Autre', '  court  ') $$,
  'Motif « Autre » : expliquez la raison dans le champ Détails (10 caractères minimum)',
  'motif « Autre » avec moins de 10 caractères (espaces retirés) : refusé');
select throws_ok($$ select public.expert_quit_intervention('e0000000-0000-4000-8000-000000000001', 'Fatigue', 'Je suis trop fatigué') $$,
  'Choisissez un motif d''interruption',
  'motif hors liste : refusé');
select lives_ok($$ select public.expert_quit_intervention('e0000000-0000-4000-8000-000000000001', 'Autre', 'Chien agressif dans le jardin') $$,
  'motif « Autre » expliqué : interruption acceptée');

select tests.as_postgres();
select is((select status::text from public.mandates where id = 'e0000000-0000-4000-8000-000000000001'), 'drop_pending',
  'le mandat est remis en liste de drop');
select ok(exists(select 1 from public.notifications
                  where user_id = 'b0000000-0000-4000-8000-000000000001'
                    and mandate_id = 'e0000000-0000-4000-8000-000000000001'
                    and title = 'Anomalie : intervention interrompue'
                    and body like '%Autre — Chien agressif dans le jardin%'),
  'le gestionnaire reçoit la notification avec le motif « Autre — … »');

select * from finish();
rollback;
