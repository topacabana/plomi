# PLOMI — Bibliothèque des tests

Version du 23/11/2026 (21 h). Recette d'interface terminée : tous les tests applicables sont passés. Document de référence : chaque test garde **son identifiant pour toujours**. On ne renumérote jamais. Un test supprimé est barré, pas réutilisé.

**Statuts** : ✅ passé · ❌ échec (anomalie ouverte) · ↻ corrigé, à revérifier · ⏳ à faire · ➖ non applicable.

**Comptes de test** (tous sur la boîte de Thomas) :
- gestionnaire : `cadelisthomas7` ;
- expert : `cadelisthomas8` ;
- bénéficiaires : `cadelisthomas7+<assureur><n>@gmail.com`.

**Procédure de compte rendu** : identifiant du test, mandat utilisé, ce qui s'affiche, capture si écart. Les écarts sont reportés au format **entrée / attendu / obtenu / analyse / correction** dans la partie 9 du mémoire.

---

## Niveau 1 — Tests automatiques pgTAP (CI GitHub)

Les tests sont lancés à chaque envoi sur le dépôt `topacabana/plomi`, sur une base Docker neuve. Ils couvrent **20 fichiers SQL et 139 assertions**, plus **5 tests unitaires Deno** sur les Edge Functions ; tous passent (CI verte le 23/11).

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
| 09_import_csv | 13 | Import CSV : décodage, séparateur, colonnes, conversions, lignes en erreur, code postal ou ville obligatoire |
| 10_fiche_mandat | 3 | Coordonnées du bénéficiaire cloisonnées par organisation |
| 11_attribution_messages | 7 | Attribution manuelle : messages distincts (jeu d'essai, écarts 1 et 2) |
| 12_verification_presence | 17 | Code e-mail ou décharge ; fonctions réservées au serveur |
| 13_separation_roles | 3 | Carte de l'app expert réservée aux experts |
| 14_interruption_suspension | 7 | Quitter sans rapport : expert suspendu jusqu'à régularisation |
| 15_abandon_suspension | 5 | Abandon après prise en charge : même suspension |
| 16_rdfs_suite | 12 | RDFS en suite d'un RDF : lié, droppé sans redrop, une seule fois |
| 17_rdfs_liens | 7 | Liens RDF ↔ RDFS sur la fiche mandat |
| 18_zone_danger_retrait | 6 | Gestionnaire retiré : plus aucun droit ; fichiers mis en file de suppression |
| 19_interruption_motif_autre (PG-19) | 6 | Motif « Autre » refusé sans explication de 10 caractères, accepté avec ; notification « Autre — … » |
| 21_archives_purge (PG-21) | 10 | Purge des archives : plus de 5 ans seulement, ou toutes sur choix explicite ; réservée aux gestionnaires, limitée à leur organisation, tracée |
| geocode-addresses/classement_test.ts (PG-20, Deno) | 5 | Géocodage : 429, 5xx ou absence de réponse → adresse retentée ; autres 4xx → adresse refusée |

PG-20 n'existe qu'en Deno : la règle du 429 est dans l'Edge Function, pas en base. Le numéro 20 est donc absent des fichiers SQL.

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
- au 5e code faux, la vérification est **bloquée** et les gestionnaires sont **prévenus** (pas de décharge : l'expert doit contacter son gestionnaire) ;
- la décharge n'est proposée **que si le bénéficiaire n'a pas d'e-mail** ; les gestionnaires sont prévenus.

| ID | Scénario | Attendu | Statut |
|---|---|---|---|
| P1 | Envoyer le code, saisir le bon code, commencer l'expertise | E-mail reçu, présence confirmée, « Commencer l'expertise » actif | ✅ 22/11 (MAN-0085, après réglage Brevo) |
| P2 | Saisir 5 codes faux | Essais restants affichés, blocage au 5e, gestionnaires notifiés, aucune décharge proposée | ✅ 22/11 (attendu corrigé le 23/11) |
| P3 | Renvoyer le code avant 1 min | Refusé avec message d'attente | ✅ 22/11 |
| P4 | Envoyer le code une 4e fois | Refusé (3 envois maximum) | ✅ 22/11 |
| P5 | « Commencer l'expertise » avant vérification | Bouton inactif | ✅ 22/11 |
| P6 | Décharge : cocher et valider (bénéficiaire sans e-mail) | Expertise autorisée, décharge tracée, gestionnaires notifiés | ✅ 22/11 |
| P7 | Bénéficiaire sans e-mail | Décharge proposée d'office | ✅ 22/11 |
| P8 | Envoi refusé par Brevo | Message clair, envoi non décompté, cause dans les journaux | ✅ 22/11 (IP non autorisée) |

### X — Parcours expert de bout en bout

| ID | Scénario | Attendu | Statut |
|---|---|---|---|
| X1 | Drop par le gestionnaire, mandat visible sur la carte expert | Marqueur à la bonne adresse | ✅ 22/11 |
| X2 | Prise en charge avec créneau | Carte masquée, bloc « Mandats à traiter en priorité » | ✅ 22/11 |
| X3 | Rapport RDF 4 étapes avec photos, synthèse, aperçu, envoi | Retour à l'accueil, mandat en attente de validation | ✅ 22/11 |
| X4 | Prendre un 2e mandat puis l'abandonner | Expert suspendu, gestionnaire notifié | ✅ 22/11 |
| X5 | Levée de la suspension par le gestionnaire | Bandeau retiré côté expert | ✅ 22/11 (lent, voir C3) |
| X6 | Quitter l'intervention, motif listé | Suspension et notification « Anomalie » | ✅ 22/11 |
| X7 | Rapport RDFS : accord destructif, pièce, constats, photo, envoi | Rapport reçu par le gestionnaire | ✅ 22/11 |
| X8 | RDFS en suite d'un RDF depuis la fiche mandat | Mandat RDFS lié, un seul par RDF ; actions masquées sur le mandat d'origine | ✅ 23/11 |
| X9 | Notifications expert : attribution, retrait, drop ciblé, suspension, levée | Notification reçue et liste rafraîchie sans recharger | ✅ 23/11 |
| X10 | Profil expert : lien vers les CGU | Page CGU ouverte depuis le profil | ✅ 23/11 |

### G — Côté gestionnaire

| ID | Scénario | Attendu | Statut |
|---|---|---|---|
| G1 | Rapport reçu : fiche mandat | Rapport, photos et commentaires visibles | ✅ 22/11 |
| G2 | PDF du rapport | Assureur, n° de dossier assureur, synthèse, annexes | ✅ 22/11 |
| G3 | Valider ou refuser le rapport | Statut mis à jour, expert notifié | ✅ 22/11 |
| G4 | Import CSV | Une seule notification récapitulative, pas une par mandat | ✅ 23/11 |
| G5 | Logos des assureurs dans Liste_drop, Current_drop et Archives | Logo en début de ligne | ✅ 23/11 |
| G6 | Liste_drop : filtres rapides, réinitialisation, compteur « N sélectionné(s) » | Pas d'ouverture de la fenêtre de fichier | ✅ 23/11 |
| G7 | Mandat sans localisation (MAN-0118) | Classé « Adresse non localisée », absent des cartes | ✅ 23/11 |
| G8 | Bouton rafraîchir et témoin de chargement (barre de navigation) | Rechargement, roue visible pendant les appels | ✅ 23/11 |
| G9 | Mandates_creation : bloc tiers, aperçu du logo | Champs sans chevauchement | ✅ 23/11 |
| G10 | Liste_experts : icônes visibles seulement avec une sélection, y compris « tout sélectionner » | Icônes conditionnelles | ✅ 23/11 |
| G11 | Zone de danger : suppression d'un assureur | Supprimer si aucun mandat, sinon archiver ; confirmation, fichiers en file | ✅ 23/11 |
| G12 | Retrait d'attribution pendant une intervention | Message clair côté expert à l'interruption | ✅ 22/11 |
| G13 | Complétion par le client d'un mandat importé sans créneaux | Page publique, créneaux enregistrés, pastille « Compléter » retirée | ✅ 23/11 |
| G14 | Modifier un mandat jusqu'à son archivage | Bouton Modifier sur toute fiche non archivée ; « Mandat modifié » et champs dans l'historique | ✅ 23/11 |
| G15 | Diffusion d'un mandat non localisé ou au bénéficiaire incomplet | Drop refusé avec message ; mandat absent de la vue expert | ✅ 23/11 |
| G16 | Création pré-remplie depuis la liste de drop | Organisme demandeur et identité repris et verrouillés | ✅ 23/11 |
| G17 | Fiche mandat clôturée, annulée ou ayant un RDFS | Boutons d'action et zone de danger masqués | ✅ 23/11 |
| G18 | Code couleur des boutons sur toutes les pages | Orange : drop / redrop ; vert : attribuer ; rouge : retirer / supprimer | ✅ 23/11 |
| G19 | « Tout sélectionner » sur Current_drop, Liste_drop, Experts, Archives | Au-dessus de la liste, compteur « n sélectionné(s) », cases identiques à celles des lignes | ✅ 23/11 |
| G20 | Archives : télécharger et supprimer | Liste des archives, avertissement < 5 ans, deux choix, phrase de confirmation ; PDF téléchargé avant toute suppression | ✅ 23/11 |
| G21 | Demandes RGPD : date de réception | Date future ou de plus d'un an refusée ; échéance affichée | ✅ 23/11 |
| G22 | Demande d'effacement avec mandats en cours | Refus expliqué, rien n'est effacé | ✅ 23/11 |

### C — Corrections du 22/11 revérifiées après publication

| ID | Scénario | Attendu | Statut |
|---|---|---|---|
| C1 | Encadrés sauvegardés RDF (4 étapes) et RDFS | Ligne « Commentaire : … » affichée | ✅ 23/11 |
| C2 | Témoin de chargement app expert | Pastille « Chargement… » pendant les appels | ✅ 23/11 |
| C3 | Levée de suspension, expert resté sur l'accueil | Bandeau retiré en 30 s au plus, ou au retour sur l'accueil | ✅ 23/11 |
| C4 | Interruption avec « Autre » sans détail, puis avec détail | Refus, puis acceptation ; notification « Autre — … » | ✅ 23/11 |
| C5 | Carte expert : pas de pin au point 0° / 0° | Carte centrée sur la France | ✅ 23/11 |
| C6 | Géocodage après un import CSV en rafale | Toutes les adresses localisées | ✅ 22/11 (9/9 rattrapées ; MAN-0118 imprécise) |

### T — Transverses

| ID | Scénario | Attendu | Statut |
|---|---|---|---|
| T-M1 | App expert sur mobile 375 px | Aucun débordement, boutons utilisables | ✅ 23/11 |
| T-M2 | App gestionnaire sur tablette | Filtres en retour à la ligne propre | ➖ app gestionnaire utilisée sur ordinateur uniquement |
| T-CH | Charte graphique sur toutes les pages | Mêmes cartes, boutons et champs | ✅ 23/11 |
| T-SEC | Connexion avec un compte du mauvais rôle | Déconnexion immédiate et message | ✅ 23/11 |
| T-RGPD | Confidentialité, CGU, export et effacement expert | Pages publiques, actions tracées | ✅ 23/11 (gestionnaire et expert, traces vérifiées) |
| T-SEC2 | Ouvrir une page privée sans session ou pendant le contrôle du rôle | Écran « Vérification du compte… », aucune donnée affichée avant validation | ✅ 23/11 |

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
| 23/11 | G8 | Témoin de chargement invisible côté gestionnaire | Appels plus courts que le délai d'affichage | Affichage forcé 800 ms après « Rafraîchir » |
| 23/11 | G10 | Les icônes décalent la mise en page à la sélection | Rendu conditionnel | Visibilité au lieu du rendu conditionnel |
| 23/11 | G11 | Seul « Archiver » proposé | Zone de danger non adaptée au nombre de mandats | Suppression si aucun mandat, archivage sinon |
| 23/11 | X8 | Actions encore proposées sur un mandat clôturé ou suivi d'un RDFS | Boutons non conditionnés au statut | Boutons et zone de danger masqués |
| 23/11 | T-SEC | La page s'affiche pendant le contrôle du rôle | Contrôle lancé après l'affichage | Écran de vérification + pages privées WeWeb |
| 23/11 | T-SEC | Message de refus effacé (app expert) | Message vidé après la tentative de connexion | Message vidé avant la connexion |
| 23/11 | T-RGPD | Échéance incompréhensible, date future acceptée | Date de réception non contrôlée | Contrôle en base, échéance renvoyée et affichée |
| 23/11 | T-RGPD | Bouton d'effacement sans réponse | Refus de la base non affiché | Message de refus (mandats en cours) |
| 23/11 | T-RGPD | Pas de lien vers les CGU dans le profil expert | Lien absent | Lien ajouté |
| 23/11 | T-M1 | Fenêtre du mandat mal alignée, cases des archives trop petites | Ordre et marges des blocs | Titre et adresse en tête, boutons empilés, cases 24 px |
| 23/11 | T-CH | Code couleur des boutons seulement sur Current_drop | Styles saisis page par page | Code couleur appliqué partout ; bouton « Supprimer » retiré de Liste_drop |
| 23/11 | T-CH | « Tout sélectionner » loin de la liste, sans compteur | Case dans la barre de filtres | Barre au-dessus de chaque liste avec compteur |
| 23/11 | CI | Test 09 en échec depuis la règle « code postal ou ville » | Fichier de test sans colonne Ville | Colonne ajoutée + assertion sur la règle |
| 23/11 | T-CH | Cases des archives jamais cochées à l'écran | Valeur lue une seule fois à l'affichage | Case liée à la sélection ; design unique pour toutes les cases |
