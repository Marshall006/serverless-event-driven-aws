#!/usr/bin/env bash
# Démonstration de bout en bout sur un compte AWS (après `make deploy`).
# Prérequis : awscurl (pip install awscurl) car l'API exige une signature IAM.
set -euo pipefail
cd "$(dirname "$0")/../infra"
API=$(terraform output -raw api_url)
call() { awscurl --service execute-api --region eu-west-3 "$@"; }

for file in invoice-valid invoice-review; do
  echo "==> Dépôt de $file"
  upload=$(call -X POST "$API/uploads")
  id=$(jq -r .invoice_id <<<"$upload")
  curl -sf -X PUT -H "Content-Type: application/json" \
    --data-binary @"../events/$file.json" "$(jq -r .upload_url <<<"$upload")"
  echo "    facture $id déposée, traitement asynchrone…"
  for _ in $(seq 1 20); do
    if result=$(call "$API/invoices/$id" 2>/dev/null) && jq -e .status <<<"$result" >/dev/null; then
      jq '{status, reasons, total_excl_tax, vat_amount, total_incl_tax}' <<<"$result"; break
    fi
    sleep 2
  done
done
echo "==> Factures à vérifier :"
call "$API/invoices?status=REVIEW_REQUIRED" | jq '.count'
