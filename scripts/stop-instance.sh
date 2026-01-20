#!/bin/bash
# scripts/stop-instance.sh - Stop running Splunk instance

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

# Disable AWS CLI pager
export AWS_PAGER=""

echo "⏹️  STOPPING EPHEMERAL SPLUNK INSTANCE ⏹️"
echo ""

# Get instance ID from Parameter Store
print_status "Retrieving instance ID from Parameter Store..."
INSTANCE_ID=$(aws ssm get-parameter --name /ephemeral-splunk/instance-id --query Parameter.Value --output text 2>/dev/null || echo "")

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "null" ]; then
    print_error "Could not get instance ID from Parameter Store"
    print_error "Infrastructure may not be deployed. Run ./scripts/deploy.sh first"
    exit 1
fi

print_status "Instance ID: $INSTANCE_ID"

# Check current instance state
print_status "Checking current instance state..."
INSTANCE_STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "not-found")

case "$INSTANCE_STATE" in
    "stopped")
        print_success "Instance is already stopped"
        ;;
    "running")
        print_status "Gracefully stopping Splunk service..."
        
        # Try to gracefully stop Splunk first
        COMMAND_ID=$(aws ssm send-command \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["sudo -u splunk /opt/splunk/bin/splunk stop 2>/dev/null || sudo systemctl stop splunk 2>/dev/null || echo SPLUNK_STOP_ATTEMPTED"]' \
            --query 'Command.CommandId' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$COMMAND_ID" ]; then
            sleep 10  # Give Splunk time to shut down gracefully
            print_status "Splunk shutdown initiated"
        else
            print_warning "Could not send Splunk stop command via SSM"
        fi
        
        print_status "Stopping EC2 instance..."
        aws ec2 stop-instances --instance-ids "$INSTANCE_ID" > /dev/null
        
        print_status "Waiting for instance to stop..."
        aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
        print_success "Instance stopped successfully"
        ;;
    "pending")
        print_warning "Instance is starting up. Waiting for it to be running first..."
        aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
        
        print_status "Now stopping the instance..."
        aws ec2 stop-instances --instance-ids "$INSTANCE_ID" > /dev/null
        aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
        print_success "Instance stopped successfully"
        ;;
    "stopping")
        print_status "Instance is already stopping..."
        aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
        print_success "Instance is now stopped"
        ;;
    "not-found")
        print_error "Instance not found. Infrastructure may have been destroyed."
        exit 1
        ;;
    *)
        print_error "Instance is in unexpected state: $INSTANCE_STATE"
        print_error "Cannot stop instance in this state"
        exit 1
        ;;
esac

# Get final instance state
FINAL_STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text)

echo ""
echo "✅ INSTANCE STOP COMPLETE"
echo ""
echo "📋 Instance Information:"
echo "  • Instance ID: $INSTANCE_ID"
echo "  • State: $FINAL_STATE"
echo ""
echo "💰 Cost Information:"
echo "  • No compute charges while stopped"
echo "  • EBS volume charges still apply (varies by volume size)"
echo "  • Use ./scripts/destroy.sh for zero costs"
echo ""
echo "🔄 Management Commands:"
echo "  • Start instance: ./scripts/start-instance.sh"
echo "  • Check status: ./scripts/verify-installation.sh"
echo "  • Destroy all: ./scripts/destroy.sh"
echo ""
echo "⏹️  Instance stopped successfully! ⏹️"
