# ADR 0001 — S3 → EventBridge → SQS → Lambda plutôt que S3 → Lambda direct

- **Statut** : accepté
- **Date** : 2026-11

## Contexte

Chaque facture déposée dans S3 doit être traitée. La solution la plus courte
consiste à déclencher la Lambda directement depuis S3.

## Décision

Chaîne **S3 → EventBridge → SQS → Lambda**.

## Justification

| Critère | S3 → Lambda | S3 → EventBridge → SQS → Lambda |
|---|---|---|
| Pic de dépôts (1 000 factures d'un coup) | 1 000 Lambdas simultanées : risque de limitation et de saturation de DynamoDB | La file **absorbe** le pic ; concurrence plafonnée à 10 |
| Échec de traitement | 2 reprises asynchrones, puis perte ou destination | 3 tentatives puis **DLQ** conservée 14 jours, rejouable |
| Ajout d'un nouveau consommateur (archivage, IA…) | Modifier la notification S3 | Ajouter une **règle EventBridge**, sans toucher à l'existant |
| Filtrage (préfixe `incoming/`) | Oui | Oui, et filtrage riche (contenu de l'événement) |
| Traitement par lots | Non | Oui (10 messages, échecs partiels) |

## Conséquences

- Latence ajoutée de quelques secondes (fenêtre de lot de 5 s) : acceptable
  pour un traitement comptable.
- Coût : EventBridge facture les événements personnalisés publiés ; les
  événements des services AWS sur le bus par défaut ne le sont pas.
- Livraison « au moins une fois » : impose l'idempotence (ADR 0003).
