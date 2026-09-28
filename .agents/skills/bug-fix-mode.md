---
paths:
- mobile/lib/**
- supabase/**
---
# Mode BUG FIX

Un bug est signalé. NE PAS modifier immédiatement. Suivre exactement :

1. REPRODUIRE — écrire/étendre un test qui échoue pour la bonne raison.
2. LOCALISER — isoler le fichier et la fonction responsables.
3. IDENTIFIER LA CAUSE — expliquer le mécanisme réel, pas une hypothèse.
4. PROPOSER LE CORRECTIF — décrire la modification minimale.
5. MODIFIER — appliquer ce correctif.
6. TESTER — `cd mobile && flutter analyze && flutter test`.
7. VÉRIFIER LES RÉGRESSIONS — le nombre de tests ne doit pas baisser.

Rapport :
```
BUG
CAUSE
CORRECTION
TEST
RÉSULTAT
```
