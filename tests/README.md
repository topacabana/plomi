# Tests PLOMI

## 1. Tests en base (sécurité et composants métier)
100 tests exécutés directement dans PostgreSQL en prenant l'identité de chaque compte (`set role authenticated` + `request.jwt.claims`), écritures annulées après chaque test (transaction + rollback). Dernière exécution : 05, 06 et 08/11/2026.

Comptes : gestionnaire A (org Assurances Solidaires Mutuelle), gestionnaire B (org Covéa), un expert.

| Domaine | Tests | Exemples |
|---|---|---|
| Cloisonnement par organisation et par rôle (RLS) | 01–07, 16–26, 37, 55, 71–72, 90–91 | un gestionnaire ne voit aucun mandat d'une autre organisation ; un expert ne voit que ses rapports |
| Accès sans connexion | 32–34 | `save_mandate_form` refusée à un visiteur |
| Création / drop de mandat | 08–10, 56–61 | doublon prénom + adresse détecté ; bénéficiaire retrouvé au lieu d'être recréé |
| Listes d'experts | 11–13, 29–30, 38–40, 51–52 | ajout refusé sur une liste automatique ou d'une autre organisation |
| Attribution manuelle | 35–36 | lot de 2 mandats : 1 attribué, 1 refus signalé |
| KPI / PLO | 41–48, 93–100 | catalogue de 50 KPI ; stratégie PLO créée, sauvegardée, supprimée |
| Recrutement | 49–55 | expert hors base refusé en liste ; recrutement → statut « new » |
| App expert (lancement, archives, profil, médias) | 62–92 | code postal invalide refusé ; média hors du dossier du mandat refusé |

Résultat au 08/11 : tous OK sauf 01, 03, 04, 16, 17, écarts **attendus** dus aux comptes de test à double rôle (gestionnaire + expert). Test 80 non exécuté (aucun cas dans les données).

**18/11/2026 — comptes à double rôle nettoyés et tests 01 à 18 relancés** : les 5 fiches expert reliées à des comptes gestionnaires ont reçu chacune un compte expert dédié, sans mot de passe (script [`scripts/donnees/20261118_delier_comptes_double_role.sql`](../scripts/donnees/20261118_delier_comptes_double_role.sql), retour arrière prévu). Relance : script [`db/tests_cloisonnement_01_18.sql`](db/tests_cloisonnement_01_18.sql), **17 tests OK sur 17** (01–13, 15–18 ; le 14, message groupé, est couvert par la recette UI). Le test 15 a fait apparaître que `create_expert_record` restait exécutable par un compte connecté (elle refusait déjà l'appel en première ligne) : le droit d'exécution a été retiré par la migration du 18/11.

## 2. Recette dans l'interface
Scénarios pas à pas par page, pour les deux apps WeWeb (création de mandat, Liste_drop, attribution, PLO, recrutement, KPI, rapports RDF / RDFS, archives, profil, capture photo).

## 3. Tests automatiques (pgTAP) et intégration continue
Les tests automatiques sont dans `supabase/tests/` (65 assertions pgTAP, 11 fichiers) : sécurité du schéma (RLS partout, fonctions fermées aux visiteurs), cloisonnement entre organisations, machine à états, attribution réservée aux experts ayant accepté les CGU, accord destructif RDFS, redrop avec justification, archivage, organisme demandeur, import CSV, fiche mandat, messages de l'attribution manuelle. Chaque fichier charge le jeu de données `ci/fixtures.sql` (`tests.seed()`) dans une transaction annulée.

La CI (`.github/workflows/ci.yml`) tourne à chaque push sur `main` :
1. démarre Supabase en conteneurs Docker (`supabase start`) ;
2. reconstruit la base avec `ci/build_db.sh` : instantané du schéma du 08/11/2026 (`supabase/schema`, remis en ordre par `ci/build_baseline.py`) puis rejeu de toutes les migrations postérieures ;
3. lance `supabase test db` (pgTAP) ;
4. lance l'analyse statique `supabase db lint` (informative).

Premier résultat utile : le rejeu a révélé une fonction (`geo_km`) présente en production mais absente des migrations du dépôt, corrigée par `20261113225200_rattrapage_geo_km.sql`. Les migrations postérieures à l'instantané portent désormais le même numéro de version qu'en production.

Exécution locale : `supabase start`, puis `bash ci/build_db.sh postgresql://postgres:postgres@127.0.0.1:54322/postgres` et `supabase test db`.

**19/11/2026 — recette d'interface (gestionnaire + expert)** : parcours complets joués en production avec un compte gestionnaire et le compte expert de démonstration (Sophie Delorme) : création d'un brouillon, contrôle de doublon, ajout à la liste de drop, attribution, prise en charge, rapport RDF (pièce, étapes non pertinentes, synthèse), aperçu, envoi, PDF. Anomalies relevées puis corrigées dans l'éditeur (à publier) : retour à l'accueil absent après « Confirmer l'envoi » (workflow réorganisé : nettoyage et navigation dans les deux branches du PDF) ; bouton d'itinéraire GPS absent de la popup du marqueur (F41, ajouté) ; recherche « Rechercher un brouillon » inopérante (source de données inexistante, filtre en égalité stricte, message en anglais : recherche partielle sur nom, prénom, adresse, ville, référence) ; statut brut « draft » dans la popup doublon (libellés français) ; icônes d'action de la liste des experts (dont le message groupé) coupées sous ~900 px de large (retour à la ligne). Données de test MAN-0049 / MAN-0050 supprimées après la recette.

**19/11/2026, 11 h — contre-recette après publication** : recherche de brouillon OK (« rena » → 7 brouillons, « zzqx » → « Aucun brouillon ne correspond »). Parcours expert complet sur un mandat de recette (MAN-RECETTE, Fondettes) : popup du marqueur avec bouton « Itinéraire GPS » (URL Google Maps vers les coordonnées du mandat), prise en charge, lancement, RDF (1 pièce, étapes 2 à 4 non pertinentes), synthèse, aperçu, « Confirmer l'envoi » → **retour à l'accueil** ; en base : mandat `waiting_report`, 1 rapport, 1 pièce, PDF généré. Nouvelles anomalies corrigées dans l'éditeur (à publier) : créneaux affichés au format ISO dans la popup de prise en charge (libellés « JJ/MM/AAAA HH:mm – HH:mm ») ; sur mobile, popup de 200 px de large dont les boutons débordaient sous la carte (largeur écran − 32 px, hauteur automatique) ; tiret rouge affiché à vide.
