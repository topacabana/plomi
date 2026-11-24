-- Import CSV côté serveur : décodage, séparateur, correspondance des colonnes, conversions et contrôles
-- (dont les champs obligatoires du 23/11 : code postal ou ville, téléphone ou e-mail).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions, tests;
select plan(13);
select tests.seed();
select tests.as_user('b0000000-0000-4000-8000-000000000001');

create temp table st as select public.csv_import_build(public.csv_import_analyze('t.csv', 'data:text/csv;base64,Tm9tO1Byw6lub207VHlwZTtBZHJlc3NlO0Nyw6luZWF1IDE7UHJpb3JpdMOpO1RlbDtQacOoY2VzO1ZpbGxlCk1hcnRpbjtMw6lhO1JERjsiMSBydWUgQTsgYsOidCBCIjsxMi8xMS8yMDI2IDE0aDMwO2hhdXRlOzYxMjM0NTY3ODtjdWlzaW5lfHNhbG9uO0NvaWduacOocmVzCkR1cmFuZDtQYXVsO3h5ejsyIHJ1ZSBCOztib2Y7OztQYXJpcwo=', '')) s;

select is((select s->>'error' from st), '', 'fichier lu sans erreur');
select is((select s->>'delimiter' from st), ';', 'séparateur ; détecté');
select is((select jsonb_array_length(s->'columns') from st), 9, '9 colonnes');
select is((select s->'columns'->1->>'key' from st), 'beneficiary.first_name', 'en-tête accentué « Prénom » reconnu');
select is((select s->'rows'->0->'data'->>'address_line_1' from st), '1 rue A; bât B', 'cellule entre guillemets avec séparateur');
select is((select s->'rows'->0->'data'->>'slot_1_at' from st), '2026-11-12T13:30:00.000Z', 'créneau 14h30 heure de Paris converti en UTC');
select is((select s->'rows'->0->'data'->'beneficiary'->>'mobile_phone' from st), '0612345678', 'téléphone : 0 initial restauré');
select is((select s->'rows'->1->>'status' from st), 'error', 'type de mandat inconnu : ligne en erreur');
select is((public.csv_import_analyze('v.csv', encode(convert_to('Nom', 'UTF8'), 'base64'), ''))->>'error',
  'Le fichier ne contient pas de ligne de données sous l''en-tête.', 'fichier sans données : message clair');

-- Règle du 23/11 : code postal ou ville obligatoire (revérifié à l'enregistrement)
select ok('Code postal ou ville manquant' = any(public.csv_import_row_errors(
  '{"mandate_type":"rdf","address_line_1":"1 rue A","beneficiary":{"last_name":"Martin","first_name":"Léa","mobile_phone":"0612345678"}}'::jsonb)),
  'ligne sans code postal ni ville : refusée');

-- Enregistrement groupé : la ligne valide est importée, la ligne en erreur n'est pas retentée.
select tests.as_postgres();
insert into public.insurers (id, organization_id, name)
values ('f0000000-0000-4000-8000-000000000009', 'a0000000-0000-4000-8000-000000000001', 'Assureur import');
select tests.as_user('b0000000-0000-4000-8000-000000000001');
create temp table done as
  select public.csv_import_commit((select s from st) || '{"insurerId":"f0000000-0000-4000-8000-000000000009"}'::jsonb) s;
select is((select s->'rows'->0->>'status' from done), 'imported', 'ligne valide importée');
select is((select s->'rows'->1->>'status' from done), 'error', 'ligne en erreur laissée de côté');
select tests.as_postgres();
select is((select requester_type || '/' || status from public.mandates where id = (select (s->'rows'->0->>'mandateId')::uuid from done)),
  'insurer/drop_pending', 'mandat créé pour l''assureur, en liste de drop');

select * from finish();
rollback;
