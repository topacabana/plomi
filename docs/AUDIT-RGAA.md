# Audit d'accessibilité (RGAA 4.1) — apps WeWeb publiées

Date : 18/11/2026. Apps auditées en production :
- PLOMI expert : Accueil (carte), Archives, Profil ;
- PLOMI mandataire : Connexion, Tableau de bord, Liste de drop, Création de mandat.

**Méthode** : script d'analyse exécuté dans le navigateur sur chaque page, plus des contrôles manuels.
- Le script vérifie : langue, titres, alternatives d'images, noms des liens et boutons, étiquettes de champs, contraste (calcul WCAG), taille des cibles, éléments cliquables non atteignables au clavier, zoom.
- Contrôle manuel : test à 375 px (smartphone).
- Les composants Google Maps sont exclus (tiers).
- Limite : session non connectée, donc les pages sont vides de données. Popups, tableaux remplis et formulaires RDF n'ont pas été audités.

## Résultats par critère du cahier des charges

| ID | Critère | Résultat | Constat |
|---|---|---|---|
| A01 | Alternatives des images | ✅ | 0 image sans `alt` sur les 7 pages |
| A02 | Contraste ≥ 4,5:1 | ✅ (1 écart) | 1 seul texte sous le seuil : le tiret « – » des valeurs vides du tableau de bord (gris `#94a3b8`, 2,56:1) |
| A03 | Navigation clavier | ❌ | Beaucoup d'éléments cliquables sont des `div` non atteignables au clavier : 3 par page dans l'app expert (cloche des notifications, filtres Type / Zones), 10 à 56 par page dans l'app mandataire (icônes d'action, raccourcis) |
| A04 | Formulaires : étiquettes | ❌ | Les champs n'ont qu'un texte indicatif (*placeholder*), sans étiquette liée : connexion (e-mail, mot de passe), création de mandat (12 champs), recherches, filtres de date. Seuls les champs fichier et les cases à cocher sont étiquetés |
| A05 | Structure des titres | 🟠 | App mandataire : un vrai H1 + des H2 sur le tableau de bord et la liste de drop, mais un seul H3 sur la création de mandat. App expert : aucun titre balisé (« ARCHIVES », « PROFIL » sont des textes mis en forme) |
| A06 | Composants dynamiques (ARIA) | ❓ | Non audité (popups fermées). Limite connue : WeWeb ne permet pas d'ajouter `aria-label`, `role` ni `tabindex` sans code |
| A07 | Zoom jusqu'à 200 % | ✅ | Zoom non bloqué (`user-scalable=yes`, `maximum-scale=10`) |
| A08 | Cibles tactiles ≥ 44 × 44 px | 🟠 | Boutons de 35 à 40 px de haut, lien « Mot de passe oublié ? » de 18 px, logo de 40 × 40 px |

## Autres constats

| Constat | Gravité | Correction proposée |
|---|---|---|
| Langue de la page déclarée en anglais (`lang="en"`) dans les deux apps (RGAA 8.3) | Majeure | Réglages WeWeb → langue de l'app = français |
| Aucune région de page (`main`, `nav`, `header`) | Mineure | Balise HTML des conteneurs principaux dans WeWeb |
| Badge « Made with WeWeb » posé sur l'onglet **Profil** de la barre de navigation expert sur mobile : le clic est intercepté | Majeure (usage) | Retirer le badge (offre WeWeb payante) ou remonter la barre de navigation |
| Création de mandat non adaptée à 375 px : la page s'étale sur 779 px (T09) | Moyenne : l'écran gestionnaire vise ordinateur / tablette (CC §3.2.1) | Colonnes en pile sous 768 px |
| **Pages accessibles sans être connecté** : accueil, archives et profil expert, tableau de bord, liste de drop et création de mandat s'ouvrent sans session (aucune donnée affichée : la RLS bloque, d'où « Chargement impossible ») | Majeure (sécurité / ergonomie) | Activer l'accès privé des pages dans WeWeb (utilisateurs authentifiés, redirection vers la connexion) |

## Exigences fonctionnelles vérifiées au passage

- **F03 réinitialisation du mot de passe : ✅.** Pages « Mot de passe oublié » et « Nouveau mot de passe » dans les deux apps, lien sur la connexion.
- **F44 centrage de la carte sur la position GPS : ❌.** La carte de l'accueil expert n'utilise pas la géolocalisation : elle s'ouvre sur une position fixe (Paris).
- **F41 pop-up mandat + lancement GPS : ❓.** Le clic sur un marqueur déclenche bien un workflow, mais il faut un compte expert avec un mandat sur la carte pour vérifier le bouton GPS.
- **R07 politique de confidentialité : 🟠.** Une page Confidentialité existe dans les deux apps (et CGU côté expert) ; pas de page « Mentions légales » distincte.
- **T09 (375 px)** : accueil, archives, profil expert et liste de drop sans défilement horizontal ; création de mandat en débordement.

## Priorités de correction

1. Accès privé des pages (sécurité) et langue française (rapides, réglages WeWeb).
2. Étiquettes des champs (A04) : remplacer les *placeholders* par des étiquettes visibles, en commençant par la connexion et la création de mandat.
3. Éléments cliquables au clavier (A03) : remplacer les `div` cliquables par des boutons ou des liens natifs WeWeb.
4. Titres balisés (A05) dans l'app expert, cibles de 44 px (A08), badge WeWeb.
