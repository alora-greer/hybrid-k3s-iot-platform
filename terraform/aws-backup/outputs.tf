output "bucket_name" {
  description = "Backup bucket name."
  value       = aws_s3_bucket.backups.bucket
}

output "bucket_region" {
  description = "Backup bucket region."
  value       = var.aws_region
}

output "kms_key_arn" {
  description = "KMS key used for SSE-KMS on the backup bucket."
  value       = aws_kms_key.backups.arn
}

output "writer_users" {
  description = "IAM user name per backup source. Create access keys out-of-band."
  value       = { for k, u in aws_iam_user.writer : k => u.name }
}
