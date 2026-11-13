# --- Bucket de dépôt des factures ---------------------------------------------
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "uploads" {
  bucket = "${var.name}-uploads-${data.aws_caller_identity.current.account_id}-${var.region}"
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Les factures déposées sont conservées 1 an (les données utiles sont dans DynamoDB)
resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    id     = "expire-uploads"
    status = "Enabled"
    filter {}
    expiration {
      days = 365
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_s3_bucket_policy" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.uploads.arn, "${aws_s3_bucket.uploads.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.uploads]
}

# Chaque dépôt de fichier émet un événement EventBridge
resource "aws_s3_bucket_notification" "uploads" {
  bucket      = aws_s3_bucket.uploads.id
  eventbridge = true
}

# --- Tables DynamoDB (paiement à la requête : 0 $ sans trafic) ----------------
resource "aws_dynamodb_table" "invoices" {
  name                        = "${var.name}-${var.environment}"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "invoice_id"
  deletion_protection_enabled = var.environment == "prod"

  attribute {
    name = "invoice_id"
    type = "S"
  }
  attribute {
    name = "status"
    type = "S"
  }

  # Index secondaire : lister les factures par statut (ex. REVIEW_REQUIRED)
  global_secondary_index {
    name            = "by-status"
    projection_type = "ALL"
    key_schema {
      attribute_name = "status"
      key_type       = "HASH"
    }
  }

  point_in_time_recovery {
    enabled = true # restauration à la seconde près sur 35 jours
  }
  server_side_encryption {
    enabled = true
  }
}

# Mémoire de l'idempotence : « ce fichier a-t-il déjà été traité ? »
resource "aws_dynamodb_table" "idempotency" {
  name         = "${var.name}-${var.environment}-idempotency"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
  ttl {
    attribute_name = "expiration" # nettoyage automatique après 7 jours
    enabled        = true
  }
  point_in_time_recovery {
    enabled = true
  }
  server_side_encryption {
    enabled = true
  }
}
