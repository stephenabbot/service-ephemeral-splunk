#!/bin/bash
# Test S3 download speeds to detect throttling

set -euo pipefail

BUCKET="splunk-installer-694394480102-us-east-1"
KEY="splunk-10.0.2-e2d18b4767e9-linux-amd64.tgz"
REGION="us-east-1"
NUM_TESTS=3

echo "Testing S3 download speeds for throttling detection"
echo "Bucket: $BUCKET"
echo "Key: $KEY"
echo "Running $NUM_TESTS consecutive downloads..."
echo ""

for i in $(seq 1 $NUM_TESTS); do
    echo "=== Test $i of $NUM_TESTS ==="
    
    START=$(date +%s)
    
    if aws s3 cp "s3://$BUCKET/$KEY" "/tmp/splunk-test-$i.tgz" --region "$REGION" 2>&1 | tee /tmp/download-log-$i.txt; then
        END=$(date +%s)
        DURATION=$((END - START))
        SIZE=$(stat -f%z "/tmp/splunk-test-$i.tgz" 2>/dev/null || stat -c%s "/tmp/splunk-test-$i.tgz")
        SPEED=$(echo "scale=2; $SIZE / $DURATION / 1024 / 1024" | bc)
        
        echo "✓ Download completed in ${DURATION}s"
        echo "  Speed: ${SPEED} MB/s"
        
        # Check for throttling indicators in output
        if grep -q "SlowDown\|RequestTimeout\|503" /tmp/download-log-$i.txt; then
            echo "⚠️  THROTTLING DETECTED in download logs"
        fi
        
        rm -f "/tmp/splunk-test-$i.tgz" /tmp/download-log-$i.txt
    else
        echo "❌ Download failed"
        cat /tmp/download-log-$i.txt
    fi
    
    echo ""
    
    # Small delay between tests
    if [ $i -lt $NUM_TESTS ]; then
        echo "Waiting 5 seconds before next test..."
        sleep 5
    fi
done

echo "=== Summary ==="
echo "If speeds degraded significantly across tests, S3 throttling is likely."
echo "Expected: Similar speeds across all tests if no throttling."
