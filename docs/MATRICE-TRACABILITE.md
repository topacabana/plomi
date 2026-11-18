# Matrice de traçabilité — exigences du cahier des charges → réalisation → tests

Référence : *PLOMI — Cahier des charges V1.0* (identifiants F, S, R, A, T). État au **18/11/2026**.

Légende : ✅ réalisé et testé · 🟠 partiel (écart expliqué) · ❌ non réalisé (perspective) · ❓ à vérifier
Tests : n° = batterie en base (`tests/README.md`) · `pgTAP nn` = `supabase/tests/nn_*.sql` (CI) · `UI` = recette dans l'interface · `JE` = jeu d'essai.

## 4.1 Authentification et comptes

| ID | Exigence (résumé) | P | Réalisation | Tests | État |
|---|---|---|---|---|---|
| F01 | Connexion e-mail / mot de passe, session persistante | P1 | Supabase Auth (JWT), pages Login / Log in | UI | ✅ |
| F02 | Date, heure, durée de chaque connexion | P1 | `user_profiles.last_login_at`, sessions expert (`user_sessions`, `touch_presence`) | 97–98 | 🟠 durée suivie pour les experts seulement |
| F03 | Réinitialisation du mot de passe par lien | P1 | Supabase Auth + pages « Mot de passe oublié » / « Nouveau mot de passe » (2 apps) | UI, audit 18/11 | ✅ |
| F04 | Inscription expert en libre-service (`pending_validation`) | P1 | Remplacée par l'invitation du gestionnaire (`invite-expert`, `create_expert_record`) | 15, UI | 🟠 choix : pas d'inscription libre, l'expert est invité ou recruté |
| F05 | Compte gestionnaire par l'admin ou sign-up validé | P1 | sign_up + `manage-manager` (superviseur) | UI | ✅ |
| F06 | Statuts `pending_validation` / `active` / `banned` | P1 | enum `expert_account_status`, suspension expert | 79, UI | ✅ |
| F07 | Déconnexion avec nettoyage de session | P1 | Menu : fermeture des canaux temps réel puis signOut | UI | ✅ |

## 4.2 Mandats — interface assurance

| ID | Exigence | P | Réalisation | Tests | État |
|---|---|---|---|---|---|
| F10 | Création d'un mandat (bénéficiaire, type, localisation, sinistre, priorité) | P1 | Mandates_creation → `save_mandate_form` | 08–10, 59–61, 92, pgTAP 08 | ✅ |
| F11 | Sauvegarde en brouillon (`draft`) | P1 | Bouton « Sauvegarder » → statut `draft` | 09 | 🟠 sauvegarde à la demande, pas automatique |
| F12 | Liste de drop filtrable (statut, priorité, type, 101 départements, A-Z) | P1 | Liste_drop | UI | ✅ |
| F13 | Drop simple | P1 | `save_mandate_form(p_drop)` → `dropped` | 56–57, pgTAP 03 | ✅ |
| F14 | Drop liste | P1 | `save_mandate_form(p_list_ids)` | 57–58 | ✅ |
| F15 | Attribution manuelle | P1 | Attribution_manuelle → `manual_assign_mandates` | 35–37, JE, pgTAP 04 / 11 | ✅ |
| F16 | Assistant PLO (4 critères, 5 stratégies) | P1 | Popup PLO → `plo_data`, `plo_select` : présélection des experts, puis attribution | 45–48 | 🟠 présélection, l'attribution reste validée par le gestionnaire (choix RGPD art. 22) |
| F17 | Blocage concurrentiel avec nom de l'opérateur | P1 | `mandate_lock_status`, verrou 10 min, temps réel | UI | ✅ |
| F18 | Redrop | P1 | `manager_redrop_mandate` | pgTAP 06 | ✅ |
| F19 | Suppression avec confirmation + SMS au bénéficiaire | P1 | Zone de danger → `transition_mandate_status(cancelled)` | UI | 🟠 pas de SMS (aucun fournisseur) |
| F20 | Cartographie des interventions | P1 | Current_drop | UI | ✅ |
| F21 | SMS bénéficiaire à chaque statut clé | P2 | — | — | ❌ perspective (fournisseur SMS) |
| F22 | Téléchargement / partage des mandats en PDF | P2 | `generate-mandates-pdf`, `mandates-export-xlsx` | UI | ✅ |
| F23 | Tableau de bord KPI | P2 | KPIs, `kpi_report`, `manager_dashboard` | 41–44, 93–99 | ✅ |

## 4.3 Experts — interface assurance

| ID | Exigence | P | Réalisation | Tests | État |
|---|---|---|---|---|---|
| F30 | Liste des experts avec disponibilité | P1 | Liste_experts, badge Actif / Hors-ligne | 28, 49 | ✅ |
| F31 | Création et modification de la fiche expert | P1 | Expert_création ; Détails_expert | UI | 🟠 modification par le gestionnaire non faite (backlog) |
| F32 | Listes d'experts nommées | P1 | Liste_creation, `save_expert_list` | 11–13, 38–40 | ✅ |
| F33 | Recrutement / invitation | P2 | Recrutement_experts, Fiche_recrutement, `invite-expert` | 50–55 | ✅ |
| F34 | Statistiques par expert | P2 | Panneau 📊 de Détails_expert | 54, 96 | ✅ |

## 4.4 Interventions — interface expert

| ID | Exigence | P | Réalisation | Tests | État |
|---|---|---|---|---|---|
| F40 | Carte des mandats disponibles, filtre par type | P1 | Home (carte) | 19 | ✅ |
| F41 | Pop-up mandat + lancement GPS | P1 | Home : workflow au clic sur un marqueur | UI | ❓ bouton GPS à vérifier avec un mandat sur la carte |
| F42 | Prise en charge + message ETA au bénéficiaire | P1 | `expert_claim_mandate` | UI | 🟠 pas de message au bénéficiaire (fournisseur) |
| F43 | Tournée avec horaire de fin, avertissement d'abandon | P1 | Lancement mandat, `expert_quit_intervention`, `expert_abandon_mandate` | 62–65 | 🟠 abandon avec motif ; pas d'horaire de fin de tournée |
| F44 | Centrage de la carte sur la position GPS (activable / désactivable) | P1 | Accueil expert : bouton « GPS activé / désactivé » (choix gardé sur l'appareil), action native « Obtenir la position » au chargement, carte centrée sur la position (18/11, à publier) | UI | 🟠 réalisé dans l'éditeur, à tester puis publier |
| F45 | Notification temps réel des nouveaux drops | P1 | Notifications in-app | 22 | 🟠 pas de push mobile (application web) |

## 4.5 Rapports d'expertise

| ID | Exigence | P | Réalisation | Tests | État |
|---|---|---|---|---|---|
| F50 | Rapport RDF structuré | P1 | Formulaires RDF, `expert_send_report` | UI | ✅ |
| F51 | Rapport RDFS | P1 | Formulaire RDFS, accord destructif | pgTAP 05 | ✅ |
| F52 | Rapport visio-expertise | P1 | Synthèse visio (sans module vidéo) | UI | 🟠 module visio en perspective |
| F53 | Photos + annotation | P1 | Capture / Éditeur de médias (`report_media`, cible X/Y) | 81–91 | ✅ |
| F54 | PDF du rapport | P1 | `generate-report-pdf` | UI | ✅ |
| F55 | Transmission au mandataire | P1 | Aperçu → `expert_send_report` → `waiting_report` | UI | ✅ |
| F56 | Consultation et validation par le gestionnaire | P1 | détails_mandats | 04, 23 | ✅ |
| F57 | Archives 1 an | P1 | Archives expert, purge planifiée | 66–72, pgTAP 07 | ✅ |
| F58 | Partage par e-mail (PDF en pièce jointe) | P2 | mailto avec lien signé | UI | 🟠 lien au lieu d'une pièce jointe |

## 4.6 Profil et statistiques expert

| ID | Exigence | P | Réalisation | Tests | État |
|---|---|---|---|---|---|
| F60 | Coordonnées, statut, statistiques | P1 | Profil, `expert_profile_data` | 73 | ✅ |
| F61 | Rapidité, réactivité, créneaux, précision | P1 | KPI groupes 1 et 2 | 93–99 | ✅ |
| F62 | Rapport de statistiques avec axes d'amélioration | P2 | Profil → PDF | 78 | ✅ |
| F63 | Modification des informations | P1 | Modification du profil, `expert_update_profile` | 74–77 | ✅ |
| F64 | Suppression du profil avec avertissement | P2 | `expert_erase` (anonymisation) | 79 | ✅ |

## 4.7 Notifications

| ID | Exigence | P | Réalisation | Tests | État |
|---|---|---|---|---|---|
| F70 | Notifications in-app en temps réel | P1 | `notifications` + Supabase Realtime | 07, 14, 22 | ✅ |
| F71 | Centre de notifications horodaté avec lien | P1 | Panneau Notifications, Mes notifications | UI | ✅ |
| F72 | Mode actif / hors-ligne | P1 | Présence (`touch_presence`) | 27–28 | 🟠 statut affiché ; pas de blocage global des notifications |
| F73 | SMS bénéficiaire | P2 | — | — | ❌ perspective |
| F74 | E-mails (inscription, mot de passe, rapport disponible) | P1 | E-mails Supabase Auth (invitation, réinitialisation) | UI | 🟠 pas d'e-mail « rapport disponible » |

## 6.1 Sécurité

| ID | Exigence | Réalisation | Tests | État |
|---|---|---|---|---|
| S01 | HTTPS / TLS | WeWeb et Supabase en HTTPS | — | ✅ |
| S02 | JWT signé, session limitée | Supabase Auth | 32–34 | ✅ |
| S03 | RLS sur toutes les tables sensibles | RLS sur les 44 tables (`docs/securite.md`) | 01–07, 16–26, pgTAP 01–02 | ✅ |
| S04 | Documents privés, liens signés | Bucket `documents` privé, `sign-report-media` | 31 | ✅ |
| S05 | Journalisation des actions sensibles | `activity_logs` (transitions, attributions, archivage) | JE | ✅ |
| S06 | Clé service jamais côté client | Clé service uniquement dans les Edge Functions | 15 | ✅ |
| S07 | Mots de passe hachés (bcrypt) | Supabase Auth | — | ✅ (protection des mots de passe compromis à activer) |
| S08 | Procédure d'incident (CNIL 72 h) | Demandes RGPD tracées (`rgpd_requests`) | — | ❓ procédure écrite à joindre |

## 6.2 RGPD

| ID | Exigence | Réalisation | État |
|---|---|---|---|
| R01 | Minimisation | migration `rgpd_a1_minimisation_available` | ✅ |
| R02 | Consentement à l'inscription | Acceptation tracée des CGU (`expert_accept_cgu`, pgTAP 04) | ✅ |
| R03 | Droits d'accès, rectification, suppression | `expert_export_my_data`, `expert_update_profile`, `expert_erase`, `rgpd_requests` | ✅ |
| R04 | Rétention et purge automatique | `rgpd_a6_retention_sweep`, purges planifiées (pg_cron) | ✅ |
| R05 | Registre des traitements | Registre (4 traitements) + AIPD | ✅ |
| R06 | DPA avec les sous-traitants | Hors code | ❓ |
| R07 | Mentions légales / politique de confidentialité sur toutes les pages | Pages Confidentialité (2 apps) et CGU (expert) | 🟠 pas de page Mentions légales distincte |

## 6.3 Accessibilité (RGAA)

Audit du 18/11/2026 : [`docs/AUDIT-RGAA.md`](AUDIT-RGAA.md).

| ID | Critère | État |
|---|---|---|
| A01 | Alternatives des images | ✅ |
| A02 | Contraste | ✅ (1 écart mineur) |
| A03 | Navigation clavier | ❌ div cliquables non focusables |
| A04 | Étiquettes des formulaires | ❌ placeholders seuls |
| A05 | Structure des titres | 🟠 app expert sans titres balisés |
| A06 | ARIA des composants dynamiques | ❓ limite WeWeb |
| A07 | Zoom 200 % | ✅ |
| A08 | Cibles ≥ 44 px | 🟠 boutons de 35–40 px |

## 8.2 Scénarios de recette

| Réf. | Scénario | Couverture | État |
|---|---|---|---|
| T01 | Création RDF + drop → visible sur la carte expert | 56–57, pgTAP 03, UI | ✅ |
| T02 | Deux gestionnaires sur le même mandat → blocage avec nom | Verrou F17, UI | ✅ (UI) |
| T03 | Acceptation depuis la carte → `assigned`, retiré de la carte des autres | UI | 🟠 sans SMS ETA |
| T04 | Rapport RDF + 3 photos → PDF < 5 s, `waiting_report` | UI | ✅ (UI) |
| T05 | Accès aux mandats d'une autre organisation refusé | 01, 17, pgTAP 02 | ✅ (la RLS renvoie 0 ligne plutôt qu'un 403) |
| T06 | PLO stratégie « Commercial » sur 10 mandats | 47 | 🟠 présélection ; 0 expert retenu avec les données de test |
| T07 | Abandon de tournée → anomalie au mandataire | 64–65 | ✅ |
| T08 | Charge : 500 utilisateurs simultanés | — | ❌ non réalisé |
| T09 | Navigation smartphone 375 px | Audit 18/11 | 🟠 app expert et liste de drop OK ; création de mandat déborde (779 px) |
| T10 | Droit à l'effacement | 79 | ✅ |

## Synthèse

Exigences fonctionnelles P1 : 42 au total, dont 28 ✅, 13 🟠 (écarts justifiés ; F44 réalisé le 18/11, à publier) et 1 ❓ (F41 bouton GPS, à vérifier avec un mandat sur la carte). Aucune exigence P1 n'est absente. Les ❌ concernent des P2 (SMS) et le test de charge T08. Les écarts 🟠 / ❌ dépendent surtout d'un fournisseur SMS / e-mail et du module visio, présentés comme perspectives.
