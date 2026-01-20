#!/bin/bash
# scripts/enable-hec-acknowledgment.sh - Enable indexer acknowledgment on running Splunk instance

set -euo pipefail

export AWS_PAGER=""

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "🔧 ENABLING HEC INDEXER ACKNOWLEDGMENT 🔧"
echo ""

# Get instance ID
print_status "Retrieving instance ID..."
INSTANCE_ID=$(aws ssm get-parameter --name /ephemeral-splunk/instance-id --query Parameter.Value --output text 2>/dev/null || echo "")

if [ -z "$INSTANCE_ID" ]; then
    print_error "Instance ID not found in Parameter Store"
    exit 1
fi

print_success "Instance ID: $INSTANCE_ID"

# Enable acknowledgment in inputs.conf
print_status "Modifying HEC token configuration to enable indexer acknowledgment..."

COMMAND_ID=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=[
"sudo sed -i \"s/useACK = 0/useACK = 1/g\" /opt/splunk/etc/apps/splunk_httpinput/local/inputs.conf",
"grep -A 5 \"\\[http://firehose-token\\]\" /opt/splunk/etc/apps/splunk_httpinput/local/inputs.conf"
]' \
    --query 'Command.CommandId' \
    --output text)

print_status "Waiting for command to complete..."
sleep 5

COMMAND_OUTPUT=$(aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query 'StandardOutputContent' \
    --output text)

if echo "$COMMAND_OUTPUT" | grep -q "useACK = 1"; then
    print_success "Configuration updated successfully"
    echo ""
    echo "Updated configuration:"
    echo "$COMMAND_OUTPUT"
else
    print_error "Failed to update configuration"
    echo "Output: $COMMAND_OUTPUT"
    exit 1
fi

# Restart Splunk to apply changes
echo ""
print_status "Restarting Splunk to apply changes..."

RESTART_CMD=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["sudo -u splunk /opt/splunk/bin/splunk restart"]' \
    --query 'Command.CommandId' \
    --output text)

print_status "Waiting for Splunk to restart (30 seconds)..."
sleep 30

# Verify Splunk is running
print_status "Verifying Splunk is running..."

VERIFY_CMD=$(aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["pgrep -f splunkd && echo \"Splunk is running\" || echo \"Splunk is not running\""]' \
    --query 'Command.CommandId' \
    --output text)

sleep 5

VERIFY_OUTPUT=$(aws ssm get-command-invocation \
    --command-id "$VERIFY_CMD" \
    --instance-id "$INSTANCE_ID" \
    --query 'StandardOutputContent' \
    --output text)

if echo "$VERIFY_OUTPUT" | grep -q "Splunk is running"; then
    echo ""
    print_success "HEC indexer acknowledgment enabled successfully!"
    echo ""
    echo "✅ Next steps:"
    echo "  1. Run ./scripts/test-splunk-hec.sh to verify acknowledgment workflow"
    echo "  2. Events will now return ackId instead of Success message"
    echo "  3. Test script will query /services/collector/ack to verify indexing"
else
    print_error "Splunk is not running after restart"
    echo "Output: $VERIFY_OUTPUT"
    exit 1
fi
