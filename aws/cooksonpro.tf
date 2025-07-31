

data "aws_route53_zone" "cookson_pro" {
  name         = var.hosted_zone_domain
  private_zone = false
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "origin_cors_s3" {
  name = "Managed-CORS-S3Origin"
}

data "aws_cloudfront_origin_request_policy" "origin_all_viewer_except_host_header" {
  name = "Managed-AllViewerExceptHostHeader"
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

# Route 53 Alias Record for CloudFront Distribution
resource "aws_route53_record" "cloudfront_alias" {
  zone_id = data.aws_route53_zone.cookson_pro.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.s3_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.s3_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

# Note: You will need to add the DNS CNAME records provided by aws_acm_certificate.cookson_pro.domain_validation_options
# to your DNS provider to validate the certificate. If using Route 53, this can be automated.

# S3 Bucket for website content
data "aws_s3_bucket" "site_bucket" {
  bucket = var.content_s3_bucket_name
}

# The following configuration allows objects to be public-read even if the bucket is private
# This is achieved by setting object_ownership to ObjectWriter and enabling public ACLs on objects.
# The bucket itself remains private due to the public access block.
# This is necessary for CloudFront to serve content from the S3 bucket when using OAI.
# See: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls
# and https://docs.aws.amazon.com/AmazonS3/latest/userguide/about-object-ownership.html

resource "aws_s3_bucket_acl" "site_bucket_acl" {
  bucket = data.aws_s3_bucket.site_bucket.id
  acl    = "private" # Ensure the bucket itself remains private

}

module "template_files" {
  source = "hashicorp/dir/template"

  base_dir = "./static"
  template_vars = {
  }
}

resource "aws_s3_object" "all_static" {
  for_each     = module.template_files.files
  bucket       = var.content_s3_bucket_name
  key          = each.key
  content_type = each.value.content_type
  source       = each.value.source_path
  content      = each.value.content

  cache_control = "public, max-age=1200"
  etag          = each.value.digests.md5
  acl           = "public-read"
}

# Block all public access to the S3 bucket
resource "aws_s3_bucket_public_access_block" "site_bucket_public_access_block" {
  bucket = data.aws_s3_bucket.site_bucket.id

  block_public_acls       = false
  block_public_policy     = true
  ignore_public_acls      = false
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "example" {
  bucket = data.aws_s3_bucket.site_bucket.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# CloudFront Origin Access Identity (OAI) to access the S3 bucket
resource "aws_cloudfront_origin_access_identity" "oai" {
  comment = "OAI for ${var.content_s3_bucket_name}"
}

# S3 Bucket Policy to allow CloudFront OAI to read objects
data "aws_iam_policy_document" "s3_bucket_policy_doc" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${data.aws_s3_bucket.site_bucket.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.oai.iam_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "bucket_policy" {
  bucket = data.aws_s3_bucket.site_bucket.id
  policy = data.aws_iam_policy_document.s3_bucket_policy_doc.json
}

resource "aws_s3_bucket" "www_cookson_pro_loudfront_logs" {
  bucket = var.log_bucket_name

  tags = {
    Name        = "www.cookson.pro-cloudfront-logs"
    Environment = "production"
  }
}

resource "aws_s3_bucket_acl" "www_cookson_pro_loudfront_logs" {
  bucket     = aws_s3_bucket.www_cookson_pro_loudfront_logs.id
  acl        = "private"
  depends_on = [aws_s3_bucket_ownership_controls.www_cookson_pro_loudfront_logs]
}

# Resource to avoid error "AccessControlListNotSupported: The bucket does not allow ACLs"
resource "aws_s3_bucket_ownership_controls" "www_cookson_pro_loudfront_logs" {
  bucket = aws_s3_bucket.www_cookson_pro_loudfront_logs.id
  rule {
    object_ownership = "ObjectWriter"
  }
}

# CloudFront Distribution
resource "aws_cloudfront_distribution" "s3_distribution" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "CloudFront distribution for ${var.domain_name}"
  default_root_object = "index.html" # Common default object for static sites

  aliases = [var.domain_name]

  logging_config {
    bucket          = "${var.log_bucket_name}.s3.amazonaws.com"
    prefix          = "cloudfront/${var.domain_name}/"
    include_cookies = false
  }

  custom_error_response {
    error_code         = 404
    response_code      = 404
    response_page_path = "/404.html"
  }

  custom_error_response {
    error_code         = 403
    response_code      = 403
    response_page_path = "/404.html"
  }

  # Origin for S3 static content
  origin {
    domain_name = data.aws_s3_bucket.site_bucket.bucket_regional_domain_name
    origin_id   = "S3-${var.content_s3_bucket_name}"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.oai.cloudfront_access_identity_path
    }
  }

  # Origin for API requests
  origin {
    domain_name = "${aws_api_gateway_rest_api.api.id}.execute-api.us-east-1.amazonaws.com"
    origin_id   = "API-origin"
    origin_path = "/prod"

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
    cache_policy_id = data.aws_cloudfront_cache_policy.caching_optimized.id

    # If your S3 content requires CORS handling where S3 itself needs to see the Origin header,
    # you might need an Origin Request Policy like "Managed-CORS-S3Origin".
    # origin_request_policy_id = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf" # Managed-CORS-S3Origin
  }

  # Ordered cache behavior for API requests (/api*)
  ordered_cache_behavior {
    path_pattern     = "/api*"
    target_origin_id = "API-origin"

    allowed_methods = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods  = ["GET", "HEAD", "OPTIONS"] # Cache GET, HEAD, OPTIONS if API supports it

    viewer_protocol_policy = "redirect-to-https" # Redirect HTTP to HTTPS
    compress               = true                # Enable compression if API responses are compressible

    # Use a managed cache policy that disables caching.
    # API responses are often dynamic and should not be cached by CloudFront,
    # or caching should be controlled by origin cache headers (Cache-Control, Expires).
    cache_policy_id = data.aws_cloudfront_cache_policy.caching_disabled.id

    # Use a managed origin request policy that forwards all viewer headers (except Host),
    # all cookies, and all query strings to the API origin.
    # CloudFront will set the Host header to the origin domain name (api.cookson.pro).
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.origin_all_viewer_except_host_header.id
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
  value       = data.aws_s3_bucket.site_bucket.bucket
}

output "acm_certificate_validation_dns_records" {
  description = "DNS CNAME records needed to validate the ACM certificate. Add these to your DNS provider."
  value       = { for o in aws_acm_certificate.cookson_pro.domain_validation_options : o.domain_name => { name = o.resource_record_name, type = o.resource_record_type, value = o.resource_record_value } }
}
