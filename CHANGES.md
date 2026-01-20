# X-Origin-Verify Header Removal - Changes Summary

## Date
2026-01-20

## Objective
Remove `X-Origin-Verify` custom header requirement from CloudFront distribution to enable AWS Kinesis Firehose to use `SplunkDestinationConfiguration` instead of `HttpEndpointDestinationConfiguration`.

## Problem Statement
AWS Kinesis Firehose's `HttpEndpointDestinationConfiguration` with `CommonAttributes` does not properly deliver the `Authorization` header to Splunk HEC, causing all delivery attempts to fail with "Token is required" errors. The native `SplunkDestinationConfiguration` handles authentication correctly but does not support custom headers.

## Solution
Remove the `X-Origin-Verify` custom header requirement from the CloudFront distribution. Security is maintained through:
- Network-level protection: Security group restricts port 8088 to CloudFront prefix list
- HTTPS encryption: Client → CloudFront uses ACM certificate
- HEC token authentication: Splunk validates all requests

## Files Modified

### 1. cloudfront-setup/main.tf
- **Removed**: `origin_secret` variable declaration
- **Removed**: `custom_header` block from CloudFront origin configuration
- **Impact**: CloudFront no longer sends or requires X-Origin-Verify header

### 2. scripts/setup-cloudfront.sh
- **Removed**: Origin secret generation logic (openssl rand -hex 32)
- **Removed**: Parameter Store write for `/ephemeral-splunk/origin-secret`
- **Removed**: `origin_secret` variable from inline Terraform
- **Removed**: `custom_header` block from inline Terraform
- **Removed**: `-var="origin_secret=$ORIGIN_SECRET"` from tofu plan command
- **Removed**: Origin secret references from output messages
- **Impact**: Script no longer generates or uses origin secret

### 3. scripts/destroy-cloudfront.sh
- **Removed**: Parameter Store read for `/ephemeral-splunk/origin-secret`
- **Removed**: `-var="origin_secret=$ORIGIN_SECRET"` from tofu plan command
- **Impact**: Destroy script no longer requires origin secret

### 4. scripts/list-deployed-resources.sh
- **Removed**: Origin secret retrieval and display section
- **Impact**: Script no longer shows origin secret in resource listing

### 5. README.md
- **Updated**: Data flow section - removed X-Origin-Verify validation step
- **Updated**: Security model - removed origin header line
- **Updated**: CloudFront configuration - removed custom header line
- **Updated**: Firehose configuration - changed to SplunkDestinationConfiguration format
- **Removed**: X-Origin-Verify from custom headers section
- **Removed**: Origin secret retrieval command
- **Removed**: `/ephemeral-splunk/origin-secret` from Parameter Store values list
- **Impact**: Documentation now reflects headerless architecture

## Files NOT Modified

### scripts/test-splunk-hec.sh
- **Status**: Already correct - never used X-Origin-Verify header
- **Reason**: Test script sends requests directly with Authorization header only

## Architecture Changes

### Before
```
Kinesis Firehose → CloudFront (validates X-Origin-Verify) → EC2:8088 → Splunk HEC
```

### After
```
Kinesis Firehose → CloudFront (HTTPS termination only) → EC2:8088 → Splunk HEC
```

## Security Considerations

### Removed Protection
- Custom header validation at CloudFront origin

### Maintained Protection
- **Network isolation**: Security group allows port 8088 only from CloudFront prefix list
- **HTTPS encryption**: Client to CloudFront uses ACM certificate
- **Authentication**: Splunk HEC validates token on all requests
- **No public access**: EC2 instance not directly accessible from internet

### Why This Is Safe
Header-based validation provides minimal security because:
1. Headers can be spoofed if endpoint is publicly accessible
2. Network-level controls (security groups) are more effective
3. HEC token authentication is the primary security mechanism
4. CloudFront IP restriction prevents direct EC2 access

## Testing Required

1. **Deploy CloudFront changes**:
   ```bash
   cd /Users/stephenabbot/projects/service-ephemeral-splunk
   ./scripts/setup-cloudfront.sh
   ```

2. **Verify HEC endpoint works without header**:
   ```bash
   ./scripts/test-splunk-hec.sh
   ```
   Expected: All 3 test events successfully indexed

3. **Update Firehose configuration** (in private-splunk-cw-firehose-to-splunk project):
   - Replace `HttpEndpointDestinationConfiguration` with `SplunkDestinationConfiguration`
   - Remove all `CommonAttributes`
   - Set `HECEndpoint` to CloudFront URL
   - Set `HECToken` from Parameter Store
   - Set `HECEndpointType` to "Event"

4. **Verify Firehose delivery**:
   - Send test event to CloudWatch Log Group
   - Check Firehose metrics: `DeliveryToSplunk.Success` should be > 0
   - Verify events appear in Splunk

## Rollback Plan

If issues occur:
1. Revert all changes: `git checkout HEAD~1`
2. Redeploy CloudFront: `./scripts/setup-cloudfront.sh`
3. Firehose will continue using `HttpEndpointDestinationConfiguration` (with known issues)

## Parameter Store Cleanup

The following Parameter Store entry is now obsolete and can be deleted manually:
```bash
aws ssm delete-parameter --name /ephemeral-splunk/origin-secret
```

Note: This is not automated to avoid breaking existing deployments during transition.

## Next Steps

1. ✅ Remove X-Origin-Verify from service-ephemeral-splunk (this change)
2. ⏳ Deploy updated CloudFront configuration
3. ⏳ Test HEC endpoint without header
4. ⏳ Update Firehose to use SplunkDestinationConfiguration
5. ⏳ Verify end-to-end data flow
6. ⏳ Delete obsolete Parameter Store entry

## References
- Issue documentation: `remove-x-origin-verify.md`
- AWS Documentation: [SplunkDestinationConfiguration](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-properties-kinesisfirehose-deliverystream-splunkdestinationconfiguration.html)
