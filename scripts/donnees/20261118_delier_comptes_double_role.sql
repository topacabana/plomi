-- PLOMI — Nettoyage des comptes de test à double rôle (point A de tests/README.md).
-- Exécuté le 18/11/2026 sur la production. Résultat : tests 01–18 relancés, 17/17 OK (tests/db/tests_cloisonnement_01_18.sql).
--
-- Avant : 5 comptes gestionnaires étaient aussi reliés à une fiche expert (experts.user_id),
-- donc is_expert() était vrai pour eux et ils voyaient en plus les mandats de la carte expert
-- (écarts des tests 01, 03, 04, 16 et 17).
-- Après : chaque fiche expert est rattachée à un compte expert dédié, sans mot de passe
-- (connexion impossible) ; les gestionnaires n'ont plus que le rôle gestionnaire.
-- Les fiches, leurs mandats, affectations, médias et KPI sont conservés.
--
-- Ce n'est pas une migration : il s'agit de données de production, pas du schéma.
-- Retour arrière : 20261118_delier_comptes_double_role_annulation.sql

begin;

-- Correspondance fiche expert → ancien compte gestionnaire → nouveau compte expert
create temp table liaison (expert_id uuid, ancien_user uuid, nouveau_user uuid, email text, prenom text, nom text) on commit drop;
insert into liaison values
  ('35152001-fbc1-492e-b592-b42e9d19d81d', '51bd0c83-94f1-4274-b3e3-16fd853d5616', 'f1000000-0000-4000-8000-000000000001', 'michel.bernard@expertise-rapide-idf.fr', 'Cadelis', 'Thomas'),
  ('8a340f22-ca3d-4406-963e-9619c3e63251', '00000002-0000-4000-8000-000000000002', 'f1000000-0000-4000-8000-000000000002', 'jm.dufour@expertplomb-idf.fr',           'Jean-Marie', 'Dufour'),
  ('88e2260b-863c-4ca8-a4f4-8ecfbeb2f532', '00000002-0000-4000-8000-000000000001', 'f1000000-0000-4000-8000-000000000003', 'alain.rousseau@expertplomb-idf.fr',      'Alain', 'Rousseau'),
  ('9f31d1af-ebc9-4827-8a0b-b6b2fdd50c0d', '00000002-0000-4000-8000-000000000004', 'f1000000-0000-4000-8000-000000000004', 'nadia.ouazoune@expertplomb-idf.fr',      'Nadia', 'Ouazoune'),
  ('96f4309e-bd97-40c6-a6bb-6891d5abd816', '00000002-0000-4000-8000-000000000003', 'f1000000-0000-4000-8000-000000000005', 'karim.benali@expertplomb-idf.fr',        'Karim', 'Benali');

-- 1. Comptes experts dédiés (sans mot de passe ni identité : aucune connexion possible).
--    Le déclencheur on_auth_user_created (handle_new_user) crée le profil avec le rôle « expert ».
insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', l.nouveau_user, 'authenticated', 'authenticated', l.email, '',
       '{"provider":"email","providers":["email"]}'::jsonb,
       jsonb_build_object('first_name', l.prenom, 'last_name', l.nom, 'role', 'expert', 'compte_demo', true),
       now(), now()
from liaison l;

-- 2. La fiche expert pointe vers le compte expert dédié.
update public.experts e set user_id = l.nouveau_user
from liaison l where e.id = l.expert_id and e.user_id = l.ancien_user;

-- 3. Contrôle : plus aucun gestionnaire n'est expert.
do $$
begin
  if exists (select 1 from public.experts e join public.user_profiles up on up.id = e.user_id
             where up.role::text = 'gestionnaire_assurance') then
    raise exception 'Il reste un compte gestionnaire relié à une fiche expert';
  end if;
end $$;

commit;
