#!/bin/bash
# scripts/setup-cloudfront.sh - Setup CloudFront distribution for Splunk HEC

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

if [ -f "config.env" ]; then
    set -a
    source config.env
    set +a
fi

export AWS_PAGER=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "🌐 SETTING UP CLOUDFRONT FOR SPLUNK HEC 🌐"
echo ""

# Check if already deployed
print_status "Checking if CloudFront distribution already exists..."
EXISTING_DISTRO=$(aws ssm get-parameter --name /ephemeral-splunk/cloudfront-distribution-id --query Parameter.Value --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_DISTRO" ] && [ "$EXISTING_DISTRO" != "null" ]; then
    print_error "CloudFront distribution already exists: $EXISTING_DISTRO"
    print_error "Script has already been run. Exiting."
    exit 1
fi

# Get instance ID
print_status "Retrieving instance ID..."
INSTANCE_ID=$(aws ssm get-parameter --name /ephemeral-splunk/instance-id --query Parameter.Value --output text 2>/dev/null || echo "")

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "null" ]; then
    print_error "Instance ID not found. Deploy the stack first."
    exit 1
fi

print_status "Instance ID: $INSTANCE_ID"

# Get private IP and public DNS/IP
print_status "Getting instance network information..."
INSTANCE_INFO=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].[PrivateIpAddress,PublicIpAddress,PublicDnsName]' --output text)
PRIVATE_IP=$(echo "$INSTANCE_INFO" | cut -f1)
PUBLIC_IP=$(echo "$INSTANCE_INFO" | cut -f2)
PUBLIC_DNS=$(echo "$INSTANCE_INFO" | cut -f3)

# Use public DNS if available, otherwise public IP
if [ -n "$PUBLIC_DNS" ] && [ "$PUBLIC_DNS" != "None" ]; then
    ORIGIN_DOMAIN="$PUBLIC_DNS"
    print_status "Using public DNS: $PUBLIC_DNS"
elif [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "None" ]; then
    ORIGIN_DOMAIN="$PUBLIC_IP"
    print_status "Using public IP: $PUBLIC_IP"
else
    print_error "No public IP or DNS available"
    exit 1
fi

# Enable HEC and create token via SSM
print_status "Enabling Splunk HEC..."
COMMAND_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=[
"sudo -u splunk /opt/splunk/bin/splunk http-event-collector enable -uri https://localhost:8089 -auth admin:changeme",
"sudo -u splunk /opt/splunk/bin/splunk http-event-collector create firehose-token -uri https://localhost:8089 -auth admin:changeme -description \"Firehose ingestion token\" -disabled 0 -index main -indexes main -use-ack 1 | grep token= | cut -d= -f2"
]' \
    --query 'Command.CommandId' \
    --output text)

sleep 10

HEC_TOKEN=$(aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query 'StandardOutputContent' \
    --output text | grep -v "^$" | tail -1)

if [ -z "$HEC_TOKEN" ]; then
    print_error "Failed to create HEC token"
    exit 1
fi

print_success "HEC token created with indexer acknowledgment enabled"

# Store HEC token
aws ssm put-parameter --name /ephemeral-splunk/hec-token --value "$HEC_TOKEN" --type SecureString --overwrite
print_success "HEC token stored in Parameter Store"

# Test HEC protocol
print_status "Testing HEC protocol..."
PROTOCOL_TEST=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=[
"curl -s -o /dev/null -w \"%{http_code}\" http://localhost:8088/services/collector/health",
"curl -k -s -o /dev/null -w \"%{http_code}\" https://localhost:8088/services/collector/health"
]' \
    --query 'Command.CommandId' \
    --output text)

sleep 5

PROTOCOL_RESULT=$(aws ssm get-command-invocation \
    --command-id "$PROTOCOL_TEST" \
    --instance-id "$INSTANCE_ID" \
    --query 'StandardOutputContent' \
    --output text)

HTTP_CODE=$(echo "$PROTOCOL_RESULT" | grep -o '[0-9]\{3\}' | head -1)
HTTPS_CODE=$(echo "$PROTOCOL_RESULT" | grep -o '[0-9]\{3\}' | tail -1)

if [ "$HTTP_CODE" = "200" ]; then
    ORIGIN_PROTOCOL="http"
    print_success "HEC responds on HTTP"
elif [ "$HTTPS_CODE" = "200" ]; then
    ORIGIN_PROTOCOL="https"
    print_success "HEC responds on HTTPS"
else
    print_error "HEC not responding on either protocol (HTTP: $HTTP_CODE, HTTPS: $HTTPS_CODE)"
    exit 1
fi

# Generate origin secret
ORIGIN_SECRET=$(openssl rand -hex 32)
aws ssm put-parameter --name /ephemeral-splunk/origin-secret --value "$ORIGIN_SECRET" --type SecureString --overwrite
print_success "Origin secret generated and stored"

# Get git info for tags
PROJECT_NAME=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/][^/]+/([^/.]+)(\.git)?$|\1|' || echo "ephemeral-splunk")
GITHUB_REPO=$(git remote get-url origin 2>/dev/null | sed 's/.*github\.com[:/]\([^/]*\/[^/.]*\).*/\1/' || echo "unknown/unknown")

# Create Terraform configuration for CloudFront
mkdir -p "$PROJECT_ROOT/cloudfront-setup"

cat > "$PROJECT_ROOT/cloudfront-setup/main.tf" << 'EOF'
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
EOF

# Get backend config
STATE_BUCKET=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/s3-state-bucket" --query Parameter.Value --output text)
DYNAMODB_TABLE=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/dynamodb-lock-table" --query Parameter.Value --output text)
BACKEND_KEY="ephemeral-splunk-cloudfront/$(echo "$GITHUB_REPO" | tr '/' '-')/terraform.tfstate"

print_status "Initializing Terraform..."
cd "$PROJECT_ROOT/cloudfront-setup"

tofu init -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="dynamodb_table=$DYNAMODB_TABLE" \
    -backend-config="key=$BACKEND_KEY" \
    -backend-config="region=us-east-1"

print_status "Planning CloudFront deployment..."
tofu plan -out=cfplan \
    -var="aws_region=${AWS_REGION:-us-east-1}" \
    -var="private_ip=$ORIGIN_DOMAIN" \
    -var="origin_secret=$ORIGIN_SECRET" \
    -var="origin_protocol=$ORIGIN_PROTOCOL" \
    -var="project_name=$PROJECT_NAME" \
    -var="github_repo=$GITHUB_REPO" \
    -var="tag_owner=${TAG_OWNER:-Platform Team}"

print_status "Applying CloudFront deployment..."
tofu apply cfplan

print_status "Waiting for CloudFront distribution to become available..."
DISTRIBUTION_ID=$(tofu output -raw distribution_id)

while true; do
    STATUS=$(aws cloudfront get-distribution --id "$DISTRIBUTION_ID" --query 'Distribution.Status' --output text)
    if [ "$STATUS" = "Deployed" ]; then
        print_success "CloudFront distribution is deployed"
        break
    fi
    print_status "Status: $STATUS - waiting 15 seconds..."
    sleep 15
done

ENDPOINT_URL=$(tofu output -raw endpoint_url)

echo ""
print_success "CLOUDFRONT SETUP COMPLETE"
echo ""
echo "📋 Configuration:"
echo "  • CloudFront Distribution: $DISTRIBUTION_ID"
echo "  • Endpoint URL: $ENDPOINT_URL"
echo "  • HEC Token: (stored in /ephemeral-splunk/hec-token)"
echo "  • Origin Secret: (stored in /ephemeral-splunk/origin-secret)"
echo ""
echo "🔥 Firehose Configuration:"
echo "  • Endpoint: $ENDPOINT_URL/services/collector"
echo "  • Custom Header: X-Origin-Verify: $ORIGIN_SECRET"
echo "  • Authentication Token: (retrieve from Parameter Store)"
echo ""
