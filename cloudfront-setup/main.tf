terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

variable "aws_region" { type = string }
variable "private_ip" { type = string }
variable "origin_secret" { type = string }
variable "origin_protocol" { type = string }
variable "project_name" { type = string }
variable "github_repo" { type = string }
variable "tag_owner" { type = string }

data "aws_route53_zone" "bittikens" {
  name = "bittikens.com"
}

resource "aws_acm_certificate" "splunk" {
  provider          = aws.us_east_1
  domain_name       = "splunk.bittikens.com"
  validation_method = "DNS"

  tags = {
    Name       = "splunk.bittikens.com"
    Project    = var.project_name
    Repository = var.github_repo
    Owner      = var.tag_owner
    ManagedBy  = "setup-cloudfront-script"
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.splunk.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.bittikens.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "splunk" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.splunk.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_cloudfront_distribution" "splunk" {
  enabled = true
  aliases = ["splunk.bittikens.com"]

  origin {
    domain_name = var.private_ip
    origin_id   = "splunk-hec"

    custom_origin_config {
      http_port              = 8088
      https_port             = 8088
      origin_protocol_policy = var.origin_protocol == "https" ? "https-only" : "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = var.origin_secret
    }
  }

  default_cache_behavior {
    target_origin_id       = "splunk-hec"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]

    forwarded_values {
      query_string = true
      headers      = ["*"]
      cookies {
        forward = "all"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.splunk.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Name       = "ephemeral-splunk-cloudfront"
    Project    = var.project_name
    Repository = var.github_repo
    Owner      = var.tag_owner
    ManagedBy  = "setup-cloudfront-script"
  }
}

resource "aws_route53_record" "splunk" {
  zone_id = data.aws_route53_zone.bittikens.zone_id
  name    = "splunk.bittikens.com"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.splunk.domain_name
    zone_id                = aws_cloudfront_distribution.splunk.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_ssm_parameter" "cloudfront_distribution_id" {
  name  = "/ephemeral-splunk/cloudfront-distribution-id"
  type  = "String"
  value = aws_cloudfront_distribution.splunk.id

  tags = {
    Project    = var.project_name
    Repository = var.github_repo
    Owner      = var.tag_owner
    ManagedBy  = "setup-cloudfront-script"
  }
}

resource "aws_ssm_parameter" "cloudfront_endpoint" {
  name  = "/ephemeral-splunk/cloudfront-endpoint"
  type  = "String"
  value = "https://splunk.bittikens.com"

  tags = {
    Project    = var.project_name
    Repository = var.github_repo
    Owner      = var.tag_owner
    ManagedBy  = "setup-cloudfront-script"
  }
}

output "distribution_id" {
  value = aws_cloudfront_distribution.splunk.id
}

output "distribution_domain" {
  value = aws_cloudfront_distribution.splunk.domain_name
}

output "endpoint_url" {
  value = "https://splunk.bittikens.com"
}
