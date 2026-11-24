-- Abandon après prise en charge (bouton « Abandonner ») : suspension jusqu'à régularisation, comme l'interruption.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(5);
select tests.seed();

select tests.as_user('b0000000-0000-4000-8000-000000000001');
select public.manual_assign_mandates('[{"mandate_id":"e0000000-0000-4000-8000-000000000001","expert_id":"c0000000-0000-4000-8000-000000000001"}]');

select tests.as_user('b0000000-0000-4000-8000-000000000003');
select throws_ok($$ select public.expert_abandon_mandate('e0000000-0000-4000-8000-000000000001', '  ') $$,
  'Le motif d''abandon est obligatoire', 'motif obligatoire');
select lives_ok($$ select public.expert_abandon_mandate('e0000000-0000-4000-8000-000000000001', 'Empêchement') $$,
  'l''expert abandonne le mandat pris en charge');
select ok(not has_function_privilege('authenticated', 'public.expert_abandon_internal(uuid,text,text)', 'execute'),
  'la fonction interne n''est pas appelable directement');

select tests.as_postgres();
select is((select status_experts::text from public.experts where id = 'c0000000-0000-4000-8000-000000000001'), 'suspendu',
  'abandon après prise en charge : expert suspendu');
select ok((select suspension_reason from public.experts where id = 'c0000000-0000-4000-8000-000000000001') like 'Mandat abandonné après prise en charge%',
  'motif de suspension tracé');

select * from finish();
rollback;
