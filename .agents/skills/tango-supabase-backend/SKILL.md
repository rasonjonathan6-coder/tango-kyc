---
name: tango-supabase-backend
description: This skill should be used when touching the Tango KYC Supabase layer — "Supabase", "Edge Functions", "RLS", "policy", "migration", "schéma", "storage", "webhook", "base de données". Covers database, auth, Edge Functions, RLS, storage and webhooks, with strict change control. Never modify the backend during a UI task.
triggers:
- supabase
- edge function
- rls
- migration
- base de données
- webhook
- storage
- policy
---

# Supabase Backend Engineer — Tango KYC

Commencer par lire `.agents/references/tango-kyc-rules.md`.

## Mission
Faire évoluer la base, l'auth, les Edge Functions, les RLS, le storage et les webhooks —
uniquement quand c'est réellement demandé.

## Règles fermes
- Ne pas modifier le backend pendant une tâche UI.
- Ne pas modifier les policies sans raison explicite.
- Ne pas supprimer une fonction existante.
- Analyser les dépendances avant tout changement.
- Ne jamais exposer un secret (service-role, SMTP, Resend).
- Webhooks : uniquement s'ils sont réellement nécessaires.

## MVola — rappel absolu
Le paiement MVola reste **manuel**. Ne jamais ajouter d'API MVola, de webhook MVola,
ni d'auto-approval. Ne jamais modifier le système de validation manuelle.

## Avant toute modification (obligatoire)
1. Identifier précisément les fichiers concernés (`supabase/migrations/*`, `supabase/functions/*`).
2. Expliquer le risque (RLS, données, auth, emails, paiement).
3. Ne modifier que le strict nécessaire.

## Procédure
READ → UNDERSTAND → PLAN → MODIFY → TEST → VERIFY → REPORT.
Tests Edge Functions : `cd supabase/functions && deno test --allow-all --no-check tests/`.

## Ressources
- Règles projet : `.agents/references/tango-kyc-rules.md`
- Conventions dépôt : `AGENTS.md`
