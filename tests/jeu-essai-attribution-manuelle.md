# Jeu d'essai — Attribution manuelle par lot

**Fonctionnalité la plus représentative** : elle traverse les 4 couches (écran WeWeb → API → fonction métier `manual_assign_mandates` → machine à états `transition_mandate_status` → tables sous RLS), applique les règles de sécurité (rôle, organisation, base d'experts, CGU) et la règle métier du cycle de vie du mandat.

**Historique**
- **09/11/2026, version 1** : 8 cas, tous conformes à l'attendu en sécurité ; 2 écarts d'ergonomie relevés (voir l'analyse ci-dessous).
- **18/11/2026, version 2** : écarts corrigés par la migration `20261118200157_attribution_messages_distincts_durcissement.sql`, puis jeu relancé. Les données de démonstration avaient changé entre-temps (ASM-2025-0003 archivé ; règle CGU du 16/11) : E1 et E2 utilisent d'autres mandats et un cas E9 (CGU) a été ajouté.

**Exécution** : base de production, dans une transaction annulée à la fin (aucune donnée modifiée). Script : [`db/jeu_essai_attribution.sql`](db/jeu_essai_attribution.sql). Test automatique correspondant : `supabase/tests/11_attribution_messages_test.sql` (CI).
**Compte** : gestionnaire de l'organisation *Assurances Solidaires Mutuelle* (JWT simulé, rôle `authenticated`).

## Données en entrée (version 2)

| Cas | Mandat (statut) | Expert (situation) | Ce que l'on vérifie |
|---|---|---|---|
| E1 | ASM-2025-0007 (`dropped`) | S. Delorme (dans la base, « new », CGU acceptées) | attribution nominale |
| E2 | ASM-2025-0004 (`redrop`) | T. Cadelis (dans la base, CGU acceptées) | attribution après redrop |
| E3 | ASM-2025-0005 (`dropped`) | L. Petit (dans la base, **suspendu**) | expert suspendu refusé |
| E4 | ASM-2025-0005 (`dropped`) | F. Moreau (**hors base** de l'organisation) | expert hors base refusé |
| E5 | CGH-2025-0009 (`dropped`, **autre organisation**) | S. Delorme | cloisonnement des organisations |
| E6 | ASM-2025-0010 (**`closed`**) | S. Delorme | transition interdite par la machine à états |
| E9 | MAN-0020 (`dropped`) | T. Gautier (**CGU non acceptées**) | règle RGPD : attribution réservée aux experts ayant accepté les CGU |
| E7 | ASM-2025-0005 | appel fait par un **compte expert** | contrôle du rôle |
| E8 | lot **vide** `[]` | — | contrôle de l'entrée |

E1 à E6 et E9 sont envoyés en **un seul appel** (lot de 7 couples).

## Données attendues / obtenues (version 2, 18/11/2026)

| Cas | Attendu | Obtenu | Résultat |
|---|---|---|---|
| E1 | mandat `assigned`, expert Delorme, affectation `manual` / `pending` créée | `assigned`, Sophie Delorme | ✅ |
| E2 | mandat `assigned`, expert Cadelis | `assigned`, Cadelis Thomas | ✅ |
| E3 | refus « Expert suspendu », mandat inchangé | « Expert suspendu (Laurent Petit) », mandat toujours `dropped` | ✅ (écart 1 corrigé) |
| E4 | refus « Recrutez d'abord l'expert dans votre base », mandat inchangé | « Recrutez d'abord l'expert dans votre base (Frédéric Moreau) », mandat toujours `dropped` | ✅ (écarts 1 et 2 corrigés) |
| E5 | refus | « Mandat introuvable dans votre organisation (Sophie Delorme) », référence non divulguée, mandat inchangé | ✅ |
| E6 | refus | « Transition interdite : closed → assigned (autorisées : {}) (Sophie Delorme) », mandat toujours `closed` | ✅ |
| E9 | refus CGU | « Expert n'ayant pas accepté les CGU en vigueur : attribution impossible… (Thierry Gautier) », mandat toujours `dropped` | ✅ |
| Lot | retour `{assigned: 2, errors: [5]}` ; les refus n'annulent pas les succès | `{assigned: 2, errors: [5 éléments]}` ; 2 lignes `mandate_assignments` créées | ✅ |
| Journal | 1 ligne `activity_logs` : demandés 7, attribués 2 | `requested: 7, assigned: 2` | ✅ |
| E7 | « Réservé aux gestionnaires » | « Réservé aux gestionnaires » | ✅ |
| E8 | « Aucune attribution à enregistrer » | « Aucune attribution à enregistrer » | ✅ |

## Analyse des écarts (version 1, 09/11) et corrections

1. **Message ambigu (E3 / E4).** Deux causes différentes (expert suspendu, expert hors base) donnaient le même message « Expert absent de votre base ou suspendu ». Le gestionnaire ne savait pas s'il devait recruter l'expert ou en choisir un autre.
   *Correction (18/11)* : deux contrôles séparés, deux messages : « Expert suspendu » / « Recrutez d'abord l'expert dans votre base ».
2. **Erreur identifiée par le seul mandat.** Quand un même mandat figurait deux fois dans le lot (E3 et E4), le compte rendu affichait deux fois « ASM-2025-0005 » sans dire quel expert était en cause.
   *Correction (18/11)* : chaque erreur contient le nom de l'expert (dans le message et dans un champ `expert_name`).
3. **Aucun écart de sécurité** : rôle, organisation, base d'experts, CGU et machine à états bloquent tous les cas interdits, y compris quand ils sont mêlés à des cas valides dans le même lot (traitement ligne par ligne avec un bloc `exception` par couple). Amélioration au passage : la référence d'un mandat d'une autre organisation n'apparaît plus dans le compte rendu (E5 : `reference` vide).
