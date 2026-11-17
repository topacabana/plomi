-- Sécurité du schéma : RLS partout, fonctions sensibles fermées aux visiteurs non connectés.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(9);

select has_table('public', 'mandates', 'la table des mandats existe');
select has_table('public', 'cgu_versions', 'la table des versions de CGU existe (RGPD C7)');
select has_table('public', 'destructive_consents', 'la table des accords destructifs existe (RDFS)');

select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  0, 'toutes les tables publiques ont la sécurité au niveau des lignes (RLS) activée');

select ok(not has_function_privilege('anon', 'public.save_mandate_form(uuid,jsonb,boolean,uuid[],boolean)', 'execute'),
  'un visiteur non connecté ne peut pas enregistrer de mandat');
select ok(not has_function_privilege('anon', 'public.manual_assign_mandates(jsonb)', 'execute'),
  'un visiteur non connecté ne peut pas attribuer de mandat');
select ok(not has_function_privilege('anon', 'public.manager_redrop_mandate(uuid,text)', 'execute'),
  'un visiteur non connecté ne peut pas redroper un mandat');
select ok(not has_function_privilege('anon', 'public.expert_record_destructive_consent(uuid,text,text,text,text)', 'execute'),
  'un visiteur non connecté ne peut pas enregistrer un accord destructif');
select is((select count(*)::int from public.cgu_versions where is_current), 1,
  'une et une seule version des CGU est en vigueur');

select * from finish();
rollback;
