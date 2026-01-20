#!/bin/bash
# scripts/verify-installation.sh - Verify Splunk installation and infrastructure

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

echo "🔍 VERIFYING EPHEMERAL SPLUNK INSTALLATION 🔍"
echo ""

# Get instance ID from Parameter Store
print_status "Retrieving instance ID from Parameter Store..."
INSTANCE_ID=$(aws ssm get-parameter --name /ephemeral-splunk/instance-id --query Parameter.Value --output text 2>/dev/null || echo "")

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "null" ]; then
    print_error "Could not get instance ID from Parameter Store"
    print_error "Infrastructure may not be deployed. Run ./scripts/deploy.sh first"
    exit 1
fi

LOG_GROUP="/ec2/ephemeral-splunk"

print_status "Checking infrastructure components..."

# Check EC2 instance state
print_status "Checking EC2 instance state..."
INSTANCE_STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "not-found")

case "$INSTANCE_STATE" in
    "running")
        print_success "EC2 instance is running"
        ;;
    "pending")
        print_warning "EC2 instance is still starting up"
        ;;
    "stopped"|"stopping")
        print_warning "EC2 instance is stopped or stopping"
        ;;
    "not-found")
        print_error "EC2 instance not found"
        exit 1
        ;;
    *)
        print_error "EC2 instance is in unexpected state: $INSTANCE_STATE"
        exit 1
        ;;
esac

# Check CloudWatch Log Group
print_status "Checking CloudWatch Log Group..."
if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --query 'logGroups[0].logGroupName' --output text > /dev/null 2>&1; then
    print_success "CloudWatch Log Group exists: $LOG_GROUP"
else
    print_error "CloudWatch Log Group not found: $LOG_GROUP"
fi

# Check SNS topic
if [ -f "infrastructure-outputs.json" ]; then
    print_status "Checking SNS topic..."
    SNS_TOPIC_ARN=$(jq -r '.instance_info.value.sns_topic_arn' infrastructure-outputs.json 2>/dev/null || echo "")
    if [ -n "$SNS_TOPIC_ARN" ] && [ "$SNS_TOPIC_ARN" != "null" ]; then
        if aws sns get-topic-attributes --topic-arn "$SNS_TOPIC_ARN" > /dev/null 2>&1; then
            print_success "SNS topic exists for cost alarms"
        else
            print_warning "SNS topic not found: $SNS_TOPIC_ARN"
        fi
    fi
fi

# Only check Splunk if instance is running
if [ "$INSTANCE_STATE" = "running" ]; then
    print_status "Checking Splunk installation status..."
    
    # Wait for SSM agent to be ready
    print_status "Waiting for SSM agent to be ready..."
    SSM_READY=false
    for i in {1..30}; do
        if aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE_ID" --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null | grep -q "Online"; then
            SSM_READY=true
            break
        fi
        echo -n "."
        sleep 10
    done
    echo ""
    
    if [ "$SSM_READY" = false ]; then
        print_warning "SSM agent not ready yet - may need a few more minutes"
        print_status "Run this script again in a few minutes to check Splunk status"
    else
        print_success "SSM agent is online"
        
        # Check installation logs for completion
        print_status "Checking installation logs..."
        
        LOG_EVENTS=$(aws logs filter-log-events \
            --log-group-name "$LOG_GROUP" \
            --start-time $(($(date +%s) * 1000 - 3600000)) \
            --query 'events[].message' \
            --output text 2>/dev/null || echo "")
        
        if echo "$LOG_EVENTS" | grep -q "SPLUNK_INSTALLATION_COMPLETE"; then
            print_success "Splunk installation completed successfully"
        elif echo "$LOG_EVENTS" | grep -q "ERROR"; then
            print_error "Splunk installation encountered errors"
            print_status "Check logs: aws logs tail $LOG_GROUP --follow"
        else
            print_warning "Splunk installation may still be in progress"
            print_status "Check logs: aws logs tail $LOG_GROUP --follow"
        fi
        
        # Check if Splunk process is running
        print_status "Checking Splunk service status..."
        COMMAND_ID=$(aws ssm send-command \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["pgrep -f splunkd > /dev/null && echo RUNNING || echo NOT_RUNNING"]' \
            --query 'Command.CommandId' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$COMMAND_ID" ]; then
            sleep 5
            
            SPLUNK_STATUS=$(aws ssm get-command-invocation \
                --command-id "$COMMAND_ID" \
                --instance-id "$INSTANCE_ID" \
                --query 'StandardOutputContent' \
                --output text 2>/dev/null | tr -d '\n' || echo "UNKNOWN")
            
            if [ "$SPLUNK_STATUS" = "RUNNING" ]; then
                print_success "Splunk service is running"
                
                # Check HEC token
                HEC_TOKEN=$(aws ssm get-parameter --name /ephemeral-splunk/hec-token --query Parameter.Value --output text 2>/dev/null || echo "")
                if [ -n "$HEC_TOKEN" ] && [[ ! "$HEC_TOKEN" == placeholder-* ]]; then
                    print_success "HEC token is configured"
                else
                    print_warning "HEC token not yet configured"
                fi
            else
                print_warning "Splunk service is not running"
            fi
        fi
    fi
elif [ "$INSTANCE_STATE" = "stopped" ]; then
    print_warning "Instance is stopped. Start it with: ./scripts/start-instance.sh"
elif [ "$INSTANCE_STATE" = "stopping" ]; then
    print_warning "Instance is stopping"
elif [ "$INSTANCE_STATE" = "pending" ]; then
    print_warning "Instance is starting up. Wait a few minutes and run this script again."
fi

echo ""
echo "📋 VERIFICATION SUMMARY"
echo ""
echo "Infrastructure Status:"
echo "  • Instance ID: $INSTANCE_ID"
echo "  • Instance State: $INSTANCE_STATE"
echo "  • Log Group: $LOG_GROUP"
echo ""

if [ "$INSTANCE_STATE" = "running" ]; then
    echo "🌐 To access Splunk web interface:"
    echo "  1. Run this command in your terminal:"
    echo "     aws ssm start-session --target $INSTANCE_ID --document-name AWS-StartPortForwardingSession --parameters 'portNumber=8000,localPortNumber=8000'"
    echo ""
    echo "  2. Open your browser to: http://localhost:8000"
    echo ""
    echo "  3. Login with username: admin  password: changeme"
    echo ""
    echo "📊 HEC Endpoint:"
    HEC_ENDPOINT=$(aws ssm get-parameter --name /ephemeral-splunk/cloudfront-endpoint --query Parameter.Value --output text 2>/dev/null || echo "not configured")
    echo "  • Endpoint: $HEC_ENDPOINT/services/collector"
    echo ""
    echo "📊 Monitoring:"
    echo "  • CloudWatch Logs: aws logs tail $LOG_GROUP --follow"
    echo "  • Cost Alarms: Configured for \$5, \$10, \$20"
else
    echo "ℹ️  Instance is not running. Use ./scripts/start-instance.sh to start it."
fi

echo ""
echo "✅ Verification complete"
