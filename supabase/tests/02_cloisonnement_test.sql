-- Cloisonnement entre organisations : un gestionnaire ne voit ni ne modifie les mandats d'un autre assureur.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(4);
select tests.seed();

select tests.as_user('b0000000-0000-4000-8000-000000000001');  -- gestionnaire A
select is((select count(*)::int from public.mandates where reference = 'TEST-RDF'), 1,
  'le gestionnaire A voit le mandat de son organisation');
select is((select count(*)::int from public.mandates where reference = 'TEST-B'), 0,
  'le gestionnaire A ne voit pas le mandat de l''assureur B');
update public.mandates set city = 'Piraté' where reference = 'TEST-B';
select tests.as_postgres();
select is((select city from public.mandates where reference = 'TEST-B'), 'Paris',
  'le gestionnaire A ne peut pas modifier un mandat de l''assureur B');

select tests.as_user('b0000000-0000-4000-8000-000000000002');  -- gestionnaire B
select is((public.manager_redrop_mandate('e0000000-0000-4000-8000-000000000001', 'test'))->>'error',
  'Mandat introuvable dans votre organisation.',
  'le gestionnaire B ne peut pas redroper un mandat de l''assureur A');

select tests.as_postgres();
select * from finish();
rollback;
