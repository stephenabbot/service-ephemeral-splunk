# Complete Firehose → Splunk Implementation Guide

## Architecture Overview

```
CloudWatch Log Group → Subscription Filter → Kinesis Firehose → [Optional Lambda Transform] → Splunk HEC
                                                    ↓
                                              S3 Backup Bucket
```

---

## **Official Documentation References**

1. **AWS Firehose to Splunk Configuration:** <https://docs.aws.amazon.com/firehose/latest/dev/create-destination.html#create-destination-splunk>
2. **CloudWatch Logs Subscription Filters:** <https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/SubscriptionFilters.html>
3. **Firehose Data Transformation:** <https://docs.aws.amazon.com/firehose/latest/dev/data-transformation.html>
4. **Splunk HEC Event Format:** <https://docs.splunk.com/Documentation/Splunk/latest/Data/FormateventsforHTTPEventCollector>
5. **CloudWatch Logs to Firehose Blueprint:** <https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/SubscriptionFilters.html#FirehoseExample>
6. **Lambda Transform Blueprint:** <https://github.com/aws-samples/amazon-kinesis-firehose-data-transformation-blueprints>
7. **Splunk Cloud HEC Setup:** <https://docs.splunk.com/Documentation/SplunkCloud/latest/Data/UsetheHTTPEventCollector>

---

## **Integration & Configuration Points**

### **1. Splunk HEC Configuration**

**Location:** Splunk Cloud Web UI → Settings → Data Inputs → HTTP Event Collector

**Steps:**

```
1. Enable HEC globally (if not enabled)
   Settings → Data Inputs → HTTP Event Collector → Global Settings
   ☑ All Tokens → Enabled
   ☑ Enable SSL (required)

2. Create new HEC token
   New Token → Name: "aws-firehose-account-123"
   
3. Configure token settings:
   ├── Source type: aws:cloudwatch (or leave empty for dynamic)
   ├── Index: your-target-index
   ├── Default Index: your-target-index (fallback)
   ├── Allowed Indexes: your-target-index (whitelist)
   └── Enable Indexer Acknowledgement: ☑ (recommended for reliability)

4. Note the token value and HEC endpoint:
   Token: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   Endpoint: https://http-inputs-<instance>.splunkcloud.com:8088/services/collector
```

**HEC Endpoint Format:**

- Event endpoint (raw JSON): `/services/collector/event`
- Raw endpoint (pre-formatted): `/services/collector/raw`
- Firehose uses: `/services/collector/event` (default)

**Index Configuration:**

```
Settings → Indexes → New Index
├── Index Name: aws_logs_account123
├── Index Data Type: Events
├── Max Size: 500GB (example)
└── Retention: 90 days (healthcare: 7 years for audit logs)
```

---

### **2. AWS IAM Roles & Permissions**

**A. Firehose Execution Role**

**Trust Policy:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "firehose.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

**Permissions Policy:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "S3BackupAccess",
      "Effect": "Allow",
      "Action": [
        "s3:AbortMultipartUpload",
        "s3:GetBucketLocation",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::firehose-backup-bucket-account123",
        "arn:aws:s3:::firehose-backup-bucket-account123/*"
      ]
    },
    {
      "Sid": "LambdaTransformAccess",
      "Effect": "Allow",
      "Action": [
        "lambda:InvokeFunction",
        "lambda:GetFunctionConfiguration"
      ],
      "Resource": "arn:aws:lambda:us-east-1:123456789012:function:firehose-transform"
    },
    {
      "Sid": "CloudWatchLogsAccess",
      "Effect": "Allow",
      "Action": [
        "logs:PutLogEvents",
        "logs:CreateLogStream"
      ],
      "Resource": "arn:aws:logs:us-east-1:123456789012:log-group:/aws/kinesisfirehose/*"
    }
  ]
}
```

**B. CloudWatch Logs Subscription Role**

**Trust Policy:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "logs.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

**Permissions Policy:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "firehose:PutRecord",
        "firehose:PutRecordBatch"
      ],
      "Resource": "arn:aws:firehose:us-east-1:123456789012:deliverystream/cloudwatch-to-splunk"
    }
  ]
}
```

---

### **3. S3 Backup Bucket Configuration**

**Purpose:** Store failed delivery events (HEC unavailable, validation errors)

**Bucket Setup:**

```
Bucket name: firehose-backup-account123-us-east-1
├── Versioning: Enabled (recommended)
├── Encryption: AES-256 or KMS
├── Lifecycle Policy:
│   └── Transition to Glacier after 30 days
│       Delete after 7 years (healthcare compliance)
├── Bucket Policy: (below)
└── Block Public Access: All enabled
```

**Bucket Policy:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::123456789012:role/firehose-execution-role"
      },
      "Action": [
        "s3:AbortMultipartUpload",
        "s3:GetBucketLocation",
        "s3:GetObject",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::firehose-backup-account123-us-east-1",
        "arn:aws:s3:::firehose-backup-account123-us-east-1/*"
      ]
    }
  ]
}
```

**Backup Prefix Structure:**

```
s3://bucket/
├── failed-events/
│   ├── 2026/01/07/14/
│   │   └── delivery-failed-2026-01-07-14-30-00-abc123.json
├── processing-failed/
│   └── (Lambda transform failures)
└── format-conversion-failed/
    └── (Rare: malformed records)
```

---

### **4. Kinesis Firehose Delivery Stream Configuration**

**Create Firehose Stream:**

**Basic Settings:**

```
Name: cloudwatch-to-splunk-account123
Source: Direct PUT (CloudWatch Logs will use this)
```

**Destination Settings:**

```
Destination: Splunk

Splunk Cluster Endpoint: https://http-inputs-<instance>.splunkcloud.com:8088
Authentication Token: <your-HEC-token>

HEC Endpoint Type: Event endpoint (raw JSON events)
  └── This sends to /services/collector/event

Retry Duration: 300 seconds (5 minutes)
  └── Firehose retries failed deliveries for this duration
  
S3 Backup Mode: All events OR Failed events only
  └── Recommended: "Failed events only" (saves S3 costs)
  └── For compliance: "All events" (retain all logs in S3)

S3 Backup Bucket: s3://firehose-backup-account123-us-east-1
S3 Prefix: failed-events/
S3 Error Prefix: processing-failed/
```

**Processing Configuration:**

```
☑ Data Transformation: Enabled (if using Lambda)
Lambda Function: arn:aws:lambda:region:account:function:firehose-transform
Buffer Size: 1 MB (for Lambda transform) or 5 MB (direct)
Buffer Interval: 60 seconds

Compression: GZIP (for S3 backup) or None (for Splunk)
  └── Splunk HEC doesn't support compressed payloads
  └── Use GZIP for S3 backup, None for HEC
```

**Buffer & Batch Settings:**

```
Buffer Size: 5 MB (max for Splunk destination)
  └── Smaller = lower latency, higher cost
  └── Larger = higher latency, lower cost
  
Buffer Interval: 60 seconds (balance of latency vs cost)
  └── Range: 60-900 seconds
  └── Triggers: whichever comes first (size OR time)

HEC Acknowledgement Timeout: 180 seconds
  └── How long to wait for Splunk to acknowledge receipt
```

**Network Configuration:**

```
VPC Configuration: Not applicable
  └── Firehose is AWS-managed, doesn't run in your VPC
  └── Uses AWS-managed NAT for Splunk Cloud egress
```

**CloudWatch Logging:**

```
☑ Enable CloudWatch Logs
Log Group: /aws/kinesisfirehose/cloudwatch-to-splunk-account123
  ├── delivery (successful deliveries)
  ├── backupToS3 (S3 backup events)
  └── httpEndpointDelivery (HEC delivery attempts)
```

**Tags:**

```
Account: 123456789012
Environment: production
CostCenter: engineering
Compliance: HIPAA
```

---

### **5. CloudWatch Logs Subscription Filter**

**This is where your CSV automation comes in**

**CSV Structure:**

```csv
account_id,region,log_group_name,firehose_arn,filter_pattern
123456789012,us-east-1,/aws/lambda/function-1,arn:aws:firehose:us-east-1:123456789012:deliverystream/cloudwatch-to-splunk-account123,""
123456789012,us-east-1,/ecs/service-api,arn:aws:firehose:us-east-1:123456789012:deliverystream/cloudwatch-to-splunk-account123,"{ $.level != ""DEBUG"" }"
123456789012,us-west-2,/aws/lambda/function-2,arn:aws:firehose:us-west-2:123456789012:deliverystream/cloudwatch-to-splunk-account123,""
```

**Subscription Filter Configuration (per log group):**

```
Log Group: /aws/lambda/function-1
Subscription Filter Name: firehose-to-splunk
Destination ARN: arn:aws:firehose:us-east-1:123456789012:deliverystream/cloudwatch-to-splunk-account123
Role ARN: arn:aws:iam::123456789012:role/cloudwatch-logs-to-firehose

Filter Pattern: "" (empty = all logs)
  └── OR: Apply filter to exclude DEBUG logs (see below)
  
Distribution: By log stream (default)
  └── Random distribution across Firehose shards
```

**Filter Pattern Examples:**

```
# All logs (no filter)
""

# Exclude DEBUG logs
[timestamp, request_id, level != DEBUG*, ...]

# Include only ERROR and WARN
[level = ERROR || level = WARN]

# Exclude specific strings
-"healthcheck" -"ping"

# JSON-based filtering (if logs are JSON)
{ $.level != "DEBUG" }

# Exclude by pattern matching
-"GET /health" -"GET /metrics"
```

**IMPORTANT CloudWatch Subscription Filter Limitations:**

- **One subscription filter per log group** (current AWS limit)
- Cannot have multiple destinations per log group
- Filter pattern evaluated before sending to Firehose
- Complex filtering better done in Lambda transform

---

### **6. Lambda Transform Function (Optional)**

**Purpose:** Filter DEBUG logs, add metadata, transform events

**Lambda Configuration:**

```
Function Name: firehose-cloudwatch-transform
Runtime: Python 3.12
Memory: 512 MB (sufficient for most transforms)
Timeout: 300 seconds (max for Firehose)
Environment Variables:
  ├── SPLUNK_INDEX: aws_logs_account123
  ├── DEFAULT_SOURCETYPE: aws:cloudwatch
  └── ACCOUNT_ID: 123456789012
```

**Execution Role Permissions:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:*"
    }
  ]
}
```

**Lambda Function Code (Python):**

```python
import json
import base64
import gzip
import os
from datetime import datetime

def lambda_handler(event, context):
    """
    Firehose Data Transformation Lambda
    
    Input: Firehose records (base64-encoded CloudWatch Logs data)
    Output: Transformed records for Splunk HEC
    """
    
    output_records = []
    
    for record in event['records']:
        # Decode Firehose record
        payload = base64.b64decode(record['data'])
        
        # CloudWatch Logs data is gzip-compressed
        decompressed = gzip.decompress(payload)
        log_data = json.loads(decompressed)
        
        # Extract CloudWatch Logs metadata
        log_group = log_data.get('logGroup', 'unknown')
        log_stream = log_data.get('logStream', 'unknown')
        account_id = os.environ.get('ACCOUNT_ID', 'unknown')
        
        # Process each log event
        for log_event in log_data.get('logEvents', []):
            # Extract event fields
            message = log_event.get('message', '')
            timestamp_ms = log_event.get('timestamp', 0)
            
            # FILTER: Skip DEBUG logs
            if filter_debug_logs(message):
                continue
            
            # Parse message (if JSON)
            parsed_message = parse_message(message)
            
            # Build Splunk HEC event
            hec_event = {
                "time": timestamp_ms / 1000.0,  # Splunk expects epoch seconds
                "host": log_stream,  # Can use instance ID if available
                "source": log_group,  # Source = CloudWatch Log Group name
                "sourcetype": determine_sourcetype(log_group, parsed_message),
                "index": os.environ.get('SPLUNK_INDEX', 'main'),
                "event": enrich_event(parsed_message, log_group, log_stream, account_id)
            }
            
            # Encode for Firehose
            output_record = {
                "recordId": record['recordId'],
                "result": "Ok",
                "data": base64.b64encode(
                    (json.dumps(hec_event) + "\n").encode('utf-8')
                ).decode('utf-8')
            }
            output_records.append(output_record)
    
    return {"records": output_records}


def filter_debug_logs(message):
    """
    Filter out DEBUG level logs
    """
    # Check if message contains DEBUG indicator
    debug_indicators = [
        '"level":"DEBUG"',
        '"level": "DEBUG"',
        '[DEBUG]',
        'DEBUG:',
        'level=DEBUG'
    ]
    
    message_upper = message.upper()
    return any(indicator.upper() in message_upper for indicator in debug_indicators)


def parse_message(message):
    """
    Attempt to parse message as JSON, otherwise return as string
    """
    try:
        return json.loads(message)
    except (json.JSONDecodeError, TypeError):
        return {"raw_message": message}


def determine_sourcetype(log_group, parsed_message):
    """
    Dynamically determine sourcetype based on log group and content
    """
    # Map log groups to sourcetypes
    sourcetype_mappings = {
        "/aws/lambda/": "aws:lambda",
        "/ecs/": "aws:ecs",
        "/aws/eks/": "aws:eks",
        "/aws/rds/": "aws:rds",
        "/aws/apigateway/": "aws:apigateway",
    }
    
    for prefix, sourcetype in sourcetype_mappings.items():
        if log_group.startswith(prefix):
            return sourcetype
    
    # Check if JSON contains specific fields
    if isinstance(parsed_message, dict):
        if "requestId" in parsed_message and "duration" in parsed_message:
            return "aws:lambda"
        elif "httpMethod" in parsed_message and "requestId" in parsed_message:
            return "aws:apigateway"
    
    # Default
    return "aws:cloudwatch"


def enrich_event(parsed_message, log_group, log_stream, account_id):
    """
    Add common metadata fields to event
    """
    # If already a dict, enrich it
    if isinstance(parsed_message, dict):
        enriched = parsed_message.copy()
    else:
        enriched = {"message": parsed_message}
    
    # Add standard metadata fields
    enriched["aws_account_id"] = account_id
    enriched["aws_log_group"] = log_group
    enriched["aws_log_stream"] = log_stream
    enriched["aws_region"] = os.environ.get('AWS_REGION', 'unknown')
    
    # Extract service name from log group
    enriched["service_name"] = extract_service_name(log_group)
    
    # Add ingestion timestamp
    enriched["ingestion_time"] = datetime.utcnow().isoformat() + "Z"
    
    # Extract environment from log group or tags (if available)
    enriched["environment"] = extract_environment(log_group)
    
    return enriched


def extract_service_name(log_group):
    """
    Extract service name from log group path
    Examples:
      /aws/lambda/api-service-prod -> api-service-prod
      /ecs/web-frontend -> web-frontend
    """
    parts = log_group.split('/')
    return parts[-1] if parts else "unknown"


def extract_environment(log_group):
    """
    Infer environment from log group name
    """
    log_group_lower = log_group.lower()
    if "prod" in log_group_lower or "production" in log_group_lower:
        return "production"
    elif "staging" in log_group_lower or "stage" in log_group_lower:
        return "staging"
    elif "dev" in log_group_lower or "development" in log_group_lower:
        return "development"
    else:
        return "unknown"
```

**Lambda Transform - Key Points:**

1. **Input Format:** Firehose sends gzip-compressed CloudWatch Logs data
2. **Output Format:** Splunk HEC JSON format (one event per line)
3. **RecordId:** Must echo back the recordId from input
4. **Result Status:** "Ok", "Dropped", or "ProcessingFailed"
   - "Ok": Successfully transformed, send to Splunk
   - "Dropped": Filtered out (e.g., DEBUG logs), don't send
   - "ProcessingFailed": Error processing, send to S3 backup
5. **Buffer Limits:** Lambda payload max 6 MB (Firehose limitation)

---

### **7. Common Metadata Fields for Splunk**

**Standard Splunk Fields:**

```json
{
  "time": 1704643200.123,        // Epoch timestamp (seconds.milliseconds)
  "host": "log-stream-name",      // Hostname or instance identifier
  "source": "/aws/lambda/func",   // Source identifier (log group)
  "sourcetype": "aws:lambda",     // Data type for parsing
  "index": "aws_logs",            // Target Splunk index
  "event": { ... }                // The actual log data
}
```

**Common AWS Metadata to Add:**

```json
{
  "aws_account_id": "123456789012",
  "aws_region": "us-east-1",
  "aws_log_group": "/aws/lambda/api-service",
  "aws_log_stream": "2026/01/07/[$LATEST]abc123",
  
  // Service identification
  "service_name": "api-service",
  "service_type": "lambda",  // lambda, ecs, eks, ec2
  
  // Environment
  "environment": "production",  // prod, staging, dev
  "cluster": "prod-cluster-1",
  
  // Application context
  "application": "user-api",
  "team": "platform-engineering",
  "cost_center": "engineering",
  
  // Request tracing (if available)
  "trace_id": "1-5f7c8d9e-12345678901234567890",
  "request_id": "abc-123-def-456",
  
  // Ingestion metadata
  "ingestion_time": "2026-01-07T14:30:00Z",
  "ingestion_method": "firehose-lambda",
  
  // Compliance
  "data_classification": "internal",  // public, internal, confidential, restricted
  "pii_present": false,
  "phi_present": false  // Healthcare specific
}
```

**Healthcare-Specific Metadata:**

```json
{
  "hipaa_covered": true,
  "phi_scrubbed": true,
  "patient_id_hashed": "sha256:abc123...",  // If applicable
  "audit_required": true,
  "retention_years": 7
}
```

**Kubernetes/ECS Metadata (if applicable):**

```json
{
  "k8s_namespace": "production",
  "k8s_pod_name": "api-service-7d8f9c-abc12",
  "k8s_container_name": "api",
  "ecs_cluster": "prod-cluster",
  "ecs_task_id": "abc123...",
  "ecs_service": "web-frontend"
}
```

**Cost Allocation Tags:**

```json
{
  "cost_center": "engineering",
  "project": "patient-portal",
  "owner": "platform-team",
  "budget_code": "ENG-2024-Q1"
}
```

---

## **8. Automation: CSV-Driven Subscription Creation**

**Terraform/Python Script for Bulk Subscription Creation:**

**CSV Format:**

```csv
account_id,region,log_group_name,firehose_arn,filter_pattern
123456789012,us-east-1,/aws/lambda/api-service,arn:aws:firehose:us-east-1:123456789012:deliverystream/cw-to-splunk,""
123456789012,us-east-1,/ecs/web-frontend,arn:aws:firehose:us-east-1:123456789012:deliverystream/cw-to-splunk,"{ $.level != ""DEBUG"" }"
123456789012,us-west-2,/aws/lambda/processor,arn:aws:firehose:us-west-2:123456789012:deliverystream/cw-to-splunk-west,""
```

**Python Script (boto3):**

```python
import boto3
import csv
from botocore.exceptions import ClientError

def create_subscription_filters_from_csv(csv_file, role_arn):
    """
    Create CloudWatch Logs subscription filters from CSV
    
    Args:
        csv_file: Path to CSV with log group configurations
        role_arn: IAM role ARN for CloudWatch → Firehose
    """
    
    with open(csv_file, 'r') as f:
        reader = csv.DictReader(f)
        
        for row in reader:
            account_id = row['account_id']
            region = row['region']
            log_group = row['log_group_name']
            firehose_arn = row['firehose_arn']
            filter_pattern = row.get('filter_pattern', '')
            
            # Create CloudWatch Logs client for region
            logs_client = boto3.client('logs', region_name=region)
            
            # Subscription filter name
            filter_name = f"firehose-to-splunk-{log_group.replace('/', '-')}"
            
            try:
                # Check if log group exists
                logs_client.describe_log_groups(logGroupNamePrefix=log_group)
                
                # Create or update subscription filter
                logs_client.put_subscription_filter(
                    logGroupName=log_group,
                    filterName=filter_name,
                    filterPattern=filter_pattern,
                    destinationArn=firehose_arn,
                    roleArn=role_arn,
                    distribution='Random'  # Or 'ByLogStream'
                )
                
                print(f"✓ Created subscription for {log_group} in {region}")
                
            except ClientError as e:
                if e.response['Error']['Code'] == 'ResourceNotFoundException':
                    print(f"✗ Log group not found: {log_group}")
                elif e.response['Error']['Code'] == 'LimitExceededException':
                    print(f"✗ Subscription limit exceeded for {log_group}")
                else:
                    print(f"✗ Error creating subscription for {log_group}: {e}")


if __name__ == "__main__":
    csv_file = "log_subscriptions.csv"
    role_arn = "arn:aws:iam::123456789012:role/cloudwatch-logs-to-firehose"
    
    create_subscription_filters_from_csv(csv_file, role_arn)
```

**Terraform Module:**

```hcl
# modules/cloudwatch-subscription/main.tf

variable "log_group_name" {
  type = string
}

variable "firehose_arn" {
  type = string
}

variable "role_arn" {
  type = string
}

variable "filter_pattern" {
  type    = string
  default = ""  # Empty = all logs
}

resource "aws_cloudwatch_log_subscription_filter" "firehose" {
  name            = "firehose-to-splunk-${replace(var.log_group_name, "/", "-")}"
  log_group_name  = var.log_group_name
  filter_pattern  = var.filter_pattern
  destination_arn = var.firehose_arn
  role_arn        = var.role_arn
  distribution    = "Random"
}
```

**Bulk Deployment (Terraform):**

```hcl
# main.tf

locals {
  log_subscriptions = csvdecode(file("${path.module}/log_subscriptions.csv"))
}

module "subscriptions" {
  for_each = { for sub in local.log_subscriptions : "${sub.region}-${sub.log_group_name}" => sub }
  
  source = "./modules/cloudwatch-subscription"
  
  providers = {
    aws = aws.region[each.value.region]
  }
  
  log_group_name  = each.value.log_group_name
  firehose_arn    = each.value.firehose_arn
  role_arn        = "arn:aws:iam::${each.value.account_id}:role/cloudwatch-logs-to-firehose"
  filter_pattern  = each.value.filter_pattern
}
```

---

## **9. Data Flow & Format at Each Stage**

**Stage 1: CloudWatch Logs (Original)**

```json
{
  "timestamp": 1704643200123,
  "message": "[ERROR] Failed to process request: Database timeout",
  "logStreamName": "2026/01/07/[$LATEST]abc123"
}
```

**Stage 2: CloudWatch → Firehose (Gzip Compressed JSON)**

```json
{
  "messageType": "DATA_MESSAGE",
  "owner": "123456789012",
  "logGroup": "/aws/lambda/api-service",
  "logStream": "2026/01/07/[$LATEST]abc123",
  "subscriptionFilters": ["firehose-to-splunk"],
  "logEvents": [
    {
      "id": "12345678901234567890",
      "timestamp": 1704643200123,
      "message": "[ERROR] Failed to process request: Database timeout"
    }
  ]
}
```

**Stage 3: Lambda Transform (if enabled)**

```json
{
  "time": 1704643200.123,
  "host": "2026/01/07/[$LATEST]abc123",
  "source": "/aws/lambda/api-service",
  "sourcetype": "aws:lambda",
  "index": "aws_logs",
  "event": {
    "level": "ERROR",
    "message": "Failed to process request: Database timeout",
    "aws_account_id": "123456789012",
    "aws_region": "us-east-1",
    "aws_log_group": "/aws/lambda/api-service",
    "service_name": "api-service",
    "environment": "production"
  }
}
```

**Stage 4: Splunk HEC (Final Storage)**

- Splunk parses based on sourcetype
- Indexes with specified index name
- Searchable by any field in "event" object

---

## **10. Testing & Validation**

**A. Test HEC Connectivity**

```bash
curl -k https://http-inputs-<instance>.splunkcloud.com:8088/services/collector/event \
  -H "Authorization: Splunk <HEC_TOKEN>" \
  -d '{"event": "test event", "sourcetype": "manual"}'

# Expected response:
{"text":"Success","code":0}
```

**B. Test Firehose Delivery**

```bash
aws firehose put-record \
  --delivery-stream-name cloudwatch-to-splunk-account123 \
  --record '{"Data":"eyJ0ZXN0IjogInRlc3QifQ=="}'  # Base64 encoded JSON

# Check Firehose metrics in CloudWatch
aws cloudwatch get-metric-statistics \
  --namespace AWS/Firehose \
  --metric-name DeliveryToSplunk.Success \
  --dimensions Name=DeliveryStreamName,Value=cloudwatch-to-splunk-account123 \
  --start-time 2026-01-07T00:00:00Z \
  --end-time 2026-01-07T23:59:59Z \
  --period 300 \
  --statistics Sum
```

**C. Test CloudWatch Subscription**

```bash
# Write test log to CloudWatch
aws logs put-log-events \
  --log-group-name /aws/lambda/api-service \
  --log-stream-name test-stream \
  --log-events timestamp=$(date +%s)000,message="Test log for Firehose"

# Check in Splunk (wait 2-5 minutes)
index=aws_logs source="/aws/lambda/api-service" "Test log for Firehose"
```

**D. Test Lambda Transform**

```bash
# Invoke Lambda with test CloudWatch Logs payload
aws lambda invoke \
  --function-name firehose-cloudwatch-transform \
  --payload file://test-payload.json \
  response.json

cat response.json
```

**test-payload.json:**

```json
{
  "records": [
    {
      "recordId": "test-record-1",
      "data": "H4sIAAAAAAAAADWOwQqDMBBE..."
    }
  ]
}
```

---

## **11. Monitoring & Alerting**

**Key Metrics to Monitor:**

**Firehose Metrics (CloudWatch):**

```
AWS/Firehose

├── DeliveryToHttpEndpoint.Success (count)
├── DeliveryToHttpEndpoint.Records (count) 
├── DeliveryToHttpEndpoint.DataFreshness (seconds)
├── DeliveryToHttpEndpoint.Bytes (bytes)
├── HttpEndpoint.RequestLatency (milliseconds)
├── HttpEndpoint.RequestsPerSecond (count)
├── IncomingRecords (count)
├── IncomingBytes (bytes)
├── ThrottledRecords (count)
└── ExecuteProcessing.Duration (ms) - if Lambda transform enabled

```

**Lambda Transform Metrics:**

```
AWS/Lambda
├── Invocations (count)
├── Errors (count)
├── Duration (ms)
├── Throttles (count)
└── ConcurrentExecutions (count)
```

**CloudWatch Alarms:**

```hcl
resource "aws_cloudwatch_metric_alarm" "firehose_delivery_failures" {
  alarm_name          = "firehose-http-delivery-failures"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DeliveryToHttpEndpoint.Success"
  namespace           = "AWS/Firehose"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  
  dimensions = {
    DeliveryStreamName = "cloudwatch-to-splunk-account123"
  }
}
```

**Splunk Monitoring:**

```spl
# Check ingestion lag
index=aws_logs 
| eval lag = now() - _time 
| stats avg(lag) as avg_lag_seconds, max(lag) as max_lag_seconds

# Count events by source (log group)
index=aws_logs 
| stats count by source

# Detect missing log groups (should see events every 5 minutes)
index=aws_logs earliest=-10m 
| stats count by source 
| where count < 1

# Monitor for errors in Lambda transform
index=_internal sourcetype=aws:cloudwatch:lambda 
| search "ERROR" OR "ProcessingFailed"
```

---

## **12. Cost Optimization**

**Cost Factors:**

```
Firehose:
├── Data ingested: $0.029/GB
├── Format conversion: $0.018/GB (not used for Splunk)
└── VPC delivery: No additional charge

Lambda Transform:
├── Invocations: $0.20/million
├── Duration: $0.0000166667/GB-second
└── Typically <$1/month for 100GB

S3 Backup:
├── Storage: $0.023/GB/month
├── PUT requests: $0.005/1000 requests
└── Only for failed events (typically <1%)

CloudWatch Logs:
├── Data ingestion: $0.50/GB (already paying this)
├── Storage: $0.03/GB/month (already paying this)
└── Subscription filter: No additional charge
```

**Optimization Strategies:**

1. **Increase Buffer Size/Interval:** Reduce Firehose invocation frequency
   - 5MB / 300s vs 1MB / 60s = 80% cost reduction
   - Trade-off: Higher latency

2. **Filter in CloudWatch:** Reduce data sent to Firehose
   - Filter pattern: Exclude DEBUG logs before Firehose
   - Saves Firehose ingestion costs
   - Trade-off: Less flexible than Lambda filtering

3. **Efficient Lambda Transform:**
   - Process multiple events per invocation (already done by Firehose batching)
   - Use minimal memory (512MB sufficient)
   - Optimize parsing logic

4. **S3 Lifecycle:** Transition backup data to Glacier
   - After 30 days → Glacier ($0.004/GB/month)
   - After 7 years → Delete (or Glacier Deep Archive)

---

## **Benefits & Tradeoffs of Lambda Transform**

### **Without Lambda Transform**

**Pros:**

- Simpler architecture (fewer components)
- Lower latency (one less hop)
- Lower cost (no Lambda invocations)
- No Lambda concurrency limits

**Cons:**

- Cannot filter DEBUG logs (sent to Splunk, waste indexing capacity)
- Limited metadata (only CloudWatch default fields)
- Sourcetype is static (configured in HEC token)
- Source is set to log group (can't customize per event)

### **With Lambda Transform**

**Pros:**

- **Filter DEBUG logs:** Save 30-50% Splunk indexing capacity
- **Rich metadata:** Add account ID, region, service name, environment, etc.
- **Dynamic sourcetype:** Determine based on log content
- **Event enrichment:** Parse JSON, extract fields, normalize formats
- **Data scrubbing:** Remove PHI/PII for compliance
- **Cost allocation:** Add tags for chargeback

**Cons:**

- Higher latency: +30-60 seconds (Lambda cold start + processing)
- Additional cost: ~$1-5/month (Lambda invocations + duration)
- More complexity: Lambda code to maintain, test, deploy
- Potential failure point: Lambda errors → events to S3 backup

### **Recommendation:**

**Use Lambda transform IF:**

- Need to filter logs (DEBUG exclusion saves money)
- Healthcare compliance requires PHI scrubbing
- Need rich metadata for cost allocation, analytics
- 100 different teams = standardized metadata critical

**Skip Lambda IF:**

- Low volume (<10GB/month)
- Simple use case (just want logs in Splunk)
- Latency critical (need <60 second delivery)
- Team lacks Lambda expertise

---

## **Summary Configuration Checklist**

**Splunk Side:**

- [ ] HEC endpoint enabled globally
- [ ] HEC token created with index permissions
- [ ] Index created (retention, size limits)
- [ ] Sourcetype defined (if custom parsing needed)

**AWS IAM:**

- [ ] Firehose execution role created
- [ ] CloudWatch Logs subscription role created
- [ ] S3 bucket policy allows Firehose access
- [ ] Lambda execution role (if using transform)

**AWS S3:**

- [ ] Backup bucket created
- [ ] Encryption enabled (SSE-S3 or KMS)
- [ ] Lifecycle policy configured
- [ ] Block public access enabled

**AWS Lambda (if using):**

- [ ] Transform function deployed
- [ ] Environment variables configured
- [ ] Timeout set to 300 seconds
- [ ] Memory allocation (512MB minimum)
- [ ] CloudWatch Logs enabled for debugging

**AWS Firehose:**

- [ ] Delivery stream created
- [ ] Splunk destination configured (HEC endpoint + token)
- [ ] S3 backup enabled
- [ ] Buffer size/interval configured
- [ ] Lambda transform enabled (if using)
- [ ] CloudWatch Logs enabled
- [ ] Tags applied

**AWS CloudWatch Logs:**

- [ ] Log groups identified (CSV prepared)
- [ ] Subscription filters created (per log group)
- [ ] Filter patterns configured (if filtering at source)
- [ ] Role ARN specified for Firehose access

**Testing:**

- [ ] HEC connectivity test (curl)
- [ ] Firehose delivery test (put-record)
- [ ] CloudWatch subscription test (put-log-events)
- [ ] Lambda transform test (if using)
- [ ] End-to-end test (write log → see in Splunk)

**Monitoring:**

- [ ] CloudWatch alarms created (delivery failures)
- [ ] Splunk alert for ingestion lag
- [ ] Dashboard for volume by source
- [ ] S3 backup monitoring (should be empty)

---

## **Conclusion**

This comprehensive guide covers all integration points for sending CloudWatch Logs to Splunk via Firehose. Your CSV-driven automation approach is sound — most enterprises use similar patterns for bulk subscription management.

The Lambda transform adds significant value for your use case (100 teams, healthcare compliance, cost allocation), outweighing the marginal complexity.

Key takeaways:

- Firehose eliminates firewall rule exhaustion (zero rules required)
- Lambda transform enables filtering and rich metadata
- S3 backup ensures no data loss
- CSV automation scales to hundreds of accounts
- Healthcare compliance supported through encryption and metadata
