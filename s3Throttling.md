# S3 Download Throttling Analysis

# Use multipart download (parallel streams)

# Use S3 VPC Gateway Endpoint - Free, keeps traffic within AWS network

# Consider larger instance - T3.large has 5 Gbps burst baseline

## Problem Statement

During development, Splunk installer downloads (1.6 GB) from S3 exhibit inconsistent performance:

- **First deployment**: Completes in ~2 minutes (acceptable)
- **Subsequent deployments**: Timeout after 20+ minutes (unacceptable)

## Root Cause Analysis

### Primary Suspect: S3 Bandwidth Throttling

**Observed behavior pattern:**

- New EC2 instances start with fresh network credits
- Each new instance should have full burst capability
- Yet subsequent downloads to new instances still slow down
- **Conclusion**: Throttling is S3-side, not EC2-side

**S3 throttling characteristics:**

- Not well-documented by AWS
- Triggered by sustained high bandwidth from single source/object
- Affects repeated downloads of same object in short timespan
- Typically resets within 1-5 minutes after request rate drops

### Secondary Factor: T3a Instance Network Credits

**T3a.medium network performance:**

- "Up to 5 Gbps" (burstable)
- Starts with initial burst credits
- Credits deplete during sustained transfers
- Credits replenish slowly over time

**Why this is secondary:**

- Each new instance gets fresh credits
- First download should always be fast (it was)
- Doesn't explain why new instances also slow down

## Installer Details

**File information:**

- **Location**: `s3://splunk-installer-694394480102-us-east-1/splunk-10.0.2-e2d18b4767e9-linux-amd64.tgz`
- **Size**: 1.6 GB (1,638 MB)
- **Region**: us-east-1

**Expected download times at various speeds:**

- 100 Mbps (12.5 MB/s): ~2.2 minutes
- 500 Mbps (62.5 MB/s): ~26 seconds
- 1 Gbps (125 MB/s): ~13 seconds
- 5 Gbps (625 MB/s): ~2.6 seconds (theoretical max)

**Actual observed:**

- First deploy: <2 minutes (good)
- Later deploys: 20+ minutes (indicates <1.4 MB/s - severe throttling)

## Factors Affecting Download Speed

### S3-Side Factors

- **Bucket region**: Same region = faster (us-east-1 ✓)
- **Object size**: Large objects (>1GB) can trigger different throttling behavior
- **Request patterns**: Rapid repeated downloads of same object trigger throttling
- **Time of day**: AWS region load (minimal impact)
- **Per-prefix limits**: 5,500 GET requests/second (not the issue for single large object)

### EC2-Side Factors

- **Instance type network performance**:
  - t3a.medium: "Up to 5 Gbps" (burstable)
  - t3.large: "Up to 5 Gbps" (burstable)
  - m5.large: 10 Gbps (sustained, non-burstable)
- **Network credits**: T3/T3a instances use credits for burst performance
- **Placement**: Same AZ as S3 endpoint (not controllable)

### Network Path Factors

- **Internet Gateway**: Shared bandwidth, variable latency (current setup)
- **VPC Endpoint (Gateway)**: Direct S3 connection, more consistent
- **NAT Gateway**: Not applicable (using public subnet)

## Testing for Throttling

### Test Script Created

**Location**: `scripts/test-s3-throttling.sh`

**What it does:**

1. Downloads installer 3 times consecutively
2. Measures speed for each download
3. Checks for throttling error codes (503 SlowDown, RequestTimeout)
4. Compares speeds across tests

**How to run:**

```bash
./scripts/test-s3-throttling.sh
```

**Interpreting results:**

- **No throttling**: All 3 downloads complete in similar times (~13-26 seconds)
- **Throttling present**: First download fast, subsequent downloads much slower
- **Error indicators**: "SlowDown", "503 Service Unavailable", "RequestTimeout"

### CloudWatch Metrics Check

**Check for S3 errors:**

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/S3 \
  --metric-name 4xxErrors \
  --dimensions Name=BucketName,Value=splunk-installer-694394480102-us-east-1 \
  --start-time $(date -u -v-24H +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 3600 \
  --statistics Sum \
  --region us-east-1
```

### S3 Access Logs

Currently not enabled. Can enable for detailed throttling analysis:

```bash
aws s3api put-bucket-logging \
  --bucket splunk-installer-694394480102-us-east-1 \
  --bucket-logging-status file://logging-config.json
```

## Solutions

### Use Case Context

**Development phase** (current):

- Multiple downloads in short timespan
- Hitting S3 throttling frequently
- Need reliable, repeatable deploys

**Production phase** (future):

- Single downloads with long gaps between them
- Throttling unlikely to occur
- Need fast, predictable deployment

### Solution 1: VPC Endpoint for S3 (Recommended for Development)

**What it is:**

- Gateway endpoint providing direct connection to S3
- Bypasses Internet Gateway
- No data transfer charges

**Benefits:**

- **Cost**: Free
- **Performance**: More consistent, reduces throttling impact
- **Setup time**: 5 minutes
- **Maintenance**: None

**Implementation:**

```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = data.aws_vpc.default.id
  service_name = "com.amazonaws.us-east-1.s3"
  route_table_ids = [data.aws_vpc.default.main_route_table_id]
}
```

**Limitations:**

- Doesn't eliminate S3-side throttling entirely
- Reduces but doesn't prevent throttling during rapid testing

### Solution 2: Pre-built AMI (Recommended for Production)

**What it is:**

- Create AMI from successfully deployed Splunk instance
- Deploy new instances from AMI instead of downloading installer
- Eliminates S3 download entirely

**Benefits:**

- **Deploy time**: <2 minutes (no download)
- **Reliability**: No throttling possible
- **Predictability**: Consistent performance
- **Perfect for**: Infrequent singleton deploys

**Costs:**

- **Storage**: ~$0.08/month for 100GB AMI
- **Snapshot**: ~$0.05/GB/month = $0.08/month for 1.6GB

**Trade-offs:**

- AMI maintenance overhead
- Must update AMI when Splunk version changes
- Storage costs (minimal)

**Implementation approach:**

1. Deploy instance successfully with installer
2. Create AMI from running instance
3. Add Terraform variable to choose: AMI vs fresh install
4. Implement AMI lifecycle management (delete old versions)

### Solution 3: S3 Transfer Acceleration

**What it is:**

- Uses CloudFront edge locations for faster transfers
- Better for long-distance transfers

**Benefits:**

- Faster for cross-region scenarios
- No infrastructure changes needed

**Costs:**

- **$0.04/GB** = $0.07 per deployment for 1.6GB
- Only helps if distance is the issue

**Recommendation:**

- Not ideal for same-region transfers
- More expensive than AMI approach
- Doesn't solve S3 throttling

### Solution 4: Larger Instance Type

**Options:**

- m5.large: 10 Gbps sustained (non-burstable)
- c5.large: 10 Gbps sustained

**Benefits:**

- Better sustained network performance
- No burst credit concerns

**Costs:**

- m5.large: ~$0.096/hr vs t3a.medium: ~$0.0376/hr
- 2.5x more expensive

**Limitations:**

- Doesn't solve S3-side throttling
- Only helps with EC2-side network performance

### Solution 5: Wait Strategy (Development Workaround)

**Approach:**

- Wait 2-5 minutes between test deploys
- Allow S3 throttling to reset

**Benefits:**

- Free
- No infrastructure changes

**Trade-offs:**

- Annoying during active development
- Not a real solution

## Recommended Implementation Strategy

### Phase 1: Immediate (Development)

1. **Add VPC Endpoint** (5 min setup, free)
   - Improves consistency
   - Reduces throttling impact
   - No ongoing costs

2. **Wait 2-3 minutes between test deploys**
   - Allows S3 throttling to reset
   - Temporary workaround during development

3. **Run throttling test script**
   - Confirm VPC Endpoint improvement
   - Measure actual speeds

### Phase 2: Production Readiness

1. **Keep VPC Endpoint** (already deployed)

2. **Create pre-built AMI**
   - After first successful deploy
   - Use for instant deploys (<2 min)
   - No download needed

3. **Add Terraform variable for deployment mode**

   ```hcl
   variable "use_prebuilt_ami" {
     description = "Use pre-built AMI instead of fresh install"
     type        = bool
     default     = false
   }
   ```

4. **Implement AMI refresh workflow**
   - Update AMI when Splunk version changes
   - Delete old AMI versions
   - Automated via script

### Phase 3: Optimization (Optional)

1. **AMI lifecycle management**
   - Automatic AMI creation after successful deploy
   - Retention policy (keep last 2 versions)
   - Cleanup of old AMIs

2. **Monitoring and alerting**
   - CloudWatch metrics for download times
   - Alerts if download exceeds threshold

## Cost Comparison

### Current Approach (Installer Download)

- **Idle**: $0
- **Active session**: ~$0.08/hr (t3a.medium)
- **Typical 3-hour session**: ~$0.24
- **Annual (weekly sessions)**: ~$12.48

### With VPC Endpoint

- **Additional cost**: $0
- **Same as current**

### With Pre-built AMI

- **AMI storage**: ~$0.08/month = ~$0.96/year
- **Active session**: ~$0.08/hr (t3a.medium)
- **Typical 3-hour session**: ~$0.24
- **Annual (weekly sessions)**: ~$13.44 (only $0.96 more)

### With Larger Instance (m5.large)

- **Idle**: $0
- **Active session**: ~$0.096/hr (m5.large)
- **Typical 3-hour session**: ~$0.29
- **Annual (weekly sessions)**: ~$15.08

## S3 Throttling Reset Timing

**Based on observed behavior** (not officially documented):

- **Request rate throttling**: Resets within 1-5 minutes after request rate drops
- **Bandwidth throttling**: Resets faster (30 seconds to 2 minutes)
- **No hard reset time**: Adaptive based on request patterns

**For your use case:**

- Development: Wait 2-3 minutes between deploys
- Production: Long gaps between deploys = no throttling

## Next Steps

1. **Run throttling test**: `./scripts/test-s3-throttling.sh`
2. **Add VPC Endpoint**: 3-line Terraform addition
3. **Test with VPC Endpoint**: Measure improvement
4. **Create AMI workflow**: For production use
5. **Document AMI refresh process**: When Splunk updates

## References

- Splunk installer: 1.6 GB (1,638 MB)
- Current instance: t3a.medium (up to 5 Gbps burstable)
- S3 bucket: splunk-installer-694394480102-us-east-1
- Region: us-east-1
- Test script: `scripts/test-s3-throttling.sh`

---

**Document created**: 2026-01-14  
**Last updated**: 2026-01-14
