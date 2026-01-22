#!/bin/bash
# scripts/start-instance.sh - Start stopped Splunk instance

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

echo "▶️  STARTING EPHEMERAL SPLUNK INSTANCE ▶️"
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
INSTANCE_INFO=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0]' 2>/dev/null || echo "{}")
INSTANCE_STATE=$(echo "$INSTANCE_INFO" | jq -r '.State.Name // "not-found"')

case "$INSTANCE_STATE" in
    "running")
        print_success "Instance is already running"
        ;;
    "stopped")
        print_status "Starting stopped instance..."
        aws ec2 start-instances --instance-ids "$INSTANCE_ID" > /dev/null
        
        print_status "Waiting for instance to start..."
        aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
        print_success "Instance started successfully"
        ;;
    "pending")
        print_status "Instance is already starting up..."
        aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
        print_success "Instance is now running"
        ;;
    "stopping")
        print_status "Instance is stopping. Waiting for it to stop completely..."
        aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
        
        print_status "Starting instance..."
        aws ec2 start-instances --instance-ids "$INSTANCE_ID" > /dev/null
        aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
        print_success "Instance started successfully"
        ;;
    "not-found")
        print_error "Instance not found. Infrastructure may have been destroyed."
        exit 1
        ;;
    *)
        print_error "Instance is in unexpected state: $INSTANCE_STATE"
        print_error "Cannot start instance in this state"
        exit 1
        ;;
esac

# Get updated instance information
print_status "Getting updated instance information..."
INSTANCE_INFO=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0]')
INSTANCE_IP=$(echo "$INSTANCE_INFO" | jq -r '.PublicIpAddress // "N/A"')
INSTANCE_STATE=$(echo "$INSTANCE_INFO" | jq -r '.State.Name')

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

if [ "$SSM_READY" = true ]; then
    print_success "SSM agent is online"
else
    print_warning "SSM agent not ready yet - may need a few more minutes"
fi

# Verify Splunk is running and listening
print_status "Verifying Splunk service is running and ready..."

if [ "$SSM_READY" = true ]; then
    # Check Splunk process and listening ports
    COMMAND_ID=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=[
            "echo \"=== SPLUNK_PROCESS ===\"",
            "pgrep -f splunkd > /dev/null && echo RUNNING || echo NOT_RUNNING",
            "echo \"=== PORT_8088 ===\"",
            "sudo netstat -tlnp 2>/dev/null | grep :8088 | grep LISTEN > /dev/null && echo LISTENING || echo NOT_LISTENING",
            "echo \"=== PORT_8000 ===\"",
            "sudo netstat -tlnp 2>/dev/null | grep :8000 | grep LISTEN > /dev/null && echo LISTENING || echo NOT_LISTENING"
        ]' \
        --query 'Command.CommandId' \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$COMMAND_ID" ]; then
        sleep 5
        
        CHECK_OUTPUT=$(aws ssm get-command-invocation \
            --command-id "$COMMAND_ID" \
            --instance-id "$INSTANCE_ID" \
            --query 'StandardOutputContent' \
            --output text 2>/dev/null || echo "")
        
        SPLUNK_RUNNING=$(echo "$CHECK_OUTPUT" | grep -A1 "SPLUNK_PROCESS" | tail -1 | tr -d '\n')
        PORT_8088=$(echo "$CHECK_OUTPUT" | grep -A1 "PORT_8088" | tail -1 | tr -d '\n')
        PORT_8000=$(echo "$CHECK_OUTPUT" | grep -A1 "PORT_8000" | tail -1 | tr -d '\n')
        
        if [ "$SPLUNK_RUNNING" = "RUNNING" ]; then
            print_success "Splunk process is running"
        else
            print_error "Splunk process is not running"
            print_status "Starting Splunk service..."
            
            START_CMD=$(aws ssm send-command \
                --instance-ids "$INSTANCE_ID" \
                --document-name "AWS-RunShellScript" \
                --parameters 'commands=["sudo systemctl start splunk || sudo -u splunk /opt/splunk/bin/splunk start --accept-license --answer-yes --no-prompt"]' \
                --query 'Command.CommandId' \
                --output text 2>/dev/null || echo "")
            
            if [ -n "$START_CMD" ]; then
                sleep 30
                print_status "Waiting for Splunk to start..."
            fi
        fi
        
        # Wait for ports to be listening (up to 60 seconds)
        print_status "Waiting for Splunk ports to be ready..."
        PORTS_READY=false
        for i in {1..12}; do
            VERIFY_CMD=$(aws ssm send-command \
                --instance-ids "$INSTANCE_ID" \
                --document-name "AWS-RunShellScript" \
                --parameters 'commands=[
                    "sudo netstat -tlnp 2>/dev/null | grep :8088 | grep LISTEN > /dev/null && echo HEC_OK || echo HEC_NOT_READY",
                    "sudo netstat -tlnp 2>/dev/null | grep :8000 | grep LISTEN > /dev/null && echo WEB_OK || echo WEB_NOT_READY"
                ]' \
                --query 'Command.CommandId' \
                --output text 2>/dev/null || echo "")
            
            if [ -n "$VERIFY_CMD" ]; then
                sleep 5
                VERIFY_OUTPUT=$(aws ssm get-command-invocation \
                    --command-id "$VERIFY_CMD" \
                    --instance-id "$INSTANCE_ID" \
                    --query 'StandardOutputContent' \
                    --output text 2>/dev/null || echo "")
                
                if echo "$VERIFY_OUTPUT" | grep -q "HEC_OK" && echo "$VERIFY_OUTPUT" | grep -q "WEB_OK"; then
                    PORTS_READY=true
                    break
                fi
            fi
            echo -n "."
            sleep 5
        done
        echo ""
        
        if [ "$PORTS_READY" = true ]; then
            print_success "Splunk HEC is listening on port 8088"
            print_success "Splunk web UI is listening on port 8000"
        else
            print_error "Splunk ports are not ready after 60 seconds"
            print_status "Check logs: aws ssm start-session --target $INSTANCE_ID"
            exit 1
        fi
    else
        print_warning "Could not verify Splunk status via SSM"
    fi
else
    print_warning "Cannot verify Splunk status - SSM not ready"
    exit 1
fi

echo ""
echo "✅ INSTANCE STARTED AND VERIFIED"
echo ""
echo "📋 Instance Information:"
echo "  • Instance ID: $INSTANCE_ID"
echo "  • State: $INSTANCE_STATE"
echo "  • Public IP: $INSTANCE_IP"
echo "  • Splunk HEC: Listening on port 8088"
echo "  • Splunk Web UI: Listening on port 8000"
echo ""
echo "🌐 To access Splunk web interface:"
echo "  1. Run this command in your terminal:"
echo "     aws ssm start-session --target $INSTANCE_ID --document-name AWS-StartPortForwardingSession --parameters 'portNumber=8000,localPortNumber=8000'"
echo ""
echo "  2. Open your browser to: http://localhost:8000"
echo ""
echo "  3. Login with username: admin  password: changeme"
echo ""
echo "🔍 Additional Commands:"
echo "  • Verify installation: ./scripts/verify-installation.sh"
echo "  • SSM Shell: aws ssm start-session --target $INSTANCE_ID"
echo ""
echo "▶️  Instance is ready for use! ▶️"
