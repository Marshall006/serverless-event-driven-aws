# ADR 0002 — DynamoDB (à la demande) plutôt qu'une base relationnelle

- **Statut** : accepté

## Contexte

Il faut stocker le résultat du traitement de chaque facture et le consulter
par identifiant ou par statut.

## Décision

**DynamoDB en mode « paiement à la requête »**, avec un index secondaire
`by-status`.

## Justification

- **Coût nul sans trafic** : une base RDS coûte au minimum une instance qui
  tourne 24 h/24 (plusieurs dizaines de dollars par mois).
- Accès simples et connus d'avance (par clé, par statut) : le modèle clé-valeur
  suffit, sans jointure.
- Aucune gestion de serveur, de correctifs ni de connexions (une Lambda qui
  monte en charge peut épuiser les connexions d'une base relationnelle).
- Sauvegarde continue (PITR, 35 jours) et chiffrement natifs.

## Conséquences

- Les requêtes analytiques (totaux par fournisseur et par mois) ne sont pas
  adaptées à DynamoDB : pour ce besoin, exporter vers S3 et interroger avec
  Athena, ou alimenter un entrepôt de données.
- L'index par statut peut devenir une « partition chaude » à très fort volume
  (quelques statuts seulement) : acceptable au volume visé.
