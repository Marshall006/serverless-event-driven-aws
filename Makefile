.PHONY: install test lint build tf-test tf-validate security deploy demo destroy

install:   ## Environnement de développement
	python3 -m venv .venv && .venv/bin/pip install -e ".[dev]"

test:      ## Tests unitaires et d'intégration (AWS simulé par moto)
	.venv/bin/pytest -v

lint:
	.venv/bin/ruff check . && .venv/bin/ruff format --check .

build:     ## Paquet Lambda (arm64, Python 3.13)
	./scripts/build.sh

tf-test:   ## Tests d'architecture Terraform (AWS simulé)
	cd infra && terraform init -backend=false && terraform test

tf-validate:
	cd infra && terraform init -backend=false && terraform validate

security:  ## Checkov
	checkov -d infra --config-file .checkov.yaml

deploy: build  ## Déploie sur ton compte AWS
	cd infra && terraform init -backend-config=backend.hcl && terraform apply

demo:      ## Dépose deux factures et affiche le résultat
	./scripts/demo.sh

destroy:   ## Supprime tout (à faire après chaque démonstration)
	cd infra && terraform destroy
