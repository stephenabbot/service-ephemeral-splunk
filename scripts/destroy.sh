#!/bin/bash
# scripts/destroy.sh - Safely destroy ephemeral Splunk infrastructure

set -euo pipefail

# Change to project root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

# Load environment variables
if [ -f "config.env" ]; then
    set -a
    source config.env
    set +a
fi

# Disable AWS CLI pager
export AWS_PAGER=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "🚨 DESTROY EPHEMERAL SPLUNK INFRASTRUCTURE 🚨"
echo ""
print_warning "This will PERMANENTLY DELETE all Splunk infrastructure!"
echo ""
print_warning "This includes:"
echo "  • EC2 instance and all data"
echo "  • EBS volumes (delete-on-termination enabled)"
echo "  • CloudWatch Log Groups and alarms"
echo "  • SNS topic and subscriptions"
echo "  • All SSM parameters"
echo ""
print_warning "Proceeding with destruction in 3 seconds... (Ctrl+C to cancel)"
sleep 3
echo ""
print_status "Starting destruction..."

# Verify prerequisites
echo ""
echo "Step 1: Verifying prerequisites..."
./scripts/verify-prerequisites.sh || exit 1

# Step 2: Check for project deployment role and assume if available
echo ""
echo "Step 2: Checking for project deployment role..."

# Extract project name from git remote URL
PROJECT_NAME=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/][^/]+/([^/.]+)(\.git)?$|\1|' || echo "")

if [ -z "$PROJECT_NAME" ]; then
  print_warning "Could not determine project name from git remote"
  print_status "Using current credentials"
else
  print_status "Project name: $PROJECT_NAME"

  # Look up project-specific deployment role
  PROJECT_ROLE_ARN=$(aws ssm get-parameter --region us-east-1 --name "/deployment-roles/${PROJECT_NAME}/role-arn" --query Parameter.Value --output text 2>/dev/null || echo "")

  if [ -n "$PROJECT_ROLE_ARN" ]; then
    print_status "Project deployment role found: $PROJECT_ROLE_ARN"

    if TEMP_CREDS=$(aws sts assume-role --role-arn "$PROJECT_ROLE_ARN" --role-session-name "${PROJECT_NAME}-destroy-$(date +%s)" --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>/dev/null); then
      export AWS_ACCESS_KEY_ID=$(echo "$TEMP_CREDS" | cut -f1)
      export AWS_SECRET_ACCESS_KEY=$(echo "$TEMP_CREDS" | cut -f2)
      export AWS_SESSION_TOKEN=$(echo "$TEMP_CREDS" | cut -f3)
      print_success "Successfully assumed project deployment role"
    else
      print_warning "Failed to assume project role, using current credentials"
      print_status "This is normal for local development with admin credentials"
    fi
  else
    print_status "Project deployment role not found at /deployment-roles/${PROJECT_NAME}/role-arn"
    print_status "Using current credentials"
  fi
fi

# Step 3: Configure OpenTofu backend
echo ""
echo "Step 3: Validating S3 installer parameter..."

# Fetch S3 bucket name for Terraform variable
if [ -z "${SPLUNK_S3_INSTALLER_PARAM:-}" ]; then
  print_error "SPLUNK_S3_INSTALLER_PARAM not set in config.env"
  exit 1
fi

S3_INSTALLER_URL=$(aws ssm get-parameter --region us-east-1 --name "$SPLUNK_S3_INSTALLER_PARAM" --query Parameter.Value --output text 2>/dev/null || echo "")

if [ -n "$S3_INSTALLER_URL" ]; then
  # Parse S3 bucket from URL
  if [[ "$S3_INSTALLER_URL" =~ s3://([^/]+)/(.+) ]]; then
    S3_BUCKET="${BASH_REMATCH[1]}"
  elif [[ "$S3_INSTALLER_URL" =~ https://([^.]+)\.s3[^/]*\.amazonaws\.com/(.+) ]]; then
    S3_BUCKET="${BASH_REMATCH[1]}"
  else
    print_warning "Could not parse S3 bucket from URL, using placeholder"
    S3_BUCKET="unknown"
  fi
  print_status "S3 bucket: $S3_BUCKET"
else
  print_warning "Could not fetch S3 installer URL, using placeholder"
  S3_BUCKET="unknown"
fi

# Step 4: Configure OpenTofu backend
echo ""
echo "Step 4: Configuring OpenTofu backend..."

STATE_BUCKET=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/s3-state-bucket" --query Parameter.Value --output text 2>/dev/null || echo "")
DYNAMODB_TABLE=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/dynamodb-lock-table" --query Parameter.Value --output text 2>/dev/null || echo "")

if [ -z "$STATE_BUCKET" ] || [ -z "$DYNAMODB_TABLE" ]; then
  print_error "Foundation backend configuration not found"
  exit 1
fi

GITHUB_REPO=$(git remote get-url origin 2>/dev/null | sed 's/.*github\.com[:/]\([^/]*\/[^/.]*\).*/\1/' || echo "unknown/unknown")
BACKEND_KEY="ephemeral-splunk/$(echo "$GITHUB_REPO" | tr '/' '-')/terraform.tfstate"

print_status "Backend configuration:"
print_status "  Bucket: $STATE_BUCKET"
print_status "  Key: $BACKEND_KEY"

# Step 5: Initialize OpenTofu
echo ""
echo "Step 5: Initializing OpenTofu..."
tofu init -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="dynamodb_table=$DYNAMODB_TABLE" \
    -backend-config="key=$BACKEND_KEY" \
    -backend-config="region=us-east-1"

# Step 5: Plan destruction
echo ""
echo "Step 6: Planning destruction..."
tofu plan -destroy -out=destroy-plan \
    -var="aws_region=${AWS_REGION:-us-east-1}" \
    -var="deployment_environment=${DEPLOYMENT_ENVIRONMENT:-prd}" \
    -var="tag_owner=${TAG_OWNER:-Platform Team}" \
    -var="ec2_instance_type=${EC2_INSTANCE_TYPE:-t3.large}" \
    -var="ebs_volume_size=${EBS_VOLUME_SIZE:-100}" \
    -var="cost_alarm_email=${COST_ALARM_EMAIL:-abbotnh@yahoo.com}" \
    -var="splunk_s3_bucket=$S3_BUCKET"

# Step 6: Apply destruction
echo ""
echo "Step 7: Applying destruction..."
tofu apply destroy-plan

# Step 7b: Clean up orphaned EBS volumes
echo ""
echo "Step 7b: Cleaning up orphaned EBS volumes..."
print_status "Checking for orphaned EBS volumes..."

ORPHANED_VOLUMES=$(aws ec2 describe-volumes \
    --filters "Name=tag:Name,Values=ephemeral-splunk-*" "Name=status,Values=available" \
    --query 'Volumes[].VolumeId' \
    --output text 2>/dev/null || echo "")

if [ -n "$ORPHANED_VOLUMES" ]; then
    print_warning "Found orphaned EBS volumes: $ORPHANED_VOLUMES"
    for volume_id in $ORPHANED_VOLUMES; do
        print_status "Deleting volume: $volume_id"
        aws ec2 delete-volume --volume-id "$volume_id" 2>/dev/null || print_warning "Failed to delete $volume_id"
    done
    print_success "Orphaned volumes cleaned up"
else
    print_success "No orphaned EBS volumes found"
fi

# Step 8: Clean up SSM parameters
echo ""
echo "Step 8: Cleaning up SSM parameters..."

# Delete SSM parameters for this project
SSM_PARAMS=(
    "/ephemeral-splunk/instance-id"
    "/ephemeral-splunk/instance-ip"
    "/ephemeral-splunk/log-group"
    "/ephemeral-splunk/get-splunk-installer"
)

for param in "${SSM_PARAMS[@]}"; do
    aws ssm delete-parameter --region us-east-1 --name "$param" 2>/dev/null || true
done

print_status "SSM parameters cleaned up"

# Step 8: Clean up local files
echo ""
echo "Step 9: Cleaning up local files..."
rm -f tfplan destroy-plan infrastructure-outputs.json

echo ""
print_success "DESTRUCTION COMPLETE"
echo ""
print_warning "All ephemeral Splunk infrastructure has been destroyed"
print_success "Monthly costs are now $0"
echo ""
print_status "To deploy again:"
print_status "  ./scripts/deploy.sh"
echo ""
print_warning "Manual cleanup may be required for:"
print_warning "  • Any data exported before destruction"
print_warning "  • SNS email subscription confirmations (if not confirmed)"
print_warning "  • CloudWatch billing alarm history"
