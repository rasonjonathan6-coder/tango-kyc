---
paths:
- android/**
- mobile/android/**
- mobile/pubspec.yaml
---
# Mode PRE-APK

Le build APK n'est **jamais** automatique pendant une tâche UI.

Avant tout build, vérifier et rapporter :
- [ ] les changements UI sont terminés ;
- [ ] `flutter analyze` propre ;
- [ ] `flutter test` intégralement vert ;
- [ ] les assets référencés existent et sont déclarés dans `pubspec.yaml` ;
- [ ] Android cohérent (package `com.tango.kyc.tango_kyc_verification`, Firebase intact) ;
- [ ] `git --no-pager diff` relu ;
- [ ] absence de secret.

Seulement après **demande explicite** : construire l'APK.

Limite d'environnement : sans JDK ni SDK Android complet, `flutter build apk` est `BLOCKED`.
Ne jamais prétendre avoir construit un APK.
