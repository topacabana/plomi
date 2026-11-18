-- Jeu d'essai de l'attribution manuelle, écarts 1 et 2 (corrigés le 18/11/2026) :
-- un expert suspendu et un expert hors base donnent deux messages distincts,
-- et chaque erreur du compte rendu porte le nom de l'expert.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(7);
select tests.seed();

-- Expert c…02 suspendu ; expert c…01 retiré de la base de l'organisation A
update public.experts set status_experts = 'suspendu' where id = 'c0000000-0000-4000-8000-000000000002';
delete from public.org_experts where organization_id = 'a0000000-0000-4000-8000-000000000001'
   and expert_id = 'c0000000-0000-4000-8000-000000000001';

select tests.as_user('b0000000-0000-4000-8000-000000000001');  -- gestionnaire A
create temp table r as select public.manual_assign_mandates('[
  {"mandate_id":"e0000000-0000-4000-8000-000000000001","expert_id":"c0000000-0000-4000-8000-000000000002"},
  {"mandate_id":"e0000000-0000-4000-8000-000000000001","expert_id":"c0000000-0000-4000-8000-000000000001"}
]') as res;

select is((select (res->>'assigned')::int from r), 0, 'aucun des deux couples n''est attribué');
select is((select jsonb_array_length(res->'errors') from r), 2, 'deux erreurs pour le même mandat');
select is((select res->'errors'->0->>'error' from r), 'Expert suspendu (Thierry Test)',
  'expert suspendu : message propre, avec le nom de l''expert');
select is((select res->'errors'->1->>'error' from r), 'Recrutez d''abord l''expert dans votre base (Sophie Test)',
  'expert hors base : message propre, avec le nom de l''expert');
select is((select res->'errors'->1->>'expert_name' from r), 'Sophie Test', 'le nom de l''expert est aussi renvoyé à part');

select tests.as_postgres();
select ok(not has_function_privilege('anon', 'public.is_supervisor()', 'execute'),
  'is_supervisor() n''est pas exécutable sans connexion');
select ok(not has_function_privilege('authenticated', 'public.create_expert_record(uuid,uuid,jsonb)', 'execute'),
  'create_expert_record() est réservée au serveur');

select * from finish();
rollback;
