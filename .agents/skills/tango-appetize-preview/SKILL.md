---
name: tango-appetize-preview
description: This skill should be used when preparing or running a visual device preview of a Tango KYC APK — "tester l'APK visuellement", "Appetize", "préparer une preview", "inspecter l'APK", "vérifier le package de l'APK", "vérifier l'intégrité de l'APK", "le lancement échoue". Uses the standalone toolkit at /workspace/appetize-preview and the APPETIZE_API_TOKEN environment variable, never exposing secrets.
triggers:
- appetize
- preview
- apk visuel
- device qa
- inspecter apk
---

# Appetize Preview / Device QA — Tango KYC

Commencer par lire `.agents/references/tango-kyc-rules.md`.

## Mission
Préparer une preview visuelle d'un APK dans un navigateur, inspecter un APK existant,
vérifier le package, l'intégrité et le lancement.

## Toolkit (standalone, hors dépôt Git)
Emplacement : `/workspace/appetize-preview`

| Script | Rôle |
|---|---|
| `preflight.sh` | vérification read-only (outils, projet, APK, API) |
| `inspect_apk.sh [apk]` | identité de l'APK (appId, taille, sha256) |
| `upload.sh [apk] [--update ID]` | upload / remplacement d'une build |
| `status.sh [--app ID \| BUILD_ID]` | liste / détail d'une build |
| `lib.sh` | helpers partagés (sourcés uniquement) |

## Authentification
- Variable unique : `APPETIZE_API_TOKEN` (ou `.env` local gitignoré dans le toolkit).
- En-tête : `X-API-KEY`. Base : `https://api.appetize.io`.
- Endpoints : `POST /v2/builds`, `PATCH /v2/builds/{buildId}`, `GET /v2/builds`.

## Règles de sécurité
- Ne jamais afficher l'API token, un secret ou des credentials. Seule une empreinte SHA-256 tronquée est tolérable.
- Ne jamais demander à l'utilisateur de coller le token dans le chat : le placer dans `.env` (gitignoré) ou une variable d'environnement.
- Si le token manque : statut **BLOCKED**. Ne jamais inventer un résultat, un build id ou une URL.

## Procédure
1. `./preflight.sh` → confirmer la disponibilité.
2. `./inspect_apk.sh <apk>` → appId, taille, sha256, intégrité.
3. `./upload.sh <apk>` → récupérer le `Build ID` réel et les URLs.
4. Ouvrir l'App URL et parcourir le flux.

## Attention
Un APK en cache peut être **antérieur** aux modifications récentes : le signaler explicitement.
Sans JDK/SDK Android complet dans cet environnement, aucun APK ne peut être construit ici.

## Ressources
- Règles projet : `.agents/references/tango-kyc-rules.md`
