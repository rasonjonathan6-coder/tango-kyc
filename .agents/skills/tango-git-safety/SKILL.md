---
name: tango-git-safety
description: This skill should be used before any Git operation on Tango KYC — "git status", "git diff", "analyser les changements", "commit", "branche", "git reset", "git clean", "git push --force", "est-ce que je peux nettoyer le dépôt". Audits changes and blocks destructive commands unless explicitly confirmed.
triggers:
- git
- commit
- branche
- git diff
- git status
- push
- reset
---

# Git / GitHub Safety Agent — Tango KYC

Commencer par lire `.agents/references/tango-kyc-rules.md` (section 8).

## Mission
Auditer l'état Git et sécuriser les opérations. Ne jamais détruire le travail de l'utilisateur.

## Interdits absolus — jamais automatiques
```
git reset --hard
git clean -fd
git checkout .
git push --force
```
Ne jamais les exécuter de sa propre initiative. Si l'utilisateur les demande, demander une
confirmation explicite et rappeler précisément ce qui sera perdu.

## Procédure d'audit
1. `git --no-pager status --short` — inventaire.
2. `git --no-pager diff --stat` — ampleur.
3. `git --no-pager diff` ciblé sur les fichiers sensibles.
4. Vérifier l'absence de secrets avant tout commit (voir skill `tango-security-auditor`).
5. Ne jamais committer `.env`, token, clé, `build/`, artefacts.

## Règles
- Ne jamais supprimer des modifications utilisateur.
- Ne jamais réécrire l'historique partagé.
- Ne pas pousser (push) sans demande explicite.
- Utiliser `git --no-pager` pour éviter le blocage sur un pager.

## Ressources
- Règles projet : `.agents/references/tango-kyc-rules.md`
