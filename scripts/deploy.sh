#!/bin/bash
# scripts/deploy.sh - Deploy ephemeral Splunk infrastructure

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

echo "🚀 DEPLOYING EPHEMERAL SPLUNK INFRASTRUCTURE 🚀"
echo ""
echo "This will deploy a fresh Splunk Enterprise instance with monitoring and cost controls"
echo ""

# Verify prerequisites
echo "Step 1: Verifying prerequisites..."
./scripts/verify-prerequisites.sh || exit 1

# Step 2: Validate S3 installer availability
echo ""
echo "Step 2: Validating S3-hosted Splunk installer..."

if [ -z "${SPLUNK_S3_INSTALLER_PARAM:-}" ]; then
  echo "❌ SPLUNK_S3_INSTALLER_PARAM not set in config.env"
  exit 1
fi

echo "  Fetching installer URL from Parameter Store: $SPLUNK_S3_INSTALLER_PARAM"
S3_INSTALLER_URL=$(aws ssm get-parameter --region us-east-1 --name "$SPLUNK_S3_INSTALLER_PARAM" --query Parameter.Value --output text 2>/dev/null || echo "")

if [ -z "$S3_INSTALLER_URL" ]; then
  echo "❌ Parameter $SPLUNK_S3_INSTALLER_PARAM not found in Parameter Store"
  echo "  Deploy the splunk-s3-installer project first: https://github.com/stephenabbot/splunk-s3-installer"
  exit 1
fi

echo "✓ Installer URL: $S3_INSTALLER_URL"

# Parse S3 bucket and key from URL
if [[ "$S3_INSTALLER_URL" =~ s3://([^/]+)/(.+) ]]; then
  S3_BUCKET="${BASH_REMATCH[1]}"
  S3_KEY="${BASH_REMATCH[2]}"
elif [[ "$S3_INSTALLER_URL" =~ https://([^.]+)\.s3[^/]*\.amazonaws\.com/(.+) ]]; then
  S3_BUCKET="${BASH_REMATCH[1]}"
  S3_KEY="${BASH_REMATCH[2]}"
else
  echo "❌ Invalid S3 URL format: $S3_INSTALLER_URL"
  echo "  Expected: s3://bucket/key or https://bucket.s3.region.amazonaws.com/key"
  exit 1
fi

echo "  Bucket: $S3_BUCKET"
echo "  Key: $S3_KEY"

# Verify S3 object exists and is accessible
echo "  Verifying S3 object accessibility..."
if ! aws s3api head-object --bucket "$S3_BUCKET" --key "$S3_KEY" --region us-east-1 >/dev/null 2>&1; then
  echo "❌ Cannot access S3 object: s3://$S3_BUCKET/$S3_KEY"
  echo "  Verify the installer exists and you have permissions"
  exit 1
fi

echo "✓ S3 installer validated and accessible"

# Export for Terraform
export TF_VAR_splunk_s3_bucket="$S3_BUCKET"

# Step 3: Check for project deployment role and assume if available
echo ""
echo "Step 3: Checking for project deployment role..."

# Extract project name from git remote URL
PROJECT_NAME=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/][^/]+/([^/.]+)(\.git)?$|\1|' || echo "")

if [ -z "$PROJECT_NAME" ]; then
  echo "⚠️  Could not determine project name from git remote"
  echo "  Using current credentials"
else
  echo "  Project name: $PROJECT_NAME"

  # Look up project-specific deployment role
  PROJECT_ROLE_ARN=$(aws ssm get-parameter --region us-east-1 --name "/deployment-roles/${PROJECT_NAME}/role-arn" --query Parameter.Value --output text 2>/dev/null || echo "")

  if [ -n "$PROJECT_ROLE_ARN" ]; then
    echo "✓ Project deployment role found: $PROJECT_ROLE_ARN"
    echo "  Attempting to assume role for deployment..."

    if TEMP_CREDS=$(aws sts assume-role --role-arn "$PROJECT_ROLE_ARN" --role-session-name "${PROJECT_NAME}-deploy-$(date +%s)" --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>/dev/null); then
      export AWS_ACCESS_KEY_ID=$(echo "$TEMP_CREDS" | cut -f1)
      export AWS_SECRET_ACCESS_KEY=$(echo "$TEMP_CREDS" | cut -f2)
      export AWS_SESSION_TOKEN=$(echo "$TEMP_CREDS" | cut -f3)
      echo "✓ Successfully assumed project deployment role"
    else
      echo "⚠️  Failed to assume project role, using current credentials"
      echo "  This is normal for local development with admin credentials"
    fi
  else
    echo "ℹ️  Project deployment role not found at /deployment-roles/${PROJECT_NAME}/role-arn"
    echo "  Using current credentials"
    echo "  To create a deployment role, run terraform-aws-deployment-roles"
  fi
fi

# Step 4: Configure OpenTofu backend
echo ""
echo "Step 4: Configuring OpenTofu backend..."

# Get backend configuration from foundation
STATE_BUCKET=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/s3-state-bucket" --query Parameter.Value --output text 2>/dev/null || echo "")
DYNAMODB_TABLE=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/dynamodb-lock-table" --query Parameter.Value --output text 2>/dev/null || echo "")

if [ -z "$STATE_BUCKET" ] || [ -z "$DYNAMODB_TABLE" ]; then
  echo "❌ Foundation backend configuration not found"
  echo "  Deploy terraform-aws-cfn-foundation first"
  exit 1
fi

# Get GitHub repository info for state key
GITHUB_REPO=$(git remote get-url origin 2>/dev/null | sed 's/.*github\.com[:/]\([^/]*\/[^/.]*\).*/\1/' || echo "unknown/unknown")
BACKEND_KEY="ephemeral-splunk/$(echo "$GITHUB_REPO" | tr '/' '-')/terraform.tfstate"

echo "✓ Backend configuration:"
echo "  Bucket: $STATE_BUCKET"
echo "  DynamoDB: $DYNAMODB_TABLE"
echo "  Key: $BACKEND_KEY"

# Step 5: Initialize OpenTofu
echo ""
echo "Step 5: Initializing OpenTofu..."

tofu init -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="dynamodb_table=$DYNAMODB_TABLE" \
    -backend-config="key=$BACKEND_KEY" \
    -backend-config="region=us-east-1"

# Step 6: Plan deployment
echo ""
echo "Step 6: Planning deployment..."
tofu plan -out=tfplan \
    -var="aws_region=${AWS_REGION:-us-east-1}" \
    -var="deployment_environment=${DEPLOYMENT_ENVIRONMENT:-prd}" \
    -var="tag_owner=${TAG_OWNER:-Platform Team}" \
    -var="ec2_instance_type=${EC2_INSTANCE_TYPE:-t3.large}" \
    -var="ebs_volume_size=${EBS_VOLUME_SIZE:-100}" \
    -var="cost_alarm_email=${COST_ALARM_EMAIL:-abbotnh@yahoo.com}" \
    -var="splunk_s3_bucket=$S3_BUCKET"

# Step 7: Apply deployment
echo ""
echo "Step 7: Applying deployment..."
tofu apply tfplan

# Step 8: Generate outputs and store in SSM
echo ""
echo "Step 8: Generating outputs and storing in SSM..."

# Generate outputs JSON (this will be gitignored)
tofu output -json > infrastructure-outputs.json

# Store outputs in SSM for consuming projects
if [ -f infrastructure-outputs.json ]; then
  INSTANCE_ID=$(jq -r '.instance_info.value.instance_id' infrastructure-outputs.json)
  INSTANCE_IP=$(jq -r '.instance_info.value.instance_ip' infrastructure-outputs.json)
  LOG_GROUP=$(jq -r '.instance_info.value.log_group_name' infrastructure-outputs.json)
  
  echo "Storing SSM parameters for ephemeral-splunk..."
  
  aws ssm put-parameter --region us-east-1 --name "/ephemeral-splunk/instance-id" --value "$INSTANCE_ID" --type String --overwrite > /dev/null
  aws ssm put-parameter --region us-east-1 --name "/ephemeral-splunk/instance-ip" --value "$INSTANCE_IP" --type String --overwrite > /dev/null
  aws ssm put-parameter --region us-east-1 --name "/ephemeral-splunk/log-group" --value "$LOG_GROUP" --type String --overwrite > /dev/null
fi

echo ""
echo "✅ DEPLOYMENT COMPLETE"
echo ""
echo "📋 Summary:"
echo "  • Ephemeral Splunk infrastructure deployed successfully"
echo "  • Instance ID: $(jq -r '.instance_info.value.instance_id' infrastructure-outputs.json)"
echo "  • Public IP: $(jq -r '.instance_info.value.instance_ip' infrastructure-outputs.json)"
echo "  • CloudWatch Logs: $(jq -r '.instance_info.value.log_group_name' infrastructure-outputs.json)"
echo ""
echo "🔍 Next steps:"
echo "  1. Wait 5-10 minutes for Splunk installation to complete"
echo "  2. Check installation status: ./scripts/verify-installation.sh"
echo ""
echo "🌐 To access Splunk web interface:"
echo "  1. Run this command in your terminal:"
echo "     $(jq -r '.connection_info.value.port_forward_command' infrastructure-outputs.json)"
echo ""
echo "  2. Open your browser to: http://localhost:8000"
echo ""
echo "  3. Login with username: admin  password: changeme"
echo ""
echo "💰 Cost monitoring:"
echo "  • Cost alarms configured for \$5, \$10, \$20"
echo "  • Email notifications sent to: ${COST_ALARM_EMAIL:-abbotnh@yahoo.com}"
echo ""
echo "🚀 Ephemeral Splunk is ready for use! 🚀"
