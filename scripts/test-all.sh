#!/bin/bash
# Test script to verify all project functionality without actual deployment

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_test() { echo -e "${BLUE}[TEST]${NC} $1"; }
print_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
print_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
print_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

export AWS_PAGER=""

TESTS_PASSED=0
TESTS_FAILED=0

echo "🧪 TESTING EPHEMERAL SPLUNK PROJECT 🧪"
echo ""

# Test 1: Verify .env file has required parameters
print_test "Checking .env configuration..."
if [ -f ".env" ]; then
    source .env
    if [ -n "${SPLUNK_S3_INSTALLER_PARAM:-}" ]; then
        print_pass ".env has SPLUNK_S3_INSTALLER_PARAM: $SPLUNK_S3_INSTALLER_PARAM"
        ((TESTS_PASSED++))
    else
        print_fail "SPLUNK_S3_INSTALLER_PARAM not found in .env"
        ((TESTS_FAILED++))
    fi
else
    print_fail ".env file not found"
    ((TESTS_FAILED++))
fi

# Test 2: Check Parameter Store for installer URL
print_test "Checking Parameter Store for installer URL..."
START_TIME=$(date +%s)
S3_URL=$(aws ssm get-parameter --region us-east-1 --name "${SPLUNK_S3_INSTALLER_PARAM}" --query Parameter.Value --output text 2>/dev/null || echo "")
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [ -n "$S3_URL" ]; then
    print_pass "Parameter Store check (${DURATION}s): $S3_URL"
    ((TESTS_PASSED++))
else
    print_fail "Parameter ${SPLUNK_S3_INSTALLER_PARAM} not found in Parameter Store"
    print_info "Deploy splunk-s3-installer first: https://github.com/stephenabbot/splunk-s3-installer"
    ((TESTS_FAILED++))
    S3_URL=""
fi

# Test 3: Parse S3 bucket and key
if [ -n "$S3_URL" ]; then
    print_test "Parsing S3 URL..."
    if [[ "$S3_URL" =~ s3://([^/]+)/(.+) ]]; then
        S3_BUCKET="${BASH_REMATCH[1]}"
        S3_KEY="${BASH_REMATCH[2]}"
        print_pass "Parsed bucket: $S3_BUCKET, key: $S3_KEY"
        ((TESTS_PASSED++))
    elif [[ "$S3_URL" =~ https://([^.]+)\.s3[^/]*\.amazonaws\.com/(.+) ]]; then
        S3_BUCKET="${BASH_REMATCH[1]}"
        S3_KEY="${BASH_REMATCH[2]}"
        print_pass "Parsed bucket: $S3_BUCKET, key: $S3_KEY"
        ((TESTS_PASSED++))
    else
        print_fail "Invalid S3 URL format: $S3_URL"
        ((TESTS_FAILED++))
        S3_BUCKET=""
        S3_KEY=""
    fi
fi

# Test 4: Verify S3 object exists
if [ -n "${S3_BUCKET:-}" ] && [ -n "${S3_KEY:-}" ]; then
    print_test "Verifying S3 object accessibility..."
    START_TIME=$(date +%s)
    if aws s3api head-object --bucket "$S3_BUCKET" --key "$S3_KEY" --region us-east-1 >/dev/null 2>&1; then
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        SIZE=$(aws s3api head-object --bucket "$S3_BUCKET" --key "$S3_KEY" --region us-east-1 --query ContentLength --output text)
        SIZE_MB=$((SIZE / 1024 / 1024))
        print_pass "S3 object accessible (${DURATION}s): ${SIZE_MB}MB"
        ((TESTS_PASSED++))
    else
        print_fail "Cannot access S3 object: s3://$S3_BUCKET/$S3_KEY"
        ((TESTS_FAILED++))
    fi
fi

# Test 5: Check Terraform/OpenTofu installation
print_test "Checking Terraform/OpenTofu installation..."
if command -v tofu &> /dev/null; then
    VERSION=$(tofu version | head -n1)
    print_pass "OpenTofu installed: $VERSION"
    ((TESTS_PASSED++))
elif command -v terraform &> /dev/null; then
    VERSION=$(terraform version | head -n1)
    print_pass "Terraform installed: $VERSION"
    ((TESTS_PASSED++))
else
    print_fail "Neither OpenTofu nor Terraform found"
    ((TESTS_FAILED++))
fi

# Test 6: Check AWS CLI
print_test "Checking AWS CLI..."
if command -v aws &> /dev/null; then
    VERSION=$(aws --version)
    print_pass "AWS CLI installed: $VERSION"
    ((TESTS_PASSED++))
else
    print_fail "AWS CLI not found"
    ((TESTS_FAILED++))
fi

# Test 7: Check jq
print_test "Checking jq..."
if command -v jq &> /dev/null; then
    VERSION=$(jq --version)
    print_pass "jq installed: $VERSION"
    ((TESTS_PASSED++))
else
    print_fail "jq not found"
    ((TESTS_FAILED++))
fi

# Test 8: Check AWS credentials
print_test "Checking AWS credentials..."
START_TIME=$(date +%s)
if IDENTITY=$(aws sts get-caller-identity 2>/dev/null); then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    ACCOUNT=$(echo "$IDENTITY" | jq -r .Account)
    USER=$(echo "$IDENTITY" | jq -r .Arn)
    print_pass "AWS credentials valid (${DURATION}s): Account $ACCOUNT"
    print_info "Identity: $USER"
    ((TESTS_PASSED++))
else
    print_fail "AWS credentials not configured"
    ((TESTS_FAILED++))
fi

# Test 9: Check backend configuration
print_test "Checking Terraform backend configuration..."
START_TIME=$(date +%s)
STATE_BUCKET=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/s3-state-bucket" --query Parameter.Value --output text 2>/dev/null || echo "")
DYNAMODB_TABLE=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/dynamodb-lock-table" --query Parameter.Value --output text 2>/dev/null || echo "")
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

if [ -n "$STATE_BUCKET" ] && [ -n "$DYNAMODB_TABLE" ]; then
    print_pass "Backend configured (${DURATION}s): $STATE_BUCKET / $DYNAMODB_TABLE"
    ((TESTS_PASSED++))
else
    print_fail "Backend configuration not found"
    print_info "Deploy terraform-aws-cfn-foundation first"
    ((TESTS_FAILED++))
fi

# Test 10: Validate Terraform configuration
print_test "Validating Terraform configuration..."
START_TIME=$(date +%s)
if tofu validate >/dev/null 2>&1 || terraform validate >/dev/null 2>&1; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    print_pass "Terraform configuration valid (${DURATION}s)"
    ((TESTS_PASSED++))
else
    print_fail "Terraform configuration invalid"
    ((TESTS_FAILED++))
fi

# Test 11: Check script permissions
print_test "Checking script permissions..."
SCRIPTS_OK=true
for script in deploy.sh destroy.sh start-instance.sh stop-instance.sh verify-installation.sh verify-prerequisites.sh; do
    if [ ! -x "scripts/$script" ]; then
        print_fail "Script not executable: scripts/$script"
        SCRIPTS_OK=false
    fi
done

if [ "$SCRIPTS_OK" = true ]; then
    print_pass "All scripts are executable"
    ((TESTS_PASSED++))
else
    ((TESTS_FAILED++))
fi

# Test 12: Verify scripts are non-interactive (syntax check)
print_test "Verifying scripts are non-interactive..."
INTERACTIVE_FOUND=false
for script in scripts/*.sh; do
    if grep -q "read " "$script" 2>/dev/null; then
        print_fail "Script may require user input: $script"
        INTERACTIVE_FOUND=true
    fi
done

if [ "$INTERACTIVE_FOUND" = false ]; then
    print_pass "No interactive prompts found in scripts"
    ((TESTS_PASSED++))
else
    ((TESTS_FAILED++))
fi

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 TEST SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}Passed:${NC} $TESTS_PASSED"
echo -e "${RED}Failed:${NC} $TESTS_FAILED"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}✅ All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}❌ Some tests failed${NC}"
    exit 1
fi
