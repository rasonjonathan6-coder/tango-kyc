# Tango KYC — règles canoniques

Fichier de référence partagé, chargé à la demande par les skills et les micro-agents.
Source de vérité courte ; le détail vit dans `docs/` et `AGENTS.md`.

## 1. Nature du projet

Tango KYC (`/workspace/project`) traite les demandes de re-vérification / support de compte.

- `mobile/` — client Flutter Android, package `com.tango.kyc.tango_kyc_verification`.
- `supabase/` — migrations, RLS, Edge Functions.
- Stack : Flutter/Dart, Android, Supabase, Firebase (Auth, Google Sign-In, FCM), emails, tickets, MVola **manuel**.

## 2. Règle absolue — MVola manuel

NE JAMAIS, sans demande explicite :

- ajouter une API MVola ;
- ajouter un webhook MVola ;
- créer un auto-approval ;
- modifier le système de validation manuelle existant.

## 3. Sécurité

- Aucun secret dans le code. Aucun mot de passe, token ou clé dans Git.
- Ne jamais afficher une clé API, même partiellement. N'afficher que `PRESENT` / `ABSENT` / `RISK` / `SAFE`.
- Ne jamais demander à l'utilisateur de coller un secret dans le chat ; le faire passer par une variable d'environnement ou un fichier `.env` local déjà gitignoré.
- Ne jamais inventer une valeur secrète.
- Avant toute modification backend / auth / paiement : identifier les fichiers concernés, expliquer le risque, ne modifier que le strict nécessaire.

## 4. Mode « UI ONLY » (défaut quand l'utilisateur dit « modifie l'interface »)

AUTORISÉ : Flutter UI, widgets, styles, animations, assets, responsive, navigation **visuelle**.
INTERDIT sans demande : Supabase, Firebase, Auth, paiement, Edge Functions, emails, backend, base de données.

## 5. Principes visuels

Premium, moderne, 2026, élégant, fluide. Palette : violet, magenta, cyan, bleu très sombre ;
gradients soignés, profondeur, glow subtil, animations légères. Lisibilité d'abord.

- Ne jamais recréer un élément déjà présent dans une image de fond (silhouette, décor, lumière).
- Utiliser les assets existants ; préserver leurs proportions ; ne pas déformer.
- Vrai `SafeArea` ; jamais de faux bandeau de statut.

## 6. Workflow de tâche (immuable)

READ → UNDERSTAND → PLAN → MODIFY → TEST → VERIFY → REPORT.
Ne jamais enchaîner READ → MODIFY directement.

## 7. Rapport final obligatoire

## DONE
## FILES CHANGED
## TESTS        (flutter analyze / flutter test / autres)
## VISUAL       (PASS / FAIL / NOT TESTED / BLOCKED)
## SECURITY     (PASS / FAIL / NOT TESTED / BLOCKED)
## BUILD        (PASS / FAIL / NOT TESTED / BLOCKED)
## NOT DONE
## BLOCKERS     (uniquement les vrais blocages)

Statuts autorisés : `PASS`, `FAIL`, `NOT TESTED`, `BLOCKED`.
Ne jamais écrire `PASS` sans exécution réelle. Ne jamais masquer un test non effectué.

## 8. Git — interdits absolus (jamais automatiques)

`git reset --hard`, `git clean -fd`, `git checkout .`, `git push --force`.
Ne jamais supprimer les modifications de l'utilisateur. Confirmation explicite avant toute opération destructive.

## 9. Commandes de référence

```bash
cd mobile && flutter analyze && flutter test
cd supabase/functions && deno test --allow-all --no-check tests/
```
