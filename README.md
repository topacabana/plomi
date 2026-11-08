# PLOMI

Plateforme de diffusion et de suivi des mandats d'expertise (recherche de fuite RDF / RDFS, visio-expertise) entre **mandataires** (assureurs, gestionnaires) et **experts** terrain.

Projet réalisé par Thomas CADELIS dans le cadre du titre professionnel **Concepteur Développeur d'Applications** (RNCP37873).

## Architecture

| Couche | Technologie | Rôle |
|---|---|---|
| Présentation | WeWeb (2 apps : *PLOMI mandataire*, *PLOMI expert*) | Écrans, formulaires, workflows front |
| API | Supabase PostgREST + RPC | Accès aux tables et aux fonctions, JWT de l'utilisateur |
| Métier | Fonctions PostgreSQL (`SECURITY DEFINER`, plpgsql) | Règles métier : cycle de vie des mandats, attribution, listes, KPI, PLO, recrutement |
| Services | Supabase Edge Functions (Deno / TypeScript) | PDF, liens signés, invitations, temps de trajet |
| Données | PostgreSQL 17 + RLS | 35 tables, 23 types, règles d'accès par rôle et par organisation |
| Fichiers | Supabase Storage | Bucket `documents` **privé** (liens signés), `organization-logos` public |
| Tâches planifiées | pg_cron + pg_net | Temps de trajet toutes les 15 min, purge des sessions |

## Contenu du dépôt

```
supabase/
  migrations/   73 migrations SQL appliquées en production (15/09/2026 → aujourd'hui), une par commit
  functions/    13 Edge Functions (TypeScript / Deno)
  schema/       instantané complet du schéma de production (tables, index, fonctions, vues, triggers, RLS)
  config.toml   configuration Supabase CLI (vérification JWT par fonction)
frontend/       description des apps WeWeb (pas d'export de code : outil no-code)
tests/          plan de tests et résultats
docs/           sécurité, conventions
```

## Historique Git

Le dépôt a été créé le 08/11/2026 **à partir de l'état réel de la production** :

- chaque migration est un commit dont la **date d'auteur** est la date d'application en base (journal `supabase_migrations.schema_migrations`) ;
- chaque Edge Function est un commit daté de son dernier déploiement (version indiquée dans le message) ;
- la **date de commit** (committer date) est celle de la création du dépôt : `git log --format='%ad | %cd | %s'` montre les deux.

Le travail antérieur au 15/09/2026 (création initiale des tables, faite depuis l'éditeur SQL de Supabase) n'a pas de migration : il est couvert par l'instantané `supabase/schema/`.

À partir de maintenant, toute modification passe par ce dépôt (voir [docs/CONVENTIONS.md](docs/CONVENTIONS.md)).

## Rejouer la base en local

Prérequis : Docker et la [Supabase CLI](https://supabase.com/docs/guides/local-development).

```bash
supabase start                      # Postgres, Auth, Storage, Edge Runtime en conteneurs
psql "$DB_URL" -f supabase/schema/00_extensions.sql   # puis 01 → 08 dans l'ordre
supabase functions serve            # Edge Functions en local
```

## Secrets

Aucun secret n'est versionné. La clé Google Maps est rangée dans le coffre Supabase (Vault, secret `google_maps_key`) ; dans la migration correspondante elle est remplacée par `<GOOGLE_MAPS_API_KEY>`. Les clés `SUPABASE_SERVICE_ROLE_KEY` / `SUPABASE_ANON_KEY` sont injectées par Supabase dans les Edge Functions.
