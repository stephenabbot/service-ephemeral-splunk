#!/bin/bash
# scripts/test-splunk-hec.sh - Send test events to Splunk via CloudFront with indexer acknowledgment

set -euo pipefail

export AWS_PAGER=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "🧪 TESTING SPLUNK HEC WITH INDEXER ACKNOWLEDGMENT 🧪"
echo ""

# Get HEC token
print_status "Retrieving HEC token from Parameter Store..."
HEC_TOKEN=$(aws ssm get-parameter --name /ephemeral-splunk/hec-token --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "")

if [ -z "$HEC_TOKEN" ]; then
    print_error "HEC token not found in Parameter Store"
    exit 1
fi

print_success "HEC token retrieved"

# Get CloudFront endpoint
print_status "Retrieving CloudFront endpoint from Parameter Store..."
CLOUDFRONT_ENDPOINT=$(aws ssm get-parameter --name /ephemeral-splunk/cloudfront-endpoint --query Parameter.Value --output text 2>/dev/null || echo "")

if [ -z "$CLOUDFRONT_ENDPOINT" ]; then
    print_error "CloudFront endpoint not found in Parameter Store"
    exit 1
fi

print_success "CloudFront endpoint: $CLOUDFRONT_ENDPOINT"

# Generate channel GUID
CHANNEL_ID=$(uuidgen)
print_status "Generated channel ID: $CHANNEL_ID"

# Send test events and collect ackIds
echo ""
print_status "Sending 3 test events to Splunk HEC..."
echo ""

declare -a ACK_IDS=()
SUCCESS_COUNT=0
FAIL_COUNT=0

for i in 1 2 3; do
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$CLOUDFRONT_ENDPOINT/services/collector/event" \
        -H "Authorization: Splunk $HEC_TOKEN" \
        -H "X-Splunk-Request-Channel: $CHANNEL_ID" \
        -H "Content-Type: application/json" \
        -d "{\"event\": \"Test event $i from test script\", \"sourcetype\": \"manual\", \"index\": \"main\"}")
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
    BODY=$(echo "$RESPONSE" | sed '$d')
    
    if [ "$HTTP_CODE" = "200" ]; then
        ACK_ID=$(echo "$BODY" | grep -o '"ackId":[0-9]*' | cut -d: -f2)
        if [ -n "$ACK_ID" ]; then
            ACK_IDS+=("$ACK_ID")
            print_success "Event $i: Received ackId $ACK_ID"
            ((SUCCESS_COUNT++))
        else
            print_error "Event $i: HTTP 200 but no ackId in response: $BODY"
            ((FAIL_COUNT++))
        fi
    else
        print_error "Event $i: HTTP $HTTP_CODE - $BODY"
        ((FAIL_COUNT++))
    fi
done

if [ ${#ACK_IDS[@]} -eq 0 ]; then
    echo ""
    print_error "No acknowledgment IDs received. Cannot verify indexing."
    exit 1
fi

# Wait for indexing
echo ""
print_status "Waiting 5 seconds for events to be indexed..."
sleep 5

# Query acknowledgment status
print_status "Querying acknowledgment status for ${#ACK_IDS[@]} events..."

# Build JSON array of ack IDs
ACK_JSON="["
for i in "${!ACK_IDS[@]}"; do
    if [ $i -gt 0 ]; then
        ACK_JSON+=","
    fi
    ACK_JSON+="${ACK_IDS[$i]}"
done
ACK_JSON+="]"

ACK_QUERY="{\"acks\":$ACK_JSON}"

ACK_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$CLOUDFRONT_ENDPOINT/services/collector/ack?channel=$CHANNEL_ID" \
    -H "Authorization: Splunk $HEC_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$ACK_QUERY")

ACK_HTTP_CODE=$(echo "$ACK_RESPONSE" | tail -n 1)
ACK_BODY=$(echo "$ACK_RESPONSE" | sed '$d')

echo ""
if [ "$ACK_HTTP_CODE" = "200" ]; then
    print_success "Acknowledgment query successful"
    echo "Response: $ACK_BODY"
    
    # Parse response to check if all events are indexed
    INDEXED_COUNT=$(echo "$ACK_BODY" | jq -r '.acks | to_entries[] | select(.value == true) | .key' | wc -l)
    
    echo ""
    echo "📊 INDEXING STATUS"
    echo "  • Events sent: $SUCCESS_COUNT"
    echo "  • Events indexed: $INDEXED_COUNT"
    
    if [ "$INDEXED_COUNT" -eq "$SUCCESS_COUNT" ]; then
        print_success "All events successfully indexed!"
        exit 0
    else
        print_error "Some events not yet indexed. Response: $ACK_BODY"
        exit 1
    fi
else
    print_error "Acknowledgment query failed: HTTP $ACK_HTTP_CODE - $ACK_BODY"
    exit 1
fi
