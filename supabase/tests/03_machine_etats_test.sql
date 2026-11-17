-- Machine à états du mandat : seules les transitions prévues sont acceptées.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(4);
select tests.seed();
select tests.as_user('b0000000-0000-4000-8000-000000000001');

select throws_like(
  $$ select public.transition_mandate_status('e0000000-0000-4000-8000-000000000004', 'assigned', 'c0000000-0000-4000-8000-000000000001') $$,
  'Transition interdite%', 'un brouillon ne peut pas être attribué directement');
select lives_ok(
  $$ select public.transition_mandate_status('e0000000-0000-4000-8000-000000000004', 'drop_pending') $$,
  'un brouillon peut passer en liste de drop');
select throws_like(
  $$ select public.transition_mandate_status('e0000000-0000-4000-8000-000000000004', 'closed') $$,
  'Motif obligatoire%', 'une clôture sans suite exige un motif');
select throws_like(
  $$ select public.transition_mandate_status('e0000000-0000-4000-8000-000000000001', 'assigned', null) $$,
  'Un expert est requis%', 'une attribution exige un expert');

select tests.as_postgres();
select * from finish();
rollback;
