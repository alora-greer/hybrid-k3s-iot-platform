terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Recommended: remote state. Configure via `terraform init -backend-config=backend.hcl`
  # (backend.hcl is environment-specific; keep it out of git or use *.example).
  # backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "hybrid-k3s-iot-platform"
      ManagedBy = "terraform"
      Component = "aws-backup"
    }
  }
}
