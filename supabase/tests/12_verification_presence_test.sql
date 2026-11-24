-- Vérification de présence de l'expert chez le bénéficiaire (code e-mail ou décharge).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(17);
select tests.seed();

-- Les deux mandats de l'organisation A sont attribués à l'expert c…01 (CGU acceptées)
select tests.as_user('b0000000-0000-4000-8000-000000000001');
select public.manual_assign_mandates('[{"mandate_id":"e0000000-0000-4000-8000-000000000001","expert_id":"c0000000-0000-4000-8000-000000000001"},
                                       {"mandate_id":"e0000000-0000-4000-8000-000000000002","expert_id":"c0000000-0000-4000-8000-000000000001"}]');
select tests.as_postgres();

-- Droits : les fonctions d'émission et de vérification sont réservées au serveur
select ok(not has_function_privilege('authenticated', 'public.presence_code_issue(uuid,uuid)', 'execute'), 'émission du code réservée au serveur');
select ok(not has_function_privilege('authenticated', 'public.presence_code_check(uuid,uuid,text)', 'execute'), 'vérification du code réservée au serveur');
select ok(not has_function_privilege('anon', 'public.expert_presence_discharge(uuid,text)', 'execute'), 'décharge fermée aux visiteurs');

-- Bénéficiaire sans e-mail : pas de code, décharge proposée
select is((public.presence_code_issue('b0000000-0000-4000-8000-000000000003', 'e0000000-0000-4000-8000-000000000001'))->>'no_email', 'true',
  'sans e-mail, aucun code n''est émis');

-- Avec e-mail : un code à 6 chiffres est émis, jamais stocké en clair
update public.beneficiaries set email = 'jeanne.martin@test.local' where id = 'd0000000-0000-4000-8000-000000000001';
create temp table emis as select public.presence_code_issue('b0000000-0000-4000-8000-000000000003', 'e0000000-0000-4000-8000-000000000001') as r;
select ok((select r->>'code' from emis) ~ '^\d{6}$', 'code de 6 chiffres émis');
select is((select r->>'email' from emis), 'jeanne.martin@test.local', 'le code part à l''adresse du bénéficiaire');
select ok((select code_hash from public.presence_verifications where mandate_id = 'e0000000-0000-4000-8000-000000000001') <> (select r->>'code' from emis),
  'le code est stocké haché, pas en clair');
select is((public.presence_code_issue('b0000000-0000-4000-8000-000000000003', 'e0000000-0000-4000-8000-000000000001'))->>'ok', 'false',
  'pas de second envoi dans la minute');

-- Un autre utilisateur (gestionnaire) ne peut pas demander le code
select is((public.presence_code_issue('b0000000-0000-4000-8000-000000000001', 'e0000000-0000-4000-8000-000000000001'))->>'ok', 'false',
  'un compte qui n''est pas l''expert attribué ne reçoit rien');

-- Mauvais code puis bon code
select is((public.presence_code_check('b0000000-0000-4000-8000-000000000003', 'e0000000-0000-4000-8000-000000000001', '000000'))->>'attempts_left', '4',
  'code erroné : 4 essais restants');
select is((public.presence_code_check('b0000000-0000-4000-8000-000000000003', 'e0000000-0000-4000-8000-000000000001', (select r->>'code' from emis)))->>'ok', 'true',
  'bon code : présence vérifiée');
select is((select presence_method from public.mandates where id = 'e0000000-0000-4000-8000-000000000001'), 'email_code',
  'méthode tracée sur le mandat');

-- Interrupteur activé : démarrage possible après vérification, refusé sans
update public.app_settings set value = 'true' where key = 'presence_verification_required';
select tests.as_user('b0000000-0000-4000-8000-000000000003');
select lives_ok($$ select public.expert_start_mandate('e0000000-0000-4000-8000-000000000001') $$, 'rapport démarré après vérification');
select throws_like($$ select public.expert_start_mandate('e0000000-0000-4000-8000-000000000002') $$, '%Vérification de présence requise%',
  'rapport refusé sans vérification');

-- Décharge : refusée si le bénéficiaire a un e-mail, acceptée sinon
select throws_like($$ select public.expert_presence_discharge('e0000000-0000-4000-8000-000000000002', '2026-11-20') $$, '%adresse e-mail%',
  'décharge refusée quand le bénéficiaire a un e-mail');
select tests.as_postgres();
update public.beneficiaries set email = null where id = 'd0000000-0000-4000-8000-000000000001';
select tests.as_user('b0000000-0000-4000-8000-000000000003');
select is((public.expert_presence_discharge('e0000000-0000-4000-8000-000000000002', '2026-11-20'))->>'method', 'decharge',
  'décharge enregistrée sans e-mail');
select lives_ok($$ select public.expert_start_mandate('e0000000-0000-4000-8000-000000000002') $$, 'rapport démarré après décharge');

select tests.as_postgres();
select * from finish();
rollback;
