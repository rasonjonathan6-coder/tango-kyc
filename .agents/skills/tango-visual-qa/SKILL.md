---
name: tango-visual-qa
description: This skill should be used when verifying Tango KYC screens visually — "vérifier visuellement les écrans", "QA visuelle", "il y a un overflow", "le texte est coupé", "mauvais alignement", "SafeArea incorrect", "image déformée", "problème de contraste", "animation cassée", "clipping". Detects overflow, clipping, misalignment, truncation, contrast and SafeArea issues, with mandatory PASS/FAIL/NOT TESTED/BLOCKED classification.
triggers:
- qa visuelle
- visual qa
- overflow
- clipping
- alignement
- contraste
- safearea
- débordement
---

# Visual QA Agent — Tango KYC

Commencer par lire `.agents/references/tango-kyc-rules.md`.

## Mission
Vérifier qu'un écran est réellement correct visuellement, pas seulement qu'il compile.
Rechercher : overflow, clipping, mauvais alignement, textes coupés, boutons mal dimensionnés,
SafeArea incorrect, responsive incorrect, images déformées, contraste insuffisant, animations cassées.

## Protocole
1. Choisir les tailles : 320x568, 360x640, 360x800, 390x844, 412x915.
2. Ajouter/étendre un test widget qui pompe l'écran à chaque taille et vérifie
   `tester.takeException()` est nul (aucune exception de rendu = pas d'overflow).
3. Pour les insets : notch (top 44 / bottom 34), punch-hole (top 24), gesture bar (top 30 / bottom 48).
4. Mesurer la géométrie réelle avec `tester.getRect(...)` quand l'alignement est en cause.
5. Pour un rendu pixel, capturer via `RepaintBoundary.toImage` **dans `tester.runAsync`**
   (le décodage d'image est asynchrone réel, plus la frame doit être pompée).
6. Ne jamais conclure depuis une capture dont le décodage d'asset n'a pas eu le temps d'aboutir :
   prévoir un délai asynchrone avant le rendu.

## Pièges connus (vécus sur ce projet)
- Un asset non décodé apparaît invisible dans une capture de test — ne pas en déduire un bug de code.
- `toByteData` dans un `testWidgets` sans `runAsync` bloque la suite (fake-async) : convertir en test simple.
- Un `Spacer` dans une colonne défilante plante (« unbounded height »), ce qui ressemble à tort à un bug visuel.

## Classification obligatoire
Chaque point vérifié reçoit un statut : `PASS`, `FAIL`, `NOT TESTED`, `BLOCKED`.
Ne jamais écrire `PASS` si le test n'a pas réellement été exécuté.

## Ressources
- Règles projet : `.agents/references/tango-kyc-rules.md`
- Design : skill `tango-premium-ui`
