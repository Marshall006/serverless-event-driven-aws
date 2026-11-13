import json


def http_event(method: str, path: str, query: dict | None = None, path_params: dict | None = None) -> dict:
    return {
        "version": "2.0",
        "routeKey": f"{method} {path}",
        "rawPath": path,
        "rawQueryString": "&".join(f"{k}={v}" for k, v in (query or {}).items()),
        "queryStringParameters": query,
        "pathParameters": path_params,
        "headers": {"content-type": "application/json"},
        "requestContext": {"http": {"method": method, "path": path, "sourceIp": "1.2.3.4"}, "stage": "$default"},
        "isBase64Encoded": False,
    }


def call(aws, context, *args, **kwargs) -> tuple[int, dict]:
    response = aws["api"].handler(http_event(*args, **kwargs), context)
    return response["statusCode"], json.loads(response["body"])


def test_create_upload_returns_presigned_url(aws, context):
    status, body = call(aws, context, "POST", "/uploads")
    assert status == 200
    assert body["upload_url"].startswith("https://")
    assert f"incoming/{body['invoice_id']}.json" in body["upload_url"]
    assert body["expires_in"] == 300


def test_get_invoice(aws, context):
    aws["api"].table.put_item(Item={"invoice_id": "3f2a1c9e-1111-4222-8333-444455556666", "status": "ACCEPTED"})
    status, body = call(aws, context, "GET", "/invoices/3f2a1c9e-1111-4222-8333-444455556666")
    assert status == 200 and body["status"] == "ACCEPTED"


def test_unknown_or_invalid_invoice(aws, context):
    assert call(aws, context, "GET", "/invoices/3f2a1c9e-1111-4222-8333-000000000000")[0] == 404
    assert call(aws, context, "GET", "/invoices/not-a-uuid")[0] == 400


def test_list_by_status(aws, context):
    for i, status in enumerate(["ACCEPTED", "REJECTED", "ACCEPTED"]):
        aws["api"].table.put_item(Item={"invoice_id": f"id-{i}", "status": status})
    status, body = call(aws, context, "GET", "/invoices", query={"status": "accepted"})
    assert status == 200 and body["count"] == 2
    assert call(aws, context, "GET", "/invoices", query={"status": "foo"})[0] == 400
