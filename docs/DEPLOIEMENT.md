# Procédure de déploiement et environnements

Mise à jour : 18/11/2026. Remplace le guide de déploiement du 24/10/2026.

## 1. Environnements

| Environnement | Où | Données | Sert à |
|---|---|---|---|
| **Développement local** | Poste du développeur : `supabase start` (Postgres, Auth, Storage, Edge Runtime en conteneurs Docker) | Jeu de test `ci/fixtures.sql` | Écrire une migration ou une Edge Function et la tester avant tout envoi |
| **Intégration continue** | GitHub Actions (`.github/workflows/ci.yml`), base Supabase jetable en conteneurs | Jeu de test `ci/fixtures.sql` | Rejouer tout le schéma depuis le dépôt et lancer les tests pgTAP à chaque push et à chaque pull request |
| **Recette** | Projet Supabase de production, dans des **transactions annulées** (scripts `tests/db/`) + apps WeWeb en mode éditeur / prévisualisation | Comptes et organisations de démonstration | Tests de cloisonnement 01–100, jeu d'essai, recette UI par le maître d'ouvrage |
| **Production** | Projet Supabase `PLOMI` (eu-west-1) + 2 apps WeWeb publiées | Données réelles | Utilisation |

Limite assumée : pas de projet Supabase de préproduction séparé branché sur les apps. La recette en base se fait donc en production, mais toujours dans des transactions annulées, et la CI rejoue chaque changement sur une base jetable avant la production. Évolution prévue : Supabase Branching (une base de préproduction par pull request).

## 2. Chaîne de livraison d'une évolution

```
branche feature/… ou fix/…  →  migration + tests pgTAP  →  pull request  →  CI verte
   →  application en production  →  tests de recette (tests/db)  →  advisors  →  fusion dans main
```

1. **Branche** : `git switch -c fix/<sujet>` (voir `docs/CONVENTIONS.md`).
2. **Migration** : un fichier `supabase/migrations/<AAAAMMJJHHMMSS>_<nom>.sql`. Toute fonction appelée par l'app est `SECURITY DEFINER`, avec `SET search_path`, un contrôle du rôle et de l'organisation, et l'exécution refusée à `anon`. Toute nouvelle table a la RLS activée dans la même migration.
3. **Test** : ajouter ou adapter un fichier `supabase/tests/NN_*_test.sql` (pgTAP).
4. **Vérification locale** (facultative si Docker est indisponible, la CI le fait) :
   ```bash
   supabase start
   bash ci/build_db.sh postgresql://postgres:postgres@127.0.0.1:54322/postgres
   supabase test db
   ```
5. **Pull request** : la CI reconstruit la base (instantané du 08/11 puis rejeu des migrations) et lance les tests. **On ne déploie pas si la CI est rouge.**
6. **Déploiement en production** :
   ```bash
   supabase link --project-ref ybbzfedbdjgcahqajltm
   supabase db push                          # applique les migrations absentes de la production
   supabase functions deploy <nom>           # pour chaque Edge Function modifiée
   ```
   Le numéro de version de la migration en production doit être celui du fichier du dépôt (`supabase migration list` pour comparer).
7. **Contrôles après déploiement** :
   - conseiller Supabase (Database → Advisors, onglet Security) : aucune nouvelle alerte ;
   - scripts de recette concernés dans `tests/db/` (transactions annulées) ;
   - journaux des Edge Functions (Logs) en cas de déploiement d'une fonction.
8. **Fusion** de la pull request dans `main` (`main` = état de la production).

## 3. Front WeWeb

1. Modifier la page dans l'éditeur WeWeb, puis la tester en prévisualisation avec un compte de démonstration.
2. **Publier** l'app (bouton *Publish*) : WeWeb construit et héberge la version (pas de serveur à gérer).
3. Les variables d'environnement (URL Supabase, clé publique `anon`) sont configurées dans le plugin Supabase de WeWeb. La clé `service_role` n'est **jamais** dans WeWeb.
4. Retour arrière : WeWeb conserve l'historique des publications ; republier la version précédente.

## 4. Secrets

| Secret | Où | Jamais |
|---|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` | Injectée par Supabase dans les Edge Functions | dans WeWeb, dans Git |
| Clé Google Maps | Coffre Supabase (Vault, `google_maps_key`) | en clair dans une migration (remplacée par `<GOOGLE_MAPS_API_KEY>`) |
| Clé publique `anon` | Plugin Supabase de WeWeb | — (publique par nature, la RLS protège les données) |

## 5. Retour arrière

- **Migration** : écrire une migration inverse (on ne modifie jamais une migration déjà appliquée). Pour une fonction, réappliquer sa version précédente (`supabase/schema/04_functions.sql` ou la migration antérieure).
- **Données** : chaque opération ponctuelle sur les données de production est un script de `scripts/donnees/` accompagné de son script d'annulation (ex. `20261118_delier_comptes_double_role_annulation.sql`).
- **Sauvegardes** : sauvegardes automatiques de Supabase (durée de rétention selon le plan) ; restauration depuis le tableau de bord (Database → Backups).

## 6. Tests d'intégration, système et recette client

| Niveau | Quoi | Outil | Quand |
|---|---|---|---|
| Unitaire | Une fonction PL/pgSQL, une règle RLS | pgTAP (`supabase/tests`) | À chaque push (CI) |
| Intégration | Enchaînement fonction → machine à états → déclencheurs → journal (ex. attribution par lot) | Scripts `tests/db/` (transactions annulées) | Avant chaque fusion touchant ce domaine |
| Système | Les 4 couches ensemble : app WeWeb → API → base → Edge Functions (PDF, liens signés) | Recette UI (`tests/README.md` §2) | Avant chaque livraison |
| Recette client | Scénarios T01–T10 du cahier des charges, validés par le maître d'ouvrage | `docs/MATRICE-TRACABILITE.md` | À la livraison |
