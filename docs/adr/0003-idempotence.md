# ADR 0003 — Idempotence du traitement

- **Statut** : accepté

## Contexte

SQS garantit qu'un message est livré **au moins une fois**, pas exactement
une fois. Une facture peut donc être traitée deux fois, avec à la clé deux
événements « InvoiceProcessed » et un risque de double paiement en aval.

## Décision

Rendre le traitement **idempotent** avec AWS Lambda Powertools : la clé est
le triplet `(bucket, clé de l'objet, etag)`. Le résultat est mémorisé
7 jours dans une table DynamoDB dédiée (expiration automatique par TTL).

## Conséquences

- Une seconde livraison renvoie le résultat mémorisé, sans effet de bord
  (test `test_duplicate_delivery_is_processed_once`).
- Un **nouveau** dépôt du même fichier modifié (etag différent) est bien
  retraité.
- Coût : une lecture et une écriture DynamoDB supplémentaires par facture.
