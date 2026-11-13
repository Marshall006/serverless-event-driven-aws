# Revue AWS Well-Architected

Revue de l'architecture selon les **6 piliers** du AWS Well-Architected
Framework.

| Pilier | Ce qui est en place | Pistes d'amélioration |
|---|---|---|
| **Excellence opérationnelle** | Infrastructure 100 % Terraform ; CI (tests, lint, sécurité) ; logs JSON structurés, traces X-Ray, métriques métier (Powertools) ; tableau de bord CloudWatch ; ADR | Runbooks de rejeu de la DLQ ; déploiement progressif (alias Lambda + CodeDeploy) |
| **Sécurité** | Un rôle IAM par fonction, moindre privilège testé ; API authentifiée (IAM) par défaut ; S3 privé + TLS obligatoire ; chiffrement partout ; URLs présignées de 5 minutes, limitées au préfixe `incoming/` ; déploiement par OIDC | Authentification JWT (Cognito) pour des utilisateurs finaux ; AWS WAF devant l'API ; signature de code Lambda |
| **Fiabilité** | File SQS tampon ; 3 tentatives puis DLQ (14 jours) ; échecs partiels par lot ; idempotence ; PITR DynamoDB ; 5 alarmes (DLQ, retard, erreurs, limitations, 5xx) | Rejeu automatisé de la DLQ ; multi-régions si l'activité l'exige |
| **Efficacité des performances** | Traitement par lots de 10 ; HTTP API (plus rapide que REST API) ; paquet Lambda réduit à 6,6 Mo (démarrage à froid plus rapide) | Ajuster la mémoire Lambda avec AWS Lambda Power Tuning |
| **Optimisation des coûts** | 100 % paiement à l'usage (0 $ sans trafic) ; arm64 (~20 % moins cher) ; aucun VPC ni NAT ; rétention des logs à 14 jours ; cycle de vie S3 ; limitation de débit de l'API | Infracost dans la CI ; budgets (voir projet 5) |
| **Durabilité** | Serverless (aucune ressource inactive), Graviton, expiration automatique des données inutiles | Archivage des factures en classe de stockage froide |

## Estimation de coût (ordre de grandeur)

Pour **10 000 factures par mois**, chaque service reste dans la tranche du
dollar ou en dessous : ~10 000 invocations Lambda courtes, ~30 000 messages
SQS, ~40 000 écritures DynamoDB, ~20 000 événements EventBridge personnalisés,
quelques Go de logs. Le poste principal est généralement **CloudWatch Logs**.

À vérifier avec l'[AWS Pricing Calculator](https://calculator.aws/) ou
Infracost pour la région et les volumes réels : les tarifs varient selon la
région et évoluent.
