terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}


provider "aws" {
  region = "us-east-1" # ACM certificates for CloudFront must be in us-east-1
}

data "aws_route53_zone" "cookson_pro" {
  name         = var.domain_name
  private_zone = false
}

# ACM Certificate for the CloudFront distribution
resource "aws_acm_certificate" "cookson_pro" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  tags = {
    Name        = "${var.domain_name}-cloudfront-cert"
    Environment = "production"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "cookson_pro" {
  certificate_arn         = aws_acm_certificate.cookson_pro.arn
  validation_record_fqdns = [for record in aws_route53_record.cookson_pro : record.fqdn]
}

resource "aws_route53_record" "cookson_pro" {
  for_each = {
    for dvo in aws_acm_certificate.cookson_pro.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.cookson_pro.zone_id
}

# Note: You will need to add the DNS CNAME records provided by aws_acm_certificate.cookson_pro.domain_validation_options
# to your DNS provider to validate the certificate. If using Route 53, this can be automated.

# S3 Bucket for website content
resource "aws_s3_bucket" "site_bucket" {
  bucket = var.content_s3_bucket_name
  # ACLs are not recommended for new buckets. Use bucket policies and IAM.
  # acl    = "private" # This is the default and recommended

  tags = {
    Name        = "${var.content_s3_bucket_name}-static-site"
    Environment = "production"
  }
}

# Block all public access to the S3 bucket
resource "aws_s3_bucket_public_access_block" "site_bucket_public_access_block" {
  bucket = aws_s3_bucket.site_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudFront Origin Access Identity (OAI) to access the S3 bucket
resource "aws_cloudfront_origin_access_identity" "oai" {
  comment = "OAI for ${var.content_s3_bucket_name}"
}

# S3 Bucket Policy to allow CloudFront OAI to read objects
data "aws_iam_policy_document" "s3_bucket_policy_doc" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site_bucket.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.oai.iam_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "bucket_policy" {
  bucket = aws_s3_bucket.site_bucket.id
  policy = data.aws_iam_policy_document.s3_bucket_policy_doc.json
}

# CloudFront Distribution
resource "aws_cloudfront_distribution" "s3_distribution" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CloudFront distribution for ${var.domain_name}"
  default_root_object = "index.html" # Common default object for static sites

  aliases = [var.domain_name]

  # Origin for S3 static content
  origin {
    domain_name = aws_s3_bucket.site_bucket.bucket_regional_domain_name
    origin_id   = "S3-${var.content_s3_bucket_name}"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.oai.cloudfront_access_identity_path
    }
  }

  # Origin for API requests
  origin {
    domain_name = var.api_origin_domain
    origin_id   = "API-${var.api_origin_domain}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only" # Enforce HTTPS to the API origin
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Default cache behavior (serves S3 content)
  default_cache_behavior {
    target_origin_id = "S3-${var.content_s3_bucket_name}"

    allowed_methods = ["GET", "HEAD", "OPTIONS"] # OPTIONS might be needed for CORS on S3 assets
    cached_methods  = ["GET", "HEAD"]

    viewer_protocol_policy = "redirect-to-https" # Redirect HTTP to HTTPS
    compress               = true                # Enable compression for S3 assets

    # Use a managed cache policy optimized for S3 static content.
    # This policy includes: no query strings, no headers, no cookies in cache key.
    # Gzip and Brotli compression enabled.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed-CachingOptimized

    # If your S3 content requires CORS handling where S3 itself needs to see the Origin header,
    # you might need an Origin Request Policy like "Managed-CORS-S3Origin".
    # origin_request_policy_id = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf" # Managed-CORS-S3Origin
  }

  # Ordered cache behavior for API requests (/api*)
  ordered_cache_behavior {
    path_pattern     = "/api*"
    target_origin_id = "API-${var.api_origin_domain}"

    allowed_methods = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods  = ["GET", "HEAD", "OPTIONS"] # Cache GET, HEAD, OPTIONS if API supports it

    viewer_protocol_policy = "redirect-to-https" # Redirect HTTP to HTTPS
    compress               = true                # Enable compression if API responses are compressible

    # Use a managed cache policy that disables caching.
    # API responses are often dynamic and should not be cached by CloudFront,
    # or caching should be controlled by origin cache headers (Cache-Control, Expires).
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a8493f392" # Managed-CachingDisabled

    # Use a managed origin request policy that forwards all viewer headers (except Host),
    # all cookies, and all query strings to the API origin.
    # CloudFront will set the Host header to the origin domain name (api.cookson.pro).
    origin_request_policy_id = "b6878925-4c69-4116-9397-33261f75c195" # Managed-AllViewerExceptHostHeader
  }

  # Viewer certificate configuration
  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.cookson_pro.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021" # Use a modern TLS security policy
  }

  # Restrictions (no geo-restrictions by default)
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Price class (PriceClass_All for best performance, PriceClass_100 for US/EU focus)
  price_class = "PriceClass_All"

  # Enable HTTP/2 for improved performance
  http_version = "http2"

  # Optional: Enable logging
  # logging_config {
  #   include_cookies = false
  #   bucket          = "your-cloudfront-logs-s3-bucket-name.s3.amazonaws.com"
  #   prefix          = "cloudfront-logs/${var.domain_name}/"
  # }

  tags = {
    Name        = "cloudfront-${var.domain_name}"
    Environment = "production"
  }

  # Wait for the certificate to be validated before creating the distribution
  depends_on = [aws_acm_certificate.cookson_pro]
}

# Outputs
output "cloudfront_distribution_id" {
  description = "The ID of the CloudFront distribution."
  value       = aws_cloudfront_distribution.s3_distribution.id
}

output "cloudfront_distribution_domain_name" {
  description = "The domain name of the CloudFront distribution."
  value       = aws_cloudfront_distribution.s3_distribution.domain_name
}

output "acm_certificate_arn" {
  description = "The ARN of the ACM certificate."
  value       = aws_acm_certificate.cookson_pro.arn
}

output "acm_validation_records" {
  value = aws_acm_certificate.cookson_pro.domain_validation_options
}

output "s3_bucket_name_output" {
  description = "The name of the S3 bucket created for static content."
  value       = aws_s3_bucket.site_bucket.bucket
}

output "acm_certificate_validation_dns_records" {
  description = "DNS CNAME records needed to validate the ACM certificate. Add these to your DNS provider."
  value       = { for o in aws_acm_certificate.cookson_pro.domain_validation_options : o.domain_name => { name = o.resource_record_name, type = o.resource_record_type, value = o.resource_record_value } }
}
