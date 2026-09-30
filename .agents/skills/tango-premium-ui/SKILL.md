---
name: tango-premium-ui
description: 'This skill should be used when designing or refining Tango KYC screens — "rendre cet écran premium", "moderniser le splash", "refaire l’onboarding", "améliorer le login", "corriger le responsive", "ajouter des animations", "améliorer le design", "Material 3", "dark mode", "glassmorphism". Owns visual design: type, espacement, gradients, profondeur, glow, animations, responsive Android.'
triggers:
- premium
- design
- ui
- ux
- splash
- onboarding
- responsive
- Material 3
- glassmorphism
- animation
---

# Premium Mobile UI/UX 2026 — Tango KYC

Commencer par lire `.agents/references/tango-kyc-rules.md` (section 5 par. visuels obligatoire).

## Mission
Écrans mobiles premium, modernes, 2026 : Material 3, responsive, SafeArea, typographie,
espacement, gradients, profondeur, glow subtil, animations légères, dark/light.

## Style recherché
Premium, moderne, élégant, fluide, professionnel — inspiré des applications sociales/support
modernes. Palette : violet, magenta, cyan, bleu très sombre. Grande lisibilité avant tout.

## Procédure UI (obligatoire, dans cet ordre)
1. Analyser l'écran actuel : lire le widget en entier, noter chaque élément déjà rendu.
2. Identifier les éléments existants : qu'est-ce qui vient de l'asset de fond ? du logo ? du thème ?
3. Modifier uniquement ce qui est nécessaire.
4. Vérifier les overflow sur plusieurs tailles.
5. Vérifier les contraintes Flutter (bornes de hauteur, flex, scroll).
6. Tester sur plusieurs tailles logiques : 320x568, 360x640, 360x800, 390x844, 412x915.

## Règles fermes
- Ne jamais ajouter un élément visuel déjà présent dans un background (silhouette, décor, lumière).
- Utiliser les assets existants ; chercher avant de créer.
- Respecter les proportions originales ; jamais de déformation (`BoxFit.contain` pour un logo).
- Ne pas créer une deuxième silhouette si elle existe déjà dans l'image.
- Pas de faux status bar : utiliser le vrai `SafeArea`.
- Adapter à différentes tailles Android (y compris notch / punch-hole / gesture bar).
- Logo transparent : aucun fond blanc, aucun halo carré.

## Anti-patterns
- Superposer un cercle/bulle décoratif sur une image qui en contient déjà.
- Centrer un texte que la composition demande à gauche (ou l'inverse) sans raison mesurée.
- Animer des propriétés qui provoquent un re-layout à chaque frame (préférer opacity/transform).

## Vérifications
- Aucun overflow (aucune exception de rendu) sur les tailles testées.
- Contraste lisible sur tous les textes.
- `flutter analyze` propre, `flutter test` vert.

## Ressources
- Règles projet : `.agents/references/tango-kyc-rules.md`
- QA visuelle : skill `tango-visual-qa`
