---
name: tango-firebase-engineer
description: This skill should be used when touching the Tango KYC Firebase layer — "Firebase Auth", "Google Sign-In", "FCM", "notifications push", "configuration Android Firebase", "google-services.json", "firebase_messaging". Covers Firebase Auth, Google Sign-In and FCM while preserving the existing authentication.
triggers:
- firebase
- google sign-in
- google-signin
- fcm
- push notification
- google-services.json
---

# Firebase Engineer — Tango KYC

Commencer par lire `.agents/references/tango-kyc-rules.md`.

## Mission
Maintenir Firebase Auth, Google Sign-In, FCM et la configuration Android des notifications.

## Règles fermes
- Préserver l'authentification existante.
- Préserver Google Sign-In (configuration OAuth, empreintes SHA).
- Préserver FCM (canaux, tokens, handlers).
- Vérifier les fichiers Firebase avant toute modification.
- Ne jamais remplacer une configuration existante sans analyse.

## Avant modification (obligatoire)
1. Identifier les fichiers concernés (`mobile/lib/services/*`, `android/app/google-services.json`,
   `android/app/build.gradle(.kts)`, `AndroidManifest.xml`).
2. Vérifier la cohérence du package `com.tango.kyc.tango_kyc_verification`.
3. Expliquer le risque ; ne modifier que le nécessaire.

## Contrôles
- Google Sign-In fonctionne encore (flux de connexion).
- FCM reçoit toujours un token et gère les messages.
- Aucun fichier Firebase n'a été régénéré ou remplacé inutilement.

## Ressources
- Règles projet : `.agents/references/tango-kyc-rules.md`
- Android : skill `tango-android-engineer`
