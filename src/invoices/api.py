"""Lambda « api » (API Gateway HTTP API) :

POST /uploads              -> URL présignée pour déposer une facture (5 min)
GET  /invoices/{id}        -> résultat du traitement d'une facture
GET  /invoices?status=...  -> factures par statut (index secondaire)
"""

from __future__ import annotations

import os
import uuid

import boto3
from aws_lambda_powertools import Logger, Tracer
from aws_lambda_powertools.event_handler import APIGatewayHttpResolver
from aws_lambda_powertools.event_handler.exceptions import BadRequestError, NotFoundError
from boto3.dynamodb.conditions import Key

logger = Logger()
tracer = Tracer()
app = APIGatewayHttpResolver()

s3 = boto3.client("s3")
table = boto3.resource("dynamodb").Table(os.environ["INVOICES_TABLE"])
BUCKET = os.environ["UPLOAD_BUCKET"]
STATUSES = {"ACCEPTED", "REVIEW_REQUIRED", "REJECTED"}


@app.post("/uploads")
@tracer.capture_method
def create_upload() -> dict:
    invoice_id = str(uuid.uuid4())
    url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": BUCKET, "Key": f"incoming/{invoice_id}.json", "ContentType": "application/json"},
        ExpiresIn=300,
    )
    return {"invoice_id": invoice_id, "upload_url": url, "expires_in": 300, "method": "PUT"}


@app.get("/invoices/<invoice_id>")
@tracer.capture_method
def get_invoice(invoice_id: str) -> dict:
    try:
        uuid.UUID(invoice_id)
    except ValueError as exc:
        raise BadRequestError("Identifiant invalide") from exc
    item = table.get_item(Key={"invoice_id": invoice_id}).get("Item")
    if not item:
        raise NotFoundError("Facture inconnue ou en cours de traitement")
    return item


@app.get("/invoices")
@tracer.capture_method
def list_invoices() -> dict:
    status = (app.current_event.get_query_string_value("status") or "").upper()
    if status not in STATUSES:
        raise BadRequestError(f"status doit valoir : {', '.join(sorted(STATUSES))}")
    result = table.query(IndexName="by-status", KeyConditionExpression=Key("status").eq(status), Limit=50)
    return {"status": status, "count": len(result["Items"]), "items": result["Items"]}


@logger.inject_lambda_context(clear_state=True)
@tracer.capture_lambda_handler
def handler(event: dict, context) -> dict:
    return app.resolve(event, context)
