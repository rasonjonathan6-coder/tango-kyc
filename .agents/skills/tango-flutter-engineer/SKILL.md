---
name: tango-flutter-engineer
description: This skill should be used when working on the Tango KYC Flutter/Dart client — "modifier un widget", "corriger une erreur de compilation Dart", "ajouter un écran Flutter", "changer la navigation", "toucher au state management", "optimiser une animation Flutter", "corriger un écran Flutter". Covers widgets, navigation, état, responsive, animations, performance and compilation errors inside mobile/.
triggers:
- flutter
- dart
- widget
- écran Flutter
- navigation
- state management
---

# Flutter / Dart Engineer — Tango KYC

Commencer par lire `.agents/references/tango-kyc-rules.md` (règles projet, mode UI ONLY, rapport final).

## Mission
Faire évoluer le client Flutter `mobile/` sans casser l'existant : widgets, navigation,
gestion d'état existante, responsive, animations, performance, erreurs de compilation.

## Procédure
1. READ — lire le fichier ciblé en entier, plus ses appels (`grep` sur la classe/fonction) et les tests associés.
2. UNDERSTAND — identifier l'API publique, les routes, le state management en place. Ne pas supposer : vérifier.
3. PLAN — décrire la modification minimale. Si plusieurs fichiers sont concernés, lister qui est maître de quel fichier.
4. MODIFY — modifier uniquement le nécessaire.
5. TEST — `cd mobile && flutter analyze && flutter test`.
6. VERIFY — relire le diff ; vérifier qu'aucune API ni route n'a changé.
7. REPORT — format obligatoire.

## Règles
- Comprendre le code existant avant toute modification.
- Ne pas réécrire inutilement une fonctionnalité qui marche.
- Conserver les APIs et les routes existantes ; ne pas renommer une méthode publique sans raison.
- Éviter toute dépendance nouvelle. Si une dépendance est indispensable, le justifier explicitement.
- Respecter le state management déjà utilisé dans le projet ; ne pas en introduire un autre.
- Un `Spacer`/`Expanded` exige un parent à hauteur **bornée** : jamais dans une colonne défilante.
- Imports en haut de fichier. Code propre, commentaires minimaux.

## Vérifications obligatoires
- `flutter analyze` → doit être `No issues found!`
- `flutter test` → doit passer intégralement
- Aucune régression : le nombre de tests ne doit pas baisser.

## Erreurs fréquentes à éviter
- Casser une route ou un nom de widget utilisé par un test.
- Ajouter un `MediaQuery`/`SafeArea` en double.
- Modifier `main.dart`, l'auth ou les services pour un changement purement visuel.

## Ressources
- Règles projet : `.agents/references/tango-kyc-rules.md`
- Conventions dépôt : `AGENTS.md`
