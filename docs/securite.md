# PLOMI — Sécurité (mise en place du 05/11/2026)

## Principe
- « Est gestionnaire » = `is_manager()` (user_profiles.role = gestionnaire_assurance).
- « Est expert » = `is_expert()` (le compte est relié à une fiche `experts`). Un compte peut avoir les deux rôles.
- Les écritures métier passent par des fonctions Postgres SECURITY DEFINER (transitions, broadcast, save_mandate_form, envoi de rapport) et des fonctions Edge (PDF, liens signés).

## Étapes (migrations `securite_1` à `securite_6`)
1. **mandates** : RLS. Gestionnaire = mandats de son organisation (lecture/écriture). Expert = mandats sur la carte (listes ciblées respectées) + mandats attribués / déjà affectés (`expert_has_assignment`).
   - `save_mandate_form(p_mandate_id, p_data, p_drop)` : création ou mise à jour du formulaire + drop. Organisation forcée par trigger `force_manager_org` (mandats, bénéficiaires).
   - beneficiaries : règles « tout autoriser » supprimées.
2. **rdf_reports / rdf_report_rooms** : lecture seule. Gestionnaire = mandats de son organisation ; expert = ses rapports. Toutes les règles `current_user_role()` remplacées par `is_manager()` / `is_expert()`.
3. **notifications** (RLS activée), **expert_kpis** (gestionnaires : tout ; expert : les siens), **expert_performance_logs** (condition toujours vraie corrigée).
4. **Vues** : pending_mandates_with_beneficiaries et mandate_lock_status en security_invoker ; mandate_history, experts_with_profiles, vw_expert_kpis_dashboard filtrées dans la vue (+ exception service_role pour les fonctions Edge).
5. **Stockage** : bucket `documents` privé.
   - Lecture : auteur du fichier, gestionnaire du mandat (rapports/{mandat}/…), ses propres exports (exports/{user}/…). Upload : experts dans rapports/.
   - Edge `sign-report-media` : liens signés 1 h des photos.
   - PDF (rapport, mandats, historique) : liens signés 7 jours ; exports limités à l'organisation du gestionnaire.
6. **Droits des fonctions** : plus aucune fonction appelable sans connexion ; fonctions internes (déclencheurs, calculs) fermées aux comptes connectés.

## Failles trouvées et corrigées (audit du 24/10/2026)
| Constat | Correction |
|---|---|
| RLS jamais activée sur `mandates` : avec la clé publique, lecture / modification de tous les mandats | `securite_1_mandates_rls` |
| 10 fonctions SECURITY DEFINER appelables sans connexion (dont `transition_mandate_status`) | `securite_6_droits_fonctions` |
| Bucket `documents` public (rapports et photos accessibles par lien) | `securite_5_stockage_prive` + liens signés |
| Vues SECURITY DEFINER contournant la RLS | `securite_4_vues` |
| Règle `expert_performance_logs` toujours vraie | `securite_3_notifications_kpi` |

## Points ouverts
- Protection des mots de passe compromis (Supabase Auth) à activer.
- Edge Functions de test `test-mandates-csv` / `test-mandates-csv-2` (jeu de données CSV, sans vérification JWT) : à supprimer en production — non versionnées ici.
- `get-coordinates`, `create-expert`, `generate-rapport-pdf` : anciennes versions (remplacées par `invite-expert`, `generate-report-pdf`) à retirer.
- Comptes gestionnaires de test reliés à des fiches experts : à nettoyer à la livraison.
