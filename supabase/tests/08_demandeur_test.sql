-- Création de mandat : l'organisme demandeur (assureur, entreprise tierce ou particulier) est obligatoire.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(8);
select tests.seed();

insert into public.insurers (id, organization_id, name)
values ('f0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001', 'Assureur test');

select tests.as_user('b0000000-0000-4000-8000-000000000001');

select throws_like(
  $$select public.save_mandate_form('e0000000-0000-4000-8000-000000000004', '{"comments":"x"}'::jsonb)$$,
  'Organisme demandeur obligatoire%', 'sans demandeur : enregistrement refusé');

select throws_like(
  $$select public.save_mandate_form('e0000000-0000-4000-8000-000000000004', '{"requester_type":"insurer"}'::jsonb)$$,
  '%sélectionnez l''assureur%', 'assureur coché sans assureur choisi : refusé');

select lives_ok(
  $$select public.save_mandate_form('e0000000-0000-4000-8000-000000000004',
      '{"requester_type":"insurer","insurer_id":"f0000000-0000-4000-8000-000000000001"}'::jsonb)$$,
  'assureur de l''organisation : accepté');

select throws_like(
  $$select public.save_mandate_form('e0000000-0000-4000-8000-000000000004',
      '{"requester_type":"third_party","requester_company_name":"ACME SAS","requester_trade_name":"ACME",
        "requester_siret":"12345678901234","requester_contact_first_name":"Léa","requester_contact_last_name":"Martin",
        "requester_contact_phone":"0600000000","requester_contact_email":"lea@acme.fr"}'::jsonb)$$,
  '%le logo est obligatoire%', 'entreprise tierce incomplète (sans logo) : refusée');

select throws_like(
  $$select public.save_mandate_form('e0000000-0000-4000-8000-000000000004',
      '{"requester_type":"third_party","requester_company_name":"ACME SAS","requester_trade_name":"ACME",
        "requester_siret":"12345678901234","requester_contact_first_name":"Léa","requester_contact_last_name":"Martin",
        "requester_contact_phone":"0600000000","requester_contact_email":"lea@acme.fr",
        "requester_logo_url":"data:text/html;base64,PHNjcmlwdD4="}'::jsonb)$$,
  '%doit être une image%', 'logo qui n''est pas une image : refusé');

select lives_ok(
  $$select public.save_mandate_form('e0000000-0000-4000-8000-000000000004',
      '{"requester_type":"third_party","requester_company_name":"ACME SAS","requester_trade_name":"ACME",
        "requester_siret":"12345678901234","requester_contact_first_name":"Léa","requester_contact_last_name":"Martin",
        "requester_contact_phone":"0600000000","requester_contact_email":"lea@acme.fr",
        "requester_logo_url":"https://exemple.fr/logo.png"}'::jsonb)$$,
  'entreprise tierce complète : acceptée');

select tests.as_postgres();
select is((select insurer_id from public.mandates where id = 'e0000000-0000-4000-8000-000000000004'), null::uuid,
  'passer en entreprise tierce détache l''assureur');

select tests.as_user('b0000000-0000-4000-8000-000000000001');
select public.save_mandate_form('e0000000-0000-4000-8000-000000000004', '{"requester_type":"individual"}'::jsonb);
select tests.as_postgres();
select is((select requester_siret from public.mandates where id = 'e0000000-0000-4000-8000-000000000004'), null,
  'particulier : les données de l''entreprise tierce sont effacées');

select * from finish();
rollback;
