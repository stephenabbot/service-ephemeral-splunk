# Remove X-Origin-Verify Header Requirement

## Problem

AWS Kinesis Firehose cannot successfully deliver data to Splunk HEC when using `HttpEndpointDestinationConfiguration` with custom headers. All delivery attempts fail with:

```
HTTP 401: {"text":"Token is required","code":2}
```

**Root Cause**: Firehose's `CommonAttributes` mechanism for sending custom HTTP headers does not properly deliver the `Authorization` header to Splunk HEC, even though the header is correctly configured in the Firehose delivery stream.

## Evidence

1. **Firehose Configuration (Verified via AWS API)**:
   ```json
   "CommonAttributes": [
     {"AttributeName": "Authorization", "AttributeValue": "Splunk 714b59a7-..."},
     {"AttributeName": "X-Origin-Verify", "AttributeValue": "b86e2a22..."},
     {"AttributeName": "X-Splunk-Request-Channel", "AttributeValue": "uuid"},
     {"AttributeName": "Content-Type", "AttributeValue": "application/json"}
   ]
   ```

2. **Curl Test (Works Perfectly)**:
   ```bash
   curl -X POST "https://splunk.bittikens.com/services/collector/event" \
     -H "Authorization: Splunk 714b59a7-..." \
     -H "X-Origin-Verify: b86e2a22..." \
     -H "X-Splunk-Request-Channel: uuid" \
     -H "Content-Type: application/json" \
     -d '{"event": "test"}'
   # Returns: HTTP 200 {"text":"Success","code":0,"ackId":0}
   ```

3. **Firehose Delivery (Fails)**:
   - All records end up in S3 backup bucket under `failed-records-errors/http-endpoint-failed/`
   - Error message: "Token is required" (Splunk not receiving Authorization header)
   - 5+ retry attempts per batch, all failing

## Solution

**Use AWS Firehose's built-in `SplunkDestinationConfiguration`** instead of generic `HttpEndpointDestinationConfiguration`.

### Why This Works

`SplunkDestinationConfiguration` has native support for Splunk HEC authentication:
- `HECEndpoint`: Splunk HEC URL
- `HECToken`: Authentication token (properly formatted by AWS)
- `HECEndpointType`: "Event" or "Raw"

AWS handles the Authorization header formatting internally, avoiding the CommonAttributes issue.

### Why X-Origin-Verify Must Be Removed

`SplunkDestinationConfiguration` does not support custom headers. It only sends:
- `Authorization: Splunk {HECToken}` (automatically)
- `X-Splunk-Request-Channel: {uuid}` (automatically)

To use this configuration, the CloudFront distribution must not require `X-Origin-Verify` header from clients.

## Required Changes to service-ephemeral-splunk

### File: `cloudfront-setup/main.tf`

**Current Configuration** (lines 84-87):
```hcl
custom_header {
  name  = "X-Origin-Verify"
  value = var.origin_secret
}
```

**Action Required**: **REMOVE** the entire `custom_header` block from the origin configuration.

### Why This Is Safe

**Original Intent**: Prevent direct access to Splunk HEC endpoint, force all traffic through CloudFront.

**Alternative Protection Mechanisms**:

1. **Network-Level Protection**:
   - Splunk HEC endpoint should be in a private subnet or security group
   - Only allow inbound traffic from CloudFront IP ranges
   - This is more secure than header-based validation

2. **CloudFront Origin Shield**:
   - Reduces load on origin
   - Provides additional caching layer

3. **AWS WAF** (if needed):
   - Rate limiting
   - Geographic restrictions
   - IP allowlist/blocklist

**Header-based validation is weak security** because:
- Headers can be spoofed if the endpoint is publicly accessible
- Doesn't prevent direct access if someone discovers the header value
- Network-level controls are more effective

## Implementation Steps

1. **Update CloudFront Configuration**:
   - Remove `custom_header` block from `cloudfront-setup/main.tf`
   - Apply Terraform changes: `terraform apply`

2. **Update Firehose Configuration** (in private-splunk-cw-firehose-to-splunk project):
   - Replace `HttpEndpointDestinationConfiguration` with `SplunkDestinationConfiguration`
   - Remove all `CommonAttributes` (Authorization, X-Origin-Verify, etc.)
   - Use `HECEndpoint` and `HECToken` parameters instead

3. **Test Delivery**:
   - Send test event to CloudWatch Log Group
   - Verify Firehose delivers to Splunk successfully
   - Check CloudWatch metrics: `DeliveryToSplunk.Success` should be > 0

## Expected Outcome

After removing the `X-Origin-Verify` requirement:
- ✅ Firehose will successfully deliver to Splunk using `SplunkDestinationConfiguration`
- ✅ AWS handles HEC authentication properly
- ✅ No more "Token is required" errors
- ✅ Data flows: CloudWatch Logs → Firehose → Lambda → Firehose → CloudFront → Splunk

## Testing After Changes

```bash
# 1. Verify CloudFront no longer requires X-Origin-Verify
curl -X POST "https://splunk.bittikens.com/services/collector/event" \
  -H "Authorization: Splunk {token}" \
  -H "X-Splunk-Request-Channel: {uuid}" \
  -d '{"event": "test without origin verify"}'
# Should return: HTTP 200

# 2. Deploy updated Firehose stack
cd projects/stephenabbot-base_694394480102
./scripts/deploy.sh

# 3. Send test event
aws logs put-log-events --region us-east-2 \
  --log-group-name "/aws/lambda/use2-demo-heartbeat" \
  --log-stream-name "test-stream" \
  --log-events timestamp=$(date +%s)000,message="Test after fix"

# 4. Wait 90 seconds, then check metrics
aws cloudwatch get-metric-statistics --region us-east-2 \
  --namespace AWS/Firehose \
  --metric-name DeliveryToSplunk.Success \
  --dimensions Name=DeliveryStreamName,Value=cw-log-to-splunk-XX-use2-firehose \
  --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Sum
# Should show Sum > 0
```

## References

- AWS Documentation: [SplunkDestinationConfiguration](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-properties-kinesisfirehose-deliverystream-splunkdestinationconfiguration.html)
- Splunk Community: [HEC Token Authentication Issues](https://community.splunk.com/t5/Dashboards-Visualizations/After-setting-up-the-HTTP-Event-Collector-on-a-heavy-forwarder/td-p/253816)
- Investigation Date: 2026-01-20
- Related Project: private-splunk-cw-firehose-to-splunk
