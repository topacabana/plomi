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

Résultat : tous OK sauf 01, 03, 04, 16, 17, écarts **attendus** dus aux comptes de test à double rôle (gestionnaire + expert) ; à relancer après nettoyage des comptes. Test 80 non exécuté (aucun cas dans les données).

## 2. Recette dans l'interface
Scénarios pas à pas par page, pour les deux apps WeWeb (création de mandat, Liste_drop, attribution, PLO, recrutement, KPI, rapports RDF / RDFS, archives, profil, capture photo).

## 3. À venir
- Conversion des tests en base au format **pgTAP** (`supabase test db`) dans `tests/db/`.
- Exécution automatique à chaque push (GitHub Actions) sur une base locale en conteneur.
