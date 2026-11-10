variable "aws_region" {
  description = "AWS region for the backup bucket."
  type        = string
}

variable "bucket_name" {
  description = "Globally unique S3 bucket name for off-site backups."
  type        = string
}

variable "backup_prefixes" {
  description = "Map of backup writer name => S3 key prefix. One least-privilege IAM user is created per entry."
  type        = map(string)
  default = {
    k3s            = "k3s/"
    home-assistant = "home-assistant/"
  }

  validation {
    condition     = alltrue([for p in values(var.backup_prefixes) : endswith(p, "/")])
    error_message = "Every prefix must end with a trailing slash."
  }
}

variable "transition_to_glacier_days" {
  description = "Days before current objects move to Glacier Instant Retrieval."
  type        = number
  default     = 30
}

variable "noncurrent_version_expiration_days" {
  description = "Days to keep superseded (noncurrent) object versions."
  type        = number
  default     = 90
}

variable "expiration_days" {
  description = "Days before current backup objects expire. 0 disables expiration."
  type        = number
  default     = 365
}
