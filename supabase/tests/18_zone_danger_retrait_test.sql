-- Zone de danger : un gestionnaire retiré perd ses droits ; la purge met les fichiers des mandats en file de suppression.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(6);
select tests.seed();
-- deux gestionnaires dans l'organisation A : le superviseur (seed) et un second, créé ici
update public.user_profiles set is_supervisor = true where id = 'b0000000-0000-4000-8000-000000000001';
insert into auth.users (id, email, aud, role) values
  ('b0000000-0000-4000-8000-0000000000aa', 'second.gestionnaire@test.local', 'authenticated', 'authenticated')
on conflict (id) do nothing;
insert into public.user_profiles (id, email, role, organization_id) values
  ('b0000000-0000-4000-8000-0000000000aa', 'second.gestionnaire@test.local', 'gestionnaire_assurance', 'a0000000-0000-4000-8000-000000000001')
on conflict (id) do update set role = excluded.role, organization_id = excluded.organization_id;

select tests.as_user('b0000000-0000-4000-8000-0000000000aa');
select ok(public.is_manager(), 'avant retrait : le second gestionnaire a les droits');

select tests.as_user('b0000000-0000-4000-8000-000000000001');
select lives_ok($$ select public.supervisor_remove_manager('b0000000-0000-4000-8000-0000000000aa') $$, 'le superviseur retire le gestionnaire');

select tests.as_user('b0000000-0000-4000-8000-0000000000aa');
select ok(not public.is_manager(), 'après retrait : plus de droits gestionnaire');
select is((select count(*)::int from public.mandates), 0, 'après retrait : aucun mandat visible');

select tests.as_user('b0000000-0000-4000-8000-000000000001');
select public.transition_mandate_status('e0000000-0000-4000-8000-000000000004', 'closed', null, 'Doublon');
create temp table p1 as select public.supervisor_archive_mandates(null, true) as r;
select is((select r->>'deleted' from p1), '1', 'la purge supprime le mandat clôturé');
select ok((select r ? 'files_queued' from p1), 'la purge indique les fichiers mis en file de suppression');

select * from finish();
rollback;
