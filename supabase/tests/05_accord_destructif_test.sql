-- RDFS : l'accord du bénéficiaire aux investigations destructives est contrôlé et horodaté.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(5);
select tests.seed();

select tests.as_user('b0000000-0000-4000-8000-000000000003');  -- expert avec CGU, mandat pas encore attribué
select is((public.expert_record_destructive_consent('e0000000-0000-4000-8000-000000000002', 'Jeanne Martin', 'beneficiaire',
            'Ouverture du doublage salle de bain', (public.destructive_consent_text())->>'version'))->>'error',
  'Ce mandat ne vous est pas attribué.', 'un expert ne recueille pas d''accord sur un mandat qui n''est pas le sien');

select tests.as_user('b0000000-0000-4000-8000-000000000001');
select public.manual_assign_mandates('[{"mandate_id":"e0000000-0000-4000-8000-000000000002","expert_id":"c0000000-0000-4000-8000-000000000001"}]');

select tests.as_user('b0000000-0000-4000-8000-000000000003');
select is((public.expert_record_destructive_consent('e0000000-0000-4000-8000-000000000002', 'J', 'beneficiaire',
            'Ouverture du doublage', (public.destructive_consent_text())->>'version'))->>'error',
  'Le bénéficiaire doit saisir son nom.', 'le nom du signataire est obligatoire');
select is((public.expert_record_destructive_consent('e0000000-0000-4000-8000-000000000002', 'Jeanne Martin', 'voisin',
            'Ouverture du doublage', (public.destructive_consent_text())->>'version'))->>'error',
  'Précisez la qualité du signataire.', 'la qualité du signataire est contrôlée');
select is((public.expert_record_destructive_consent('e0000000-0000-4000-8000-000000000002', 'Jeanne Martin', 'beneficiaire',
            'Ouverture du doublage salle de bain', (public.destructive_consent_text())->>'version'))->>'ok',
  'true', 'l''accord complet est enregistré');

select tests.as_postgres();
select is((select count(*)::int from public.destructive_consents
            where mandate_id = 'e0000000-0000-4000-8000-000000000002' and consented_at is not null and consent_text <> ''),
  1, 'l''accord est conservé avec le texte présenté et l''horodatage');

select * from finish();
rollback;
