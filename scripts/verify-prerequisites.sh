#!/bin/bash
# scripts/verify-prerequisites.sh - Verify deployment prerequisites

set -euo pipefail

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

# Change to project root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

print_status "Verifying prerequisites..."

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    print_error "Not in a git repository"
    exit 1
fi

# Check for required tools
REQUIRED_TOOLS=("tofu" "aws" "jq")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        print_error "$tool is not installed or not in PATH"
        exit 1
    fi
done
print_success "Required tools are available"

# Check git repository state
print_status "Checking git repository state..."

# Check for uncommitted changes
if ! git diff-index --quiet HEAD --; then
    print_error "Repository has uncommitted changes"
    git status --porcelain
    exit 1
fi

# Check for untracked files
if [ -n "$(git ls-files --others --exclude-standard)" ]; then
    print_error "Repository has untracked files"
    git ls-files --others --exclude-standard
    exit 1
fi

# Check if local branch is up to date with remote
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if git ls-remote --exit-code origin "$BRANCH" > /dev/null 2>&1; then
    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse "origin/$BRANCH")
    if [ "$LOCAL" != "$REMOTE" ]; then
        print_error "Local branch is not up to date with remote"
        print_error "Run: git pull origin $BRANCH"
        exit 1
    fi
fi
print_success "Git repository state is clean"

# Check AWS credentials
print_status "Checking AWS credentials..."
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    print_error "AWS credentials not configured or invalid"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
print_success "AWS credentials valid (Account: $ACCOUNT_ID)"

# Check foundation infrastructure
print_status "Checking foundation infrastructure..."
FOUNDATION_PARAMS=(
    "/terraform/foundation/s3-state-bucket"
    "/terraform/foundation/dynamodb-lock-table"
    "/terraform/foundation/oidc-provider"
)

for param in "${FOUNDATION_PARAMS[@]}"; do
    if ! aws ssm get-parameter --region us-east-1 --name "$param" > /dev/null 2>&1; then
        print_error "Foundation parameter $param not found"
        print_error "Deploy terraform-aws-cfn-foundation first"
        exit 1
    fi
done
print_success "Foundation infrastructure is available"

# Check deployment role
print_status "Checking deployment role..."

# Get project name from git remote
REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
  PROJECT_NAME="${BASH_REMATCH[2]}"
else
  print_error "Could not determine project name from git remote"
  exit 1
fi

ROLE_PARAM="/deployment-roles/${PROJECT_NAME}/role-arn"
if ! aws ssm get-parameter --region us-east-1 --name "$ROLE_PARAM" > /dev/null 2>&1; then
    print_warning "Deployment role parameter $ROLE_PARAM not found"
    print_warning "This is acceptable for local development with admin credentials"
    print_warning "For GitHub Actions, deploy terraform-aws-deployment-roles first"
else
    print_success "Deployment role is available for project: $PROJECT_NAME"
fi

# Check for default VPC
print_status "Checking default VPC..."
VPC_COUNT=$(aws ec2 describe-vpcs --region us-east-1 --filters "Name=is-default,Values=true" --query "length(Vpcs)" --output text)

if [ "$VPC_COUNT" -eq 0 ]; then
    print_error "No default VPC found in us-east-1"
    print_error "Manual resolution required:"
    print_error "1. Run: aws ec2 create-default-vpc --region us-east-1"
    print_error "2. Or create a custom VPC and update Terraform configuration"
    exit 1
else
    print_success "Default VPC is available"
fi

# Check config.env file
print_status "Checking configuration file..."
if [ ! -f "config.env" ]; then
    print_error "config.env file not found"
    exit 1
fi
print_success "Configuration file found"

print_success "All prerequisites verified successfully"
