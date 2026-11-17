-- Redrop depuis la fiche mandat : passe par une fonction serveur qui exige un motif.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(4);
select tests.seed();
select tests.as_user('b0000000-0000-4000-8000-000000000001');

select is((public.manager_redrop_mandate('e0000000-0000-4000-8000-000000000001', '  '))->>'error',
  'Saisissez la justification du redrop.', 'le redrop exige une justification');
select is((public.manager_redrop_mandate('e0000000-0000-4000-8000-000000000001', 'Expert indisponible'))->>'ok',
  'true', 'le redrop avec justification est accepté');

select tests.as_postgres();
select is((select status::text from public.mandates where id = 'e0000000-0000-4000-8000-000000000001'),
  'redrop', 'le mandat est en redrop');
select ok((select redrop_count >= 1 from public.mandates where id = 'e0000000-0000-4000-8000-000000000001'),
  'le compteur de redrops est incrémenté');

select * from finish();
rollback;
