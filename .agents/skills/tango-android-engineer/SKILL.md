---
name: tango-android-engineer
description: This skill should be used when touching the Android layer of Tango KYC — "Gradle", "AndroidManifest", "permissions Android", "package name", "build configuration", "APK/AAB", "ressources Android", "Firebase Android", "google-services.json", "signing". Covers Gradle, Manifest, permissions, build config and Android resources without breaking Firebase or Google Sign-In.
triggers:
- android
- gradle
- manifest
- apk
- aab
- permissions
- package name
- google-services
---

# Android Engineer — Tango KYC

Commencer par lire `.agents/references/tango-kyc-rules.md`.

## Mission
Gérer la couche Android : Gradle, Manifest, permissions, package name, build config,
compatibilité, APK/AAB, ressources, sans casser Firebase ni Google Sign-In.

## Règles fermes
- Ne jamais modifier le package name (`com.tango.kyc.tango_kyc_verification`) sans autorisation explicite.
- Ne jamais casser Firebase : `android/app/google-services.json` doit rester cohérent avec le package.
- Ne jamais casser Google Sign-In (empreinte SHA, configuration OAuth).
- Ne jamais supprimer une permission nécessaire sans analyse d'impact.
- Ne jamais changer la configuration de production sans justification écrite.

## Procédure
1. READ — lire `android/app/build.gradle(.kts)`, `AndroidManifest.xml`, `google-services.json` (présence + package, jamais le contenu secret).
2. UNDERSTAND — identifier ce qui dépend de ce qu'on modifie (Firebase, Google Sign-In, FCM).
3. PLAN — modification minimale, risque explicité.
4. MODIFY — uniquement le nécessaire.
5. TEST — `flutter analyze`, `flutter test` ; le build APK n'est lancé que sur demande explicite.
6. VERIFY — package inchangé, Firebase intact, permissions inchangées sans raison.
7. REPORT.

## Environnement (état réel à ce jour)
- Flutter 3.47.5 stable.
- **Aucun JDK** (`java` absent) et **SDK Android incomplet** (`/usr/lib/android-sdk` ne contient que `build-tools`).
- Conséquence : `flutter build apk` échoue ici. Ne pas prétendre avoir construit un APK.

## Anti-patterns
- Régénérer `google-services.json` ou renommer l'applicationId pour « faire propre ».
- Ajouter `android:exported` ou des permissions sans comprendre la cible Android.
- Lancer un build de production implicitement.

## Ressources
- Règles projet : `.agents/references/tango-kyc-rules.md`
- Préview device : skill `tango-appetize-preview`
