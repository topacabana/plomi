-- Fiche mandat : coordonnées du bénéficiaire, cloisonnées par organisation (RLS).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(3);
select tests.seed();

select tests.as_user('b0000000-0000-4000-8000-000000000001');
select is(public.mandate_beneficiary_contact('e0000000-0000-4000-8000-000000000001')->>'last_name', 'Martin',
  'gestionnaire A : bénéficiaire de son mandat');
select is(public.mandate_beneficiary_contact('e0000000-0000-4000-8000-000000000003'), '{}'::jsonb,
  'gestionnaire A : rien sur un mandat de l''assureur B');

select tests.as_user('b0000000-0000-4000-8000-000000000002');
select is(public.mandate_beneficiary_contact('e0000000-0000-4000-8000-000000000003')->>'first_name', 'Paul',
  'gestionnaire B : bénéficiaire de son mandat');

select * from finish();
rollback;
