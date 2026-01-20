#!/bin/bash
# scripts/list-deployed-resources.sh - List all deployed resources and configuration

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

# Disable AWS CLI pager
export AWS_PAGER=""

echo "📋 EPHEMERAL SPLUNK DEPLOYED RESOURCES 📋"
echo ""

# Get instance ID from Parameter Store
print_status "Retrieving deployment information..."
INSTANCE_ID=$(aws ssm get-parameter --name /ephemeral-splunk/instance-id --query Parameter.Value --output text 2>/dev/null || echo "")

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "null" ]; then
    print_error "Could not get instance ID from Parameter Store"
    print_error "Infrastructure may not be deployed. Run ./scripts/deploy.sh first"
    exit 1
fi

echo "═══════════════════════════════════════════════════════════════"
echo "EC2 INSTANCE"
echo "═══════════════════════════════════════════════════════════════"

INSTANCE_INFO=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0]' 2>/dev/null || echo "{}")

INSTANCE_STATE=$(echo "$INSTANCE_INFO" | jq -r '.State.Name // "unknown"')
INSTANCE_TYPE=$(echo "$INSTANCE_INFO" | jq -r '.InstanceType // "unknown"')
PRIVATE_IP=$(echo "$INSTANCE_INFO" | jq -r '.PrivateIpAddress // "unknown"')
AZ=$(echo "$INSTANCE_INFO" | jq -r '.Placement.AvailabilityZone // "unknown"')
LAUNCH_TIME=$(echo "$INSTANCE_INFO" | jq -r '.LaunchTime // "unknown"')

echo "Instance ID:      $INSTANCE_ID"
echo "State:            $INSTANCE_STATE"
echo "Instance Type:    $INSTANCE_TYPE"
echo "Private IP:       $PRIVATE_IP"
echo "Availability Zone: $AZ"
echo "Launch Time:      $LAUNCH_TIME"
echo ""

echo "═══════════════════════════════════════════════════════════════"
echo "PARAMETER STORE VALUES"
echo "═══════════════════════════════════════════════════════════════"

echo "Instance ID:"
echo "  Key:   /ephemeral-splunk/instance-id"
echo "  Value: $INSTANCE_ID"
echo ""

HEC_TOKEN=$(aws ssm get-parameter --name /ephemeral-splunk/hec-token --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "not configured")
echo "HEC Token:"
echo "  Key:   /ephemeral-splunk/hec-token"
echo "  Value: ${HEC_TOKEN:0:8}...${HEC_TOKEN: -8}"
echo ""

CLOUDFRONT_ENDPOINT=$(aws ssm get-parameter --name /ephemeral-splunk/cloudfront-endpoint --query Parameter.Value --output text 2>/dev/null || echo "not configured")
echo "CloudFront Endpoint:"
echo "  Key:   /ephemeral-splunk/cloudfront-endpoint"
echo "  Value: $CLOUDFRONT_ENDPOINT"
echo ""

CLOUDFRONT_DIST_ID=$(aws ssm get-parameter --name /ephemeral-splunk/cloudfront-distribution-id --query Parameter.Value --output text 2>/dev/null || echo "not configured")
if [ "$CLOUDFRONT_DIST_ID" != "not configured" ]; then
    echo "CloudFront Distribution ID:"
    echo "  Key:   /ephemeral-splunk/cloudfront-distribution-id"
    echo "  Value: $CLOUDFRONT_DIST_ID"
    echo ""
fi

echo "═══════════════════════════════════════════════════════════════"
echo "CLOUDWATCH LOGS"
echo "═══════════════════════════════════════════════════════════════"

LOG_GROUP="/ec2/ephemeral-splunk"
echo "Log Group:        $LOG_GROUP"
echo "View Logs:        aws logs tail $LOG_GROUP --follow"
echo ""

echo "═══════════════════════════════════════════════════════════════"
echo "ACCESS COMMANDS"
echo "═══════════════════════════════════════════════════════════════"

echo "SSM Session (shell access):"
echo "  aws ssm start-session --target $INSTANCE_ID"
echo ""

echo "Port Forward (web UI on localhost:8000):"
echo "  aws ssm start-session --target $INSTANCE_ID \\"
echo "    --document-name AWS-StartPortForwardingSession \\"
echo "    --parameters 'portNumber=8000,localPortNumber=8000'"
echo ""

echo "Splunk Web UI:"
echo "  http://localhost:8000"
echo "  Username: admin"
echo "  Password: changeme"
echo ""

echo "═══════════════════════════════════════════════════════════════"
echo "TEST HEC ENDPOINT"
echo "═══════════════════════════════════════════════════════════════"

if [ "$CLOUDFRONT_ENDPOINT" != "not configured" ]; then
    echo "Run test script:"
    echo "  ./scripts/test-splunk-hec.sh"
    echo ""
    
    echo "HEC Endpoint:"
    echo "  $CLOUDFRONT_ENDPOINT/services/collector/event"
    echo ""
    
    echo "Manual curl test:"
    echo "  HEC_TOKEN=\$(aws ssm get-parameter --name /ephemeral-splunk/hec-token --with-decryption --query Parameter.Value --output text)"
    echo "  curl -X POST $CLOUDFRONT_ENDPOINT/services/collector/event \\"
    echo "    -H \"Authorization: Splunk \$HEC_TOKEN\" \\"
    echo "    -H \"Content-Type: application/json\" \\"
    echo "    -d '{\"event\":\"test message\",\"sourcetype\":\"manual\",\"index\":\"main\"}'"
else
    echo "CloudFront not configured. Run ./scripts/setup-cloudfront.sh first."
fi
echo ""

echo "✅ Resource listing complete"
