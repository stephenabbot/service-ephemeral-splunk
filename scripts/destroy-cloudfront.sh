#!/bin/bash
# scripts/destroy-cloudfront.sh - Destroy CloudFront distribution

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

echo "🗑️  DESTROYING CLOUDFRONT DISTRIBUTION 🗑️"
echo ""

if [ ! -d "$PROJECT_ROOT/cloudfront-setup" ]; then
    print_warning "CloudFront setup directory not found. Nothing to destroy."
    exit 0
fi

cd "$PROJECT_ROOT/cloudfront-setup"

# Get backend config
STATE_BUCKET=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/s3-state-bucket" --query Parameter.Value --output text 2>/dev/null || echo "")
DYNAMODB_TABLE=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/dynamodb-lock-table" --query Parameter.Value --output text 2>/dev/null || echo "")
GITHUB_REPO=$(git remote get-url origin 2>/dev/null | sed 's/.*github\.com[:/]\([^/]*\/[^/.]*\).*/\1/' || echo "unknown/unknown")
BACKEND_KEY="ephemeral-splunk-cloudfront/$(echo "$GITHUB_REPO" | tr '/' '-')/terraform.tfstate"

if [ -z "$STATE_BUCKET" ] || [ -z "$DYNAMODB_TABLE" ]; then
    print_error "Cannot retrieve backend configuration"
    exit 1
fi

print_status "Initializing Terraform..."
tofu init -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="dynamodb_table=$DYNAMODB_TABLE" \
    -backend-config="key=$BACKEND_KEY" \
    -backend-config="region=us-east-1"

# Get variables from Parameter Store
PRIVATE_IP=$(aws ec2 describe-instances --instance-ids "$(aws ssm get-parameter --name /ephemeral-splunk/instance-id --query Parameter.Value --output text)" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>/dev/null || echo "127.0.0.1")
PROJECT_NAME=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/][^/]+/([^/.]+)(\.git)?$|\1|' || echo "ephemeral-splunk")

print_status "Planning destruction..."
tofu plan -destroy -out=destroy-plan \
    -var="aws_region=${AWS_REGION:-us-east-1}" \
    -var="private_ip=$PRIVATE_IP" \
    -var="origin_protocol=http" \
    -var="project_name=$PROJECT_NAME" \
    -var="github_repo=$GITHUB_REPO" \
    -var="tag_owner=${TAG_OWNER:-Platform Team}"

print_status "Applying destruction..."

# Run destroy
tofu apply destroy-plan || {
    EXIT_CODE=$?
    print_error "Destroy failed with exit code $EXIT_CODE"
    exit 1
}

# Clean up local files
cd "$PROJECT_ROOT"
rm -rf cloudfront-setup

print_success "CloudFront distribution destroyed successfully"
