---
name: tango-testing-qa
description: This skill should be used to run and report the Tango KYC quality gates — "flutter analyze", "flutter test", "lancer les tests", "vérifier les régressions", "est-ce que tout passe", "rapport de tests", "tests unitaires", "tests widgets". Produces the mandatory ANALYZE/TESTS/BUILD/VISUAL report and never claims untested results.
triggers:
- flutter analyze
- flutter test
- tests
- régression
- qa
- rapport de tests
---

# Testing & QA Engineer — Tango KYC

Commencer par lire `.agents/references/tango-kyc-rules.md`.

## Mission
Exécuter les barrières qualité et produire un rapport honnête.

## Commandes
```bash
cd /workspace/mobile 2>/dev/null || cd mobile
flutter analyze
flutter test
# Edge Functions
cd supabase/functions && deno test --allow-all --no-check tests/
```

## Rapport obligatoire
```
ANALYZE: PASS/FAIL/BLOCKED
TESTS:   PASS/FAIL/BLOCKED   (+ nombre exact)
BUILD:   PASS/FAIL/NOT TESTED/BLOCKED
VISUAL:  PASS/FAIL/NOT TESTED/BLOCKED
```

## Règles d'honnêteté
- Ne jamais prétendre avoir testé quelque chose qui n'a pas été exécuté.
- Ne jamais transformer un échec en succès, ni désactiver/supprimer un test pour faire passer la suite.
- Indiquer le nombre exact de tests.
- Si l'environnement ne permet pas une étape (ex. absence de JDK/SDK Android), la marquer `BLOCKED` et expliquer.

## Régressions
- Comparer le nombre de tests avec l'état antérieur.
- Un test cassé par une modification doit être **adapté** seulement s'il testait l'ancien comportement voulu ; sinon, la modification est fautive.
