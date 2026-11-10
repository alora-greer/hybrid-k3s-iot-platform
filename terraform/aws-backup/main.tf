data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# Encryption: customer-managed KMS key with automatic rotation
# -----------------------------------------------------------------------------
resource "aws_kms_key" "backups" {
  description             = "Encrypts hybrid-k3s-iot-platform off-site backups"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "backups" {
  name          = "alias/${var.bucket_name}"
  target_key_id = aws_kms_key.backups.key_id
}

# -----------------------------------------------------------------------------
# Bucket: private, versioned, SSE-KMS, TLS-only
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "backups" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_ownership_controls" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.backups.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "tiering-and-retention"
    status = "Enabled"
    filter {}

    transition {
      days          = var.transition_to_glacier_days
      storage_class = "GLACIER_IR"
    }

    dynamic "expiration" {
      for_each = var.expiration_days > 0 ? [1] : []
      content {
        days = var.expiration_days
      }
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.backups]
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.backups.arn, "${aws_s3_bucket.backups.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "backups" {
  bucket = aws_s3_bucket.backups.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.backups]
}

# -----------------------------------------------------------------------------
# Least-privilege writers: one IAM user per backup source, scoped to its prefix.
# s3:DeleteObject is allowed so K3s / Home Assistant can prune old snapshots,
# but on a versioned bucket that only adds a delete marker. Writers get no
# s3:DeleteObjectVersion and no bucket-config permissions, so a leaked key
# cannot destroy history for noncurrent_version_expiration_days.
#
# Access keys are intentionally NOT created here so secrets never land in
# Terraform state. Create them out-of-band:
#   aws iam create-access-key --user-name <user>
# -----------------------------------------------------------------------------
resource "aws_iam_user" "writer" {
  for_each = var.backup_prefixes
  name     = "${var.bucket_name}-${each.key}-writer"
  path     = "/backup/"
}

data "aws_iam_policy_document" "writer" {
  for_each = var.backup_prefixes

  statement {
    sid       = "ListOwnPrefix"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${each.value}*"]
    }
  }

  statement {
    sid       = "BucketLocation"
    actions   = ["s3:GetBucketLocation"]
    resources = [aws_s3_bucket.backups.arn]
  }

  statement {
    sid = "ReadWriteOwnPrefix"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.backups.arn}/${each.value}*"]
  }

  statement {
    sid       = "UseBackupKmsKey"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.backups.arn]
  }
}

resource "aws_iam_user_policy" "writer" {
  for_each = var.backup_prefixes
  name     = "backup-writer-${each.key}"
  user     = aws_iam_user.writer[each.key].name
  policy   = data.aws_iam_policy_document.writer[each.key].json
}
