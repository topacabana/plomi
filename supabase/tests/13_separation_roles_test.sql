-- Séparation des rôles : la carte de l'app expert (vue available_mandates_for_expert) est réservée aux experts.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(3);
select tests.seed();

-- Rendre visible sur la carte un mandat de l'organisation A, ouvert à tous les experts
update public.mandates set visible_on_map = true, target_list_ids = '{}' where id = 'e0000000-0000-4000-8000-000000000002';

-- Gestionnaire de l'organisation A : rien sur la carte expert, même pour ses propres mandats
select tests.as_user('b0000000-0000-4000-8000-000000000001');
select is((select count(*)::int from public.available_mandates_for_expert), 0,
  'un gestionnaire ne voit aucun mandat via la carte expert');
select ok(not public.is_expert(), 'is_expert() est faux pour un gestionnaire');

-- Expert : le mandat apparaît
select tests.as_user('b0000000-0000-4000-8000-000000000003');
select ok((select count(*) from public.available_mandates_for_expert where id = 'e0000000-0000-4000-8000-000000000002') = 1,
  'l''expert voit le mandat sur sa carte');

select * from finish();
rollback;
