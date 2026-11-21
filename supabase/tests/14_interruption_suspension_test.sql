-- Interruption d'intervention : l'expert qui quitte sans rapport est suspendu jusqu'à régularisation.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(7);
select tests.seed();

-- Le gestionnaire A attribue le mandat e…01 à l'expert c…01 (CGU acceptées)
select tests.as_user('b0000000-0000-4000-8000-000000000001');
select public.manual_assign_mandates('[{"mandate_id":"e0000000-0000-4000-8000-000000000001","expert_id":"c0000000-0000-4000-8000-000000000001"}]');

-- L'expert quitte l'intervention avec un motif
select tests.as_user('b0000000-0000-4000-8000-000000000003');
select lives_ok($$ select public.expert_quit_intervention('e0000000-0000-4000-8000-000000000001', 'Insalubrité', 'Logement inaccessible') $$,
  'l''expert peut interrompre l''intervention avec un motif');
select is((select count(*)::int from public.available_mandates_for_expert), 0,
  'expert suspendu : plus aucun mandat sur la carte');

select tests.as_postgres();
select is((select status_experts::text from public.experts where id = 'c0000000-0000-4000-8000-000000000001'), 'suspendu',
  'l''expert est suspendu après l''interruption');
select ok((select suspension_reason from public.experts where id = 'c0000000-0000-4000-8000-000000000001') like 'Intervention interrompue sans rapport%',
  'le motif de suspension est tracé');
select is((select status::text from public.mandates where id = 'e0000000-0000-4000-8000-000000000001'), 'drop_pending',
  'le mandat est remis en drop');

-- Le gestionnaire de l'organisation du mandat voit l'expert dans sa base et peut lever la suspension
select ok(exists(select 1 from public.org_experts where organization_id = 'a0000000-0000-4000-8000-000000000001'
                 and expert_id = 'c0000000-0000-4000-8000-000000000001'), 'l''expert est rattaché à l''organisation du mandat');
select tests.as_user('b0000000-0000-4000-8000-000000000001');
select lives_ok($$ select public.lift_expert_suspension('c0000000-0000-4000-8000-000000000001', 'Régularisé') $$,
  'le gestionnaire lève la suspension');

select * from finish();
rollback;
