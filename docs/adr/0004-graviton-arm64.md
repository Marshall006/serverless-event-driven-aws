# ADR 0004 — Lambda sur processeurs ARM (Graviton)

- **Statut** : accepté

## Décision

Toutes les fonctions utilisent l'architecture `arm64`.

## Justification

- Prix de la durée d'exécution inférieur d'environ 20 % à x86 sur Lambda, à
  performance comparable pour du Python.
- Moindre consommation d'énergie (pilier « durabilité » du Well-Architected
  Framework).

## Conséquences

- Les dépendances binaires doivent être compilées pour ARM : le script
  `scripts/build.sh` télécharge les roues `manylinux2014_aarch64`, quelle que
  soit la machine qui construit.
- La CI vérifie l'import du paquet dans l'image Lambda officielle arm64.
