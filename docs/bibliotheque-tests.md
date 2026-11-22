# PLOMI — Bibliothèque des tests

Version du 22/11/2026 (22 h). Document de référence : chaque test garde **son identifiant pour toujours**. On ne renumérote jamais. Un test supprimé est barré, pas réutilisé.

**Statuts** : ✅ passé · ❌ échec (anomalie ouverte) · ↻ corrigé, à revérifier · ⏳ à faire · ➖ non applicable.

**Comptes de test** (tous sur la boîte de Thomas) :
- gestionnaire : `cadelisthomas7` ;
- expert : `cadelisthomas8` ;
- bénéficiaires : `cadelisthomas7+<assureur><n>@gmail.com`.

**Procédure de compte rendu** : identifiant du test, mandat utilisé, ce qui s'affiche, capture si écart. Les écarts sont reportés au format **entrée / attendu / obtenu / analyse / correction** dans la partie 9 du mémoire.

---

## Niveau 1 — Tests automatiques pgTAP (CI GitHub)

Les tests sont lancés à chaque envoi sur le dépôt `topacabana/plomi`, sur une base Docker neuve. Ils couvrent **18 fichiers et 122 assertions** ; tous passent.

| Fichier | Assertions | Ce qui est vérifié |
|---|---|---|
| 01_securite_schema | 9 | RLS active partout, fonctions sensibles fermées aux visiteurs non connectés |
| 02_cloisonnement | 4 | Un gestionnaire ne voit ni ne modifie les mandats d'un autre assureur |
| 03_machine_etats | 4 | Seules les transitions de statut prévues sont acceptées |
| 04_cgu_attribution | 5 | Un expert ne reçoit un mandat que s'il a accepté les CGU en vigueur |
| 05_accord_destructif | 5 | RDFS : accord du bénéficiaire contrôlé et horodaté |
| 06_redrop | 4 | Redrop depuis la fiche mandat : fonction serveur, motif obligatoire |
| 07_archivage | 4 | Zone de danger : l'archivage avec purge supprime les mandats clôturés et leur historique |
| 08_demandeur | 8 | Organisme demandeur obligatoire (assureur, entreprise tierce, particulier) |
| 09_import_csv | 12 | Import CSV : décodage, séparateur, colonnes, conversions, lignes en erreur |
| 10_fiche_mandat | 3 | Coordonnées du bénéficiaire cloisonnées par organisation |
| 11_attribution_messages | 7 | Attribution manuelle : messages distincts (jeu d'essai, écarts 1 et 2) |
| 12_verification_presence | 17 | Code e-mail ou décharge ; fonctions réservées au serveur |
| 13_separation_roles | 3 | Carte de l'app expert réservée aux experts |
| 14_interruption_suspension | 7 | Quitter sans rapport : expert suspendu jusqu'à régularisation |
| 15_abandon_suspension | 5 | Abandon après prise en charge : même suspension |
| 16_rdfs_suite | 12 | RDFS en suite d'un RDF : lié, droppé sans redrop, une seule fois |
| 17_rdfs_liens | 7 | Liens RDF ↔ RDFS sur la fiche mandat |
| 18_zone_danger_retrait | 6 | Gestionnaire retiré : plus aucun droit ; fichiers mis en file de suppression |

**À ajouter** :
- **PG-19** : motif « Autre » de l'interruption (refusé sans explication de 10 caractères, accepté avec).
- **PG-20** : géocodage, un HTTP 429 laisse l'adresse en attente au lieu de la marquer refusée. Ce cas se vérifie par les journaux, pas en pgTAP.

---

## Niveau 2 — Tests en base exécutés à la main (05 → 08/11/2026)

Ces tests ont été lancés en se mettant à la place de chaque compte, avec annulation des écritures après chaque test. **100 tests**, détail dans `tests-plomi.md` (projet Claude).

| Plage | Domaine | Résultat |
|---|---|---|
| T01–T18 | Cloisonnement gestionnaires A / B, droits sur fiches, listes, notifications | ✅ sauf T01, T03, T04, T16, T17 : écarts attendus dus aux comptes à double rôle, à relancer à la livraison |
| T19–T26 | Droits de l'expert (brouillons, annuaire, KPI, rapports, écriture interdite) | ✅ |
| T27–T34 | Présence, listes automatiques, stockage privé, fonctions fermées aux visiteurs | ✅ |
| T35–T40 | Attribution manuelle, listes d'experts | ✅ |
| T41–T48 | KPI et PLO | ✅ |
| T49–T55 | Base mandataire et recrutement | ✅ |
| T56–T61 | Création de mandat, drop, doublons, bénéficiaire retrouvé | ✅ |
| T62–T65 | Lancement et interruption d'intervention | ✅ |
| T66–T72 | Archives expert | ✅ |
| T73–T80 | Profil expert, suppression | ✅ sauf T80 ⏳ (suppression refusée avec mandat en cours) |
| T81–T91 | Médias (capture, éditeur, droits) | ✅ |
| T92–T100 | Préférences d'alerte, indicateurs groupes 1 et 2, temps de trajet | ✅ |

---

## Niveau 3 — Recette d'interface (à la main, apps publiées)

Règle : toujours tester dans les **apps publiées**, jamais dans l'aperçu de l'éditeur (pas de session, donc la base refuse tout).

### P — Vérification de présence (app expert)

Règles en base :
- code valable **30 min** ;
- **5 essais** de saisie ;
- **3 envois** au maximum, **1 par minute** au plus ;
- décharge si le bénéficiaire n'a pas d'e-mail ou si la vérification est bloquée.

| ID | Scénario | Attendu | Statut |
|---|---|---|---|
| P1 | Envoyer le code, saisir le bon code, commencer l'expertise | E-mail reçu, présence confirmée, « Commencer l'expertise » actif | ✅ 22/11 (MAN-0085, après réglage Brevo) |
| P2 | Saisir 5 codes faux | Essais restants affichés, blocage au 5e, décharge proposée | ⏳ |
| P3 | Renvoyer le code avant 1 min | Refusé avec message d'attente | ⏳ |
| P4 | Envoyer le code une 4e fois | Refusé (3 envois maximum) | ⏳ |
| P5 | « Commencer l'expertise » avant vérification | Bouton inactif | ⏳ |
| P6 | Décharge : cocher et valider | Expertise autorisée, décharge tracée | ⏳ |
| P7 | Bénéficiaire sans e-mail | Décharge proposée d'office | ⏳ |
| P8 | Envoi refusé par Brevo | Message clair, envoi non décompté, cause dans les journaux | ✅ 22/11 (IP non autorisée) |

### X — Parcours expert de bout en bout

| ID | Scénario | Attendu | Statut |
|---|---|---|---|
| X1 | Drop par le gestionnaire, mandat visible sur la carte expert | Marqueur à la bonne adresse | ✅ 22/11 |
| X2 | Prise en charge avec créneau | Carte masquée, bloc « Mandats à traiter en priorité » | ✅ 22/11 |
| X3 | Rapport RDF 4 étapes avec photos, synthèse, aperçu, envoi | Retour à l'accueil, mandat en attente de validation | ✅ 22/11 |
| X4 | Prendre un 2e mandat puis l'abandonner | Expert suspendu, gestionnaire notifié | ✅ 22/11 |
| X5 | Levée de la suspension par le gestionnaire | Bandeau retiré côté expert | ✅ 22/11 (lent, voir C3) |
| X6 | Quitter l'intervention, motif listé | Suspension et notification « Anomalie » | ⏳ |
| X7 | Rapport RDFS : accord destructif, pièce, constats, photo, envoi | Rapport reçu par le gestionnaire | ⏳ |
| X8 | RDFS en suite d'un RDF depuis la fiche mandat | Mandat RDFS lié, un seul par RDF | ⏳ |

### G — Côté gestionnaire

| ID | Scénario | Attendu | Statut |
|---|---|---|---|
| G1 | Rapport reçu : fiche mandat | Rapport, photos et commentaires visibles | ⏳ |
| G2 | PDF du rapport | Assureur, n° de dossier assureur, synthèse, annexes | ⏳ |
| G3 | Valider ou refuser le rapport | Statut mis à jour, expert notifié | ⏳ |
| G4 | Import CSV | Une seule notification récapitulative, pas une par mandat | ⏳ |
| G5 | Logos des assureurs dans Liste_drop, Current_drop et Archives | Logo en début de ligne | ⏳ |
| G6 | Liste_drop : filtres rapides, réinitialisation, compteur « N sélectionné(s) » | Pas d'ouverture de la fenêtre de fichier | ⏳ |
| G7 | Mandat sans localisation (MAN-0118) | Classé « Adresse non localisée », absent des cartes | ⏳ |
| G8 | Bouton rafraîchir et témoin de chargement (barre de navigation) | Rechargement, roue visible pendant les appels | ⏳ |
| G9 | Mandates_creation : bloc tiers, aperçu du logo | Champs sans chevauchement | ⏳ |
| G10 | Liste_experts : icônes visibles seulement avec une sélection, y compris « tout sélectionner » | Icônes conditionnelles | ⏳ |
| G11 | Zone de danger : suppression d'un assureur | Confirmation, données supprimées, fichiers en file | ⏳ |
| G12 | Retrait d'attribution pendant une intervention | Message clair côté expert à l'interruption | ✅ 22/11 |

### C — Corrections du 22/11 à revérifier (après publication)

| ID | Scénario | Attendu | Statut |
|---|---|---|---|
| C1 | Encadrés sauvegardés RDF (4 étapes) et RDFS | Ligne « Commentaire : … » affichée | ↻ |
| C2 | Témoin de chargement app expert | Pastille « Chargement… » pendant les appels | ↻ |
| C3 | Levée de suspension, expert resté sur l'accueil | Bandeau retiré en 30 s au plus, ou au retour sur l'accueil | ↻ |
| C4 | Interruption avec « Autre » sans détail, puis avec détail | Refus, puis acceptation ; notification « Autre — … » | ↻ |
| C5 | Carte expert : pas de pin au point 0° / 0° | Carte centrée sur la France | ↻ |
| C6 | Géocodage après un import CSV en rafale | Toutes les adresses localisées | ✅ 22/11 (9/9 rattrapées ; MAN-0118 imprécise) |

### T — Transverses

| ID | Scénario | Attendu | Statut |
|---|---|---|---|
| T-M1 | App expert sur mobile 375 px | Aucun débordement, boutons utilisables | ⏳ |
| T-M2 | App gestionnaire sur tablette | Filtres en retour à la ligne propre | ⏳ |
| T-CH | Charte graphique sur toutes les pages | Mêmes cartes, boutons et champs | ⏳ |
| T-SEC | Connexion avec un compte du mauvais rôle | Déconnexion immédiate et message | ⏳ |
| T-RGPD | Confidentialité, CGU, export et effacement expert | Pages publiques, actions tracées | ⏳ |

---

## Journal des anomalies trouvées en recette

| Date | Test | Anomalie | Cause | Correction |
|---|---|---|---|---|
| 22/11 | P1 | Code non reçu, erreur 500 | Brevo bloquait l'IP du serveur Supabase (AWS) ; erreur masquée | Message clair, envoi non décompté, cause journalisée ; IP autorisée dans Brevo |
| 22/11 | G12 | « Interruption impossible » sans raison | Attribution retirée par le gestionnaire pendant le test | Raison de la base affichée à l'expert |
| 22/11 | X1 | Pin au large de l'Afrique | Mandat sans coordonnées traité comme 0° / 0° | Carte expert filtrée sur les coordonnées valides |
| 22/11 | C6 | 9 adresses non localisées | HTTP 429 du service de localisation pris pour une adresse refusée | 429 réessayé, appels espacés de 120 ms |
| 22/11 | X5 | Suspension affichée longtemps après la levée | Fiche expert jamais relue après l'ouverture de l'app | Relecture à l'accueil et toutes les 30 s |
| 22/11 | X3 | Commentaires absents des encadrés | Résumé sans le champ commentaire | Ligne « Commentaire » ajoutée |
| 22/11 | X4 | Pas de motif « Autre » | Liste fermée | Motif « Autre » avec explication obligatoire |
