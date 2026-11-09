# Jeu d'essai — Attribution manuelle par lot

**Fonctionnalité la plus représentative** : elle traverse les 4 couches (écran WeWeb → API → fonction métier `manual_assign_mandates` → machine à états `transition_mandate_status` → tables sous RLS), applique les règles de sécurité (rôle, organisation, base d'experts) et la règle métier du cycle de vie du mandat.

**Exécution** : 09/11/2026, base de production, dans une transaction annulée à la fin (aucune donnée modifiée). Script : [`db/jeu_essai_attribution.sql`](db/jeu_essai_attribution.sql).
**Compte** : gestionnaire de l'organisation *Assurances Solidaires Mutuelle* (JWT simulé, rôle `authenticated`).

## Données en entrée

| Cas | Mandat (statut) | Expert (situation) | Ce que l'on vérifie |
|---|---|---|---|
| E1 | ASM-2025-0003 (`drop_pending`) | S. Delorme (dans la base, « new ») | attribution nominale |
| E2 | ASM-2025-0004 (`redrop`) | T. Gautier (dans la base, connecté) | attribution après redrop |
| E3 | ASM-2025-0005 (`dropped`) | L. Petit (dans la base, **suspendu**) | expert suspendu refusé |
| E4 | ASM-2025-0005 (`dropped`) | F. Moreau (**hors base** de l'organisation) | expert hors base refusé |
| E5 | CGH-2025-0009 (`dropped`, **autre organisation**) | S. Delorme | cloisonnement des organisations |
| E6 | ASM-2025-0010 (**`closed`**) | T. Gautier | transition interdite par la machine à états |
| E7 | ASM-2025-0005 | appel fait par un **compte expert** | contrôle du rôle |
| E8 | lot **vide** `[]` | — | contrôle de l'entrée |

E1 à E6 sont envoyés en **un seul appel** (lot de 6 couples).

## Données attendues / obtenues

| Cas | Attendu | Obtenu | Résultat |
|---|---|---|---|
| E1 | mandat `assigned`, expert Delorme, affectation `manual` / `pending` créée | `assigned`, Delorme, date d'attribution renseignée | ✅ |
| E2 | mandat `assigned`, expert Gautier | `assigned`, Gautier | ✅ |
| E3 | refus, mandat inchangé | « Expert absent de votre base ou suspendu », mandat toujours `dropped` | ✅ |
| E4 | refus, mandat inchangé | « Expert absent de votre base ou suspendu », mandat toujours `dropped` | ✅ (voir écart 1) |
| E5 | refus | « Mandat introuvable dans votre organisation », mandat de l'autre organisation inchangé | ✅ |
| E6 | refus | « Transition interdite : closed → assigned (autorisées : {}) », mandat toujours `closed` | ✅ |
| Lot E1-E6 | retour `{assigned: 2, errors: [4]}` ; les refus n'annulent pas les succès | `{assigned: 2, errors: [4 éléments]}` ; 2 lignes `mandate_assignments` créées | ✅ |
| Journal | 1 ligne `activity_logs` : demandés 6, attribués 2, erreurs | `requested: 6, assigned: 2`, 4 erreurs détaillées | ✅ |
| E7 | « Réservé aux gestionnaires » | « Réservé aux gestionnaires » | ✅ |
| E8 | « Aucune attribution à enregistrer » | « Aucune attribution à enregistrer » | ✅ |

## Analyse des écarts

1. **Message ambigu (E3 / E4).** Deux causes différentes (expert suspendu, expert hors base) donnent le même message. Le gestionnaire ne sait pas s'il doit recruter l'expert ou en choisir un autre. *Correction proposée* : deux messages distincts (« Expert suspendu » / « Recrutez d'abord l'expert dans votre base »).
2. **Erreur identifiée par le seul mandat.** Quand un même mandat figure deux fois dans le lot (E3 et E4), le compte rendu affiche deux fois « ASM-2025-0005 » sans dire quel expert est en cause. *Correction proposée* : ajouter le nom de l'expert dans chaque erreur.
3. **Aucun écart de sécurité** : rôle, organisation, base d'experts et machine à états bloquent tous les cas interdits, y compris quand ils sont mêlés à des cas valides dans le même lot (traitement ligne par ligne avec bloc `exception` par couple).
