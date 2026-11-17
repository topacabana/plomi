-- RGPD C7 : un expert ne reçoit un mandat que s'il a accepté les CGU en vigueur.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(5);
select tests.seed();

select tests.as_user('b0000000-0000-4000-8000-000000000001');  -- gestionnaire A
select is(
  (public.manual_assign_mandates('[{"mandate_id":"e0000000-0000-4000-8000-000000000001","expert_id":"c0000000-0000-4000-8000-000000000002"}]'))->>'assigned',
  '0', 'attribution refusée à l''expert qui n''a pas accepté les CGU');
select is(
  (public.manual_assign_mandates('[{"mandate_id":"e0000000-0000-4000-8000-000000000001","expert_id":"c0000000-0000-4000-8000-000000000001"}]'))->>'assigned',
  '1', 'attribution acceptée pour l''expert qui a accepté les CGU');

select tests.as_user('b0000000-0000-4000-8000-000000000004');  -- l'expert sans CGU les accepte
select is((public.expert_cgu_status())->>'needs_acceptance', 'true', 'l''expert sans CGU doit les accepter à la connexion');
select lives_ok($$ select public.expert_accept_cgu((select version from public.cgu_versions where is_current)) $$,
  'l''expert accepte la version en vigueur');

select tests.as_user('b0000000-0000-4000-8000-000000000001');
select is(
  (public.manual_assign_mandates('[{"mandate_id":"e0000000-0000-4000-8000-000000000002","expert_id":"c0000000-0000-4000-8000-000000000002"}]'))->>'assigned',
  '1', 'après acceptation, l''expert peut recevoir un mandat');

select tests.as_postgres();
select * from finish();
rollback;
