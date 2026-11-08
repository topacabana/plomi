# Conventions du projet

## Branches
- `main` : état déployé en production.
- `feature/<sujet>` ou `fix/<sujet>` : une branche par évolution, fusionnée dans `main` par pull request.

## Messages de commit (Conventional Commits)
`<type>(<portée>): <description>`

| Type | Usage |
|---|---|
| `feat` | nouvelle fonctionnalité |
| `fix` | correction |
| `security` | durcissement sécurité (RLS, droits, stockage) |
| `docs` | documentation |
| `test` | tests |
| `chore` | outillage, configuration |

Portées : `db` (migrations), `edge` (Edge Functions), `schema`, `front`, `ci`.

## Base de données
- Une modification de schéma = un fichier `supabase/migrations/<AAAAMMJJHHMMSS>_<nom>.sql`, jamais de modification directe dans l'éditeur SQL.
- Nommage : tables et colonnes en `snake_case`, au pluriel pour les tables (`mandates`, `experts`) ; fonctions en verbe + objet (`save_mandate_form`, `manual_assign_mandates`) ; déclencheurs préfixés `trg_`.
- Toute fonction appelée depuis l'app : `SECURITY DEFINER`, `SET search_path`, contrôle du rôle (`is_manager()` / `is_expert()`) et de l'organisation, exécution refusée à `anon`.
- Toute nouvelle table : RLS activée dans la même migration.

## Edge Functions
- Un dossier par fonction : `supabase/functions/<nom>/index.ts`.
- Lecture des données avec le JWT de l'appelant quand c'est possible (la RLS décide) ; clé service réservée aux écritures techniques (stockage, journal).
- Fichiers du bucket `documents` : toujours renvoyer des liens signés (1 h pour l'affichage, 7 jours pour un partage).
