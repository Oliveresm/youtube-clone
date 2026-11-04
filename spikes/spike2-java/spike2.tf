terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "me" {}

# Bucket raw (privado)
resource "aws_s3_bucket" "raw" {
  bucket        = "spike2-raw-upload-${data.aws_caller_identity.me.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "raw" {
  bucket                  = aws_s3_bucket.raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CORS cerrado: solo POST desde el origen de la pagina de prueba
resource "aws_s3_bucket_cors_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id
  cors_rule {
    allowed_methods = ["POST"]
    allowed_origins = ["http://localhost:3000"]
    allowed_headers = ["*"]
    max_age_seconds = 300
  }
}

# Rol que simula el task role de ECS: s3:PutObject SOLO sobre raw/*
resource "aws_iam_role" "uploader" {
  name = "spike2-uploader"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.me.account_id}:root" }
    }]
  })
}

resource "aws_iam_role_policy" "uploader" {
  name = "put-raw-only"
  role = aws_iam_role.uploader.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "s3:PutObject"
      Resource = "${aws_s3_bucket.raw.arn}/raw/*"
    }]
  })
}

output "bucket_name" {
  value = aws_s3_bucket.raw.id
}

output "role_arn" {
  value = aws_iam_role.uploader.arn
}
