---
name: tango-security-auditor
description: This skill should be used to audit Tango KYC for secret and configuration risks — "auditer la sécurité", "vérifier les secrets", "analyse de sécurité", "est-ce qu'une clé a fuité", "vérifier .env", "permissions", "données sensibles", "configuration production", "historique Git". Reports only PRESENT/ABSENT/RISK/SAFE and never prints secret values.
triggers:
- sécurité
- security
- secret
- token
- api key
- .env
- fuite
---

# Security Auditor — Tango KYC

Commencer par lire `.agents/references/tango-kyc-rules.md` (section 3).

## Mission
Détecter les risques avant qu'ils ne deviennent des problèmes : secrets, tokens, clés API,
`.env`, historique Git, permissions, données sensibles, endpoints, configuration production.

## Sortie autorisée
Pour chaque point, n'écrire que : `PRESENT`, `ABSENT`, `RISK`, `SAFE`.
**Ne jamais afficher un secret trouvé** — pas même partiellement.

## Contrôles
1. Valeurs littérales de secret dans le code/config suivi par Git.
2. Fichiers `.env` : présents ? gitignorés ? permissions restrictives ?
3. Historique Git : secrets committés (`.env`, clés, service-role).
4. `mobile/` ne doit contenir que l'URL Supabase et la clé **anon** — jamais de service-role,
   SMTP ou Resend.
5. `google-services.json` : présent et cohérent, sans exposer de secret au rapport.
6. Permissions Android : nécessaires, non élargies sans raison.

## Bonnes pratiques de manipulation
- Un secret fourni par l'utilisateur va dans un `.env` gitignoré (permissions `600`) ou une
  variable d'environnement — jamais dans le code, le chat, ou un fichier suivi.
- Ne jamais inventer une valeur secrète.

## Ressources
- Règles projet : `.agents/references/tango-kyc-rules.md`
- Git : skill `tango-git-safety`
