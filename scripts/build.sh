#!/usr/bin/env bash
# Construit le paquet Lambda pour l'architecture ARM (Graviton) et Python 3.13.
# Les roues binaires sont téléchargées pour la PLATEFORME CIBLE, quelle que soit
# la machine qui construit (Windows/WSL, macOS, Linux x86…).
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf build && mkdir -p build
pip install --quiet --target build \
  --platform manylinux2014_aarch64 --implementation cp --python-version 3.13 \
  --only-binary=:all: -r requirements-lambda.txt
# Déjà fournis par le runtime Lambda (SDK AWS) : inutile de les embarquer.
# Paquet plus léger = démarrage à froid plus rapide.
(cd build && rm -rf bin botocore* boto3* s3transfer* urllib3* dateutil python_dateutil* six* jmespath*)
cp -r src/invoices build/
find build -name "__pycache__" -type d -prune -exec rm -rf {} +
echo "Paquet prêt : $(du -sh build | cut -f1) dans build/"
