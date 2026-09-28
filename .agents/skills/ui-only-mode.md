---
paths:
- mobile/lib/ui/**
---
# Mode UI ONLY

Cette tâche touche l'interface Flutter (`mobile/lib/ui/**`). Appliquer le mode UI ONLY.

AUTORISÉ : widgets, styles, animations, assets, responsive, navigation **visuelle**.
INTERDIT sans demande explicite : Supabase, Firebase, Auth, paiement, Edge Functions, emails,
backend, base de données.

Le paiement MVola reste **manuel** : ne jamais ajouter d'API/webhook MVola ni d'auto-approval.

Ne pas modifier `main.dart`, l'authentification ou les services pour un changement purement visuel.
Vérifier : `cd mobile && flutter analyze && flutter test`.
Rapport final au format `.agents/references/tango-kyc-rules.md` (section 7).
