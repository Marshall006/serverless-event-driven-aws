"""Lambda « processor » : SQS -> validation -> DynamoDB -> événement métier.

Déclenchement : la file SQS reçoit les événements « Object Created » de S3
(via EventBridge). Chaque message = une facture déposée.

Garanties :
  - IDEMPOTENCE : SQS peut livrer un message deux fois ; une même facture
    (même objet S3, même version) n'est traitée qu'une fois (Powertools).
  - ÉCHECS PARTIELS : dans un lot de 10 messages, seuls ceux en échec sont
    renvoyés dans la file (ReportBatchItemFailures) ; après 3 essais, ils
    partent dans la file des messages en échec (DLQ) et une alarme sonne.
  - Une facture INVALIDE n'est pas une erreur technique : elle est
    enregistrée comme REJECTED et un événement est publié (pas de reprise).
"""

from __future__ import annotations

import json
import os
from datetime import UTC, datetime
from decimal import Decimal

import boto3
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.batch import BatchProcessor, EventType, process_partial_response
from aws_lambda_powertools.utilities.data_classes.sqs_event import SQSRecord
from aws_lambda_powertools.utilities.idempotency import (
    DynamoDBPersistenceLayer,
    IdempotencyConfig,
    idempotent_function,
)

from invoices.domain import InvalidInvoice, parse_invoice, review

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="InvoicePipeline")
processor = BatchProcessor(event_type=EventType.SQS)

s3 = boto3.client("s3")
events = boto3.client("events")
table = boto3.resource("dynamodb").Table(os.environ["INVOICES_TABLE"])
EVENT_BUS = os.environ["EVENT_BUS_NAME"]
APPROVED_SUPPLIERS = set(filter(None, os.environ.get("APPROVED_SUPPLIERS", "").split(",")))
REVIEW_THRESHOLD = Decimal(os.environ.get("REVIEW_THRESHOLD", "5000000"))

idempotency = DynamoDBPersistenceLayer(table_name=os.environ["IDEMPOTENCY_TABLE"])
idempotency_config = IdempotencyConfig(
    event_key_jmespath='["bucket", "key", "etag"]',  # même fichier = même traitement
    expires_after_seconds=7 * 24 * 3600,
)


def _publish(detail_type: str, detail: dict) -> None:
    events.put_events(
        Entries=[
            {
                "EventBusName": EVENT_BUS,
                "Source": "invoices.processor",
                "DetailType": detail_type,
                "Detail": json.dumps(detail, default=str),
            }
        ]
    )


@idempotent_function(data_keyword_argument="obj", config=idempotency_config, persistence_store=idempotency)
@tracer.capture_method
def process_object(obj: dict) -> dict:
    invoice_id = obj["key"].rsplit("/", 1)[-1].removesuffix(".json")
    body = s3.get_object(Bucket=obj["bucket"], Key=obj["key"])["Body"].read()
    now = datetime.now(UTC).isoformat(timespec="seconds")
    try:
        invoice = parse_invoice(json.loads(body))
    except (InvalidInvoice, json.JSONDecodeError, UnicodeDecodeError) as exc:
        item = {
            "invoice_id": invoice_id,
            "status": "REJECTED",
            "reason": str(exc),
            "s3_key": obj["key"],
            "processed_at": now,
        }
        table.put_item(Item=item)
        _publish("InvoiceRejected", item)
        metrics.add_metric(name="InvoicesRejected", unit=MetricUnit.Count, value=1)
        logger.warning("Facture rejetée", extra={"invoice_id": invoice_id, "reason": str(exc)})
        return item

    decision = review(invoice, APPROVED_SUPPLIERS, REVIEW_THRESHOLD)
    item = {
        "invoice_id": invoice_id,
        "status": decision.status,
        "reasons": decision.reasons,
        "number": invoice.number,
        "supplier": invoice.supplier,
        "country": invoice.country,
        "currency": invoice.currency,
        "lines": len(invoice.lines),
        "total_excl_tax": invoice.total_excl_tax,
        "vat_amount": invoice.vat_amount,
        "total_incl_tax": invoice.total_incl_tax,
        "s3_key": obj["key"],
        "processed_at": now,
    }
    table.put_item(Item=item)
    _publish("InvoiceProcessed", item)
    metrics.add_metric(name=f"Invoices{decision.status.title().replace('_', '')}", unit=MetricUnit.Count, value=1)
    logger.info("Facture traitée", extra={"invoice_id": invoice_id, "status": decision.status})
    return {"invoice_id": invoice_id, "status": decision.status}


def record_handler(record: SQSRecord) -> dict:
    # Le message SQS contient l'événement EventBridge « Object Created » de S3
    detail = json.loads(record.body)["detail"]
    obj = {
        "bucket": detail["bucket"]["name"],
        "key": detail["object"]["key"],
        "etag": detail["object"].get("etag", ""),
    }
    return process_object(obj=obj)


@logger.inject_lambda_context(clear_state=True)
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, context) -> dict:
    idempotency_config.register_lambda_context(context)
    return process_partial_response(event=event, record_handler=record_handler, processor=processor, context=context)
