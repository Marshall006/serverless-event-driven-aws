import json

from conftest import published_events, sqs_event
from test_domain import VALID


def upload(aws, key: str, document) -> None:
    body = document if isinstance(document, (bytes, str)) else json.dumps(document)
    aws["s3"].put_object(Bucket="invoices-upload", Key=key, Body=body)


def test_valid_invoice_is_stored_and_published(aws, context):
    upload(aws, "incoming/aaa.json", VALID)
    result = aws["processor"].handler(sqs_event(("incoming/aaa.json", "e1")), context)

    assert result == {"batchItemFailures": []}
    item = aws["processor"].table.get_item(Key={"invoice_id": "aaa"})["Item"]
    assert item["status"] == "ACCEPTED"
    assert str(item["total_incl_tax"]) == "224201.18"
    events = published_events(aws)
    assert [e["detail-type"] for e in events] == ["InvoiceProcessed"]


def test_invalid_invoice_is_rejected_not_retried(aws, context):
    upload(aws, "incoming/bbb.json", {**VALID, "country": "US"})
    result = aws["processor"].handler(sqs_event(("incoming/bbb.json", "e2")), context)

    assert result == {"batchItemFailures": []}  # pas de reprise : erreur métier
    item = aws["processor"].table.get_item(Key={"invoice_id": "bbb"})["Item"]
    assert item["status"] == "REJECTED" and "Pays" in item["reason"]
    assert published_events(aws)[0]["detail-type"] == "InvoiceRejected"


def test_corrupted_file_is_rejected(aws, context):
    upload(aws, "incoming/ccc.json", b"\xff\xfe not json")
    aws["processor"].handler(sqs_event(("incoming/ccc.json", "e3")), context)
    assert aws["processor"].table.get_item(Key={"invoice_id": "ccc"})["Item"]["status"] == "REJECTED"


def test_duplicate_delivery_is_processed_once(aws, context):
    """SQS garantit « au moins une » livraison : l'idempotence évite les doublons."""
    upload(aws, "incoming/ddd.json", VALID)
    event = sqs_event(("incoming/ddd.json", "e4"))
    aws["processor"].handler(event, context)
    aws["processor"].handler(event, context)  # même message livré deux fois
    assert len(published_events(aws)) == 1


def test_partial_batch_failure_only_retries_the_failing_message(aws, context):
    upload(aws, "incoming/eee.json", VALID)
    # Le second objet n'existe pas : erreur technique -> seul ce message est rejoué
    batch = sqs_event(("incoming/eee.json", "e5"), ("incoming/missing.json", "e6"))
    result = aws["processor"].handler(batch, context)
    assert result == {"batchItemFailures": [{"itemIdentifier": "msg-1"}]}
    assert aws["processor"].table.get_item(Key={"invoice_id": "eee"})["Item"]["status"] == "ACCEPTED"
