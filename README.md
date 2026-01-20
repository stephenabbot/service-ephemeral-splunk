# Ephemeral Splunk Infrastructure

This project provides automated infrastructure for deploying ephemeral Splunk Enterprise instances on AWS EC2 with CloudFront-fronted HTTP Event Collector (HEC) for receiving data from AWS Kinesis Firehose. The infrastructure enables complete deploy/destroy cycles for Splunk environments used in proof-of-concept work, data analysis, and development tasks with zero idle costs when not in use.

## What This Project Does

**Core Functionality:**
- Deploys a fresh Splunk Enterprise instance on AWS EC2 (spot instance)
- Automatically configures Splunk HEC for data ingestion
- Creates a CloudFront distribution with custom domain (splunk.bittikens.com)
- Provides secure HEC endpoint for AWS Kinesis Firehose integration
- Enables complete infrastructure teardown for zero idle costs

**Key Features:**
- **True Fresh Install**: Complete deploy/destroy cycles with zero idle costs
- **CloudFront Integration**: Secure, scalable HEC endpoint with custom domain and ACM certificate
- **Firehose-Ready**: HEC configured for AWS Kinesis Firehose data ingestion
- **Spot Instance Support**: 60-70% cost savings with capacity-optimized spot instances
- **Elastic IP**: Public IP for CloudFront origin connectivity
- **Access**: SSM Session Manager with port forwarding for Splunk web UI
- **Monitoring**: CloudWatch Logs, cost alarms at $5/$10/$20 thresholds
- **Security**: CloudFront prefix list restricts HEC access, custom origin header validation

## How It Works

### Architecture Overview

```
AWS Kinesis Firehose → CloudFront (HTTPS) → EC2 Instance (HTTP:8088) → Splunk HEC
                            ↓
                    splunk.bittikens.com
                    (ACM Certificate)
```

**Data Flow:**
1. Kinesis Firehose sends events to `https://splunk.bittikens.com/services/collector/event`
2. CloudFront validates custom origin header (`X-Origin-Verify`)
3. CloudFront forwards to EC2 instance via HTTP on port 8088
4. Splunk HEC ingests events into the `main` index
5. Failed events backed up to S3 (Firehose configuration)

**Security Model:**
- **Client → CloudFront**: HTTPS with ACM certificate
- **CloudFront → Origin**: HTTP (Splunk uses self-signed cert, CloudFront can't validate)
- **Security Group**: Port 8088 only accessible from CloudFront prefix list
- **Origin Header**: Random secret prevents direct access without CloudFront
- **No Public Access**: SSM Session Manager for shell access (no SSH)

### Component Details

**EC2 Instance:**
- Spot instance (m5.xlarge) with capacity-optimized strategy
- Amazon Linux 2 with automatic architecture detection
- 50GB gp3 EBS volume (delete-on-termination: false for spot interruption recovery)
- Elastic IP for stable public endpoint
- Security group: Ingress from CloudFront prefix list on port 8088, egress for SSM/downloads

**Splunk HEC Configuration:**
- Protocol: HTTP (port 8088)
- SSL: Disabled (CloudFront terminates SSL)
- Indexer Acknowledgement: Enabled (returns ackId for verification)
- Default Index: main
- Token: Stored in Parameter Store as SecureString

**CloudFront Distribution:**
- Custom domain: splunk.bittikens.com
- ACM certificate for HTTPS
- Origin: EC2 public DNS/IP on port 8088
- Origin protocol: HTTP
- Custom header: X-Origin-Verify with random secret
- Caching: Disabled (TTL=0)

**Cost Monitoring:**
- CloudWatch billing alarms at $5, $10, $20
- SNS email notifications
- Resource tagging for cost allocation

## Prerequisites

This project requires the [splunk-s3-installer](https://github.com/stephenabbot/splunk-s3-installer) project to be deployed first. The splunk-s3-installer manages the Splunk installation package in S3 and publishes the installer URL to Parameter Store at `/splunk-s3-installer/installer-url`.

**Required Tools:**
- OpenTofu (or Terraform)
- AWS CLI
- jq
- Session Manager plugin for AWS CLI

**AWS Resources:**
- Default VPC in us-east-1
- Route53 hosted zone for bittikens.com
- terraform-aws-cfn-foundation (S3 backend, DynamoDB locking)
- terraform-aws-deployment-roles (optional, for secure deployments)

## Quick Start

1. **Prerequisites**: Ensure splunk-s3-installer is deployed
2. **Deploy Splunk**: `./scripts/deploy.sh`
3. **Verify Installation**: `./scripts/verify-installation.sh` (wait 5-10 minutes)
4. **Setup CloudFront**: `./scripts/setup-cloudfront.sh`
5. **Test HEC**: `./scripts/test-splunk-hec.sh`
6. **Connect to UI**: Use SSM port forwarding (see below)
7. **Destroy**: `./scripts/destroy-cloudfront.sh && ./scripts/destroy.sh` when finished

### Connecting to Splunk Web UI

```bash
# Get instance ID
INSTANCE_ID=$(aws ssm get-parameter --name /ephemeral-splunk/instance-id --query Parameter.Value --output text)

# Start port forwarding
aws ssm start-session --target $INSTANCE_ID \
  --document-name AWS-StartPortForwardingSession \
  --parameters 'portNumber=8000,localPortNumber=8000'

# Open browser to http://localhost:8000
# Login: admin / changeme
```

### Sending Data from Kinesis Firehose

**Firehose Configuration:**
```
Destination: Splunk
Splunk endpoint: https://splunk.bittikens.com/services/collector/event
Authentication token: (retrieve from Parameter Store: /ephemeral-splunk/hec-token)

Custom HTTP Headers:
  X-Origin-Verify: (retrieve from Parameter Store: /ephemeral-splunk/origin-secret)

S3 Backup: Enabled (for failed events)
```

**Retrieve Configuration Values:**
```bash
# HEC Token
aws ssm get-parameter --name /ephemeral-splunk/hec-token --with-decryption --query Parameter.Value --output text

# Origin Secret
aws ssm get-parameter --name /ephemeral-splunk/origin-secret --with-decryption --query Parameter.Value --output text

# CloudFront Endpoint
aws ssm get-parameter --name /ephemeral-splunk/cloudfront-endpoint --query Parameter.Value --output text
```

## Scripts Reference

### Deployment Scripts

**`scripts/deploy.sh`**
- Deploys complete Splunk infrastructure (EC2, EIP, security group, CloudWatch, SNS)
- Validates splunk-s3-installer availability
- Assumes deployment role if available
- Configures OpenTofu backend from foundation parameters
- Stores outputs in Parameter Store
- **Duration**: ~5 minutes (infrastructure) + 5-10 minutes (Splunk installation)

**`scripts/destroy.sh`**
- Destroys all Splunk infrastructure
- Cleans up orphaned EBS volumes
- Removes Parameter Store entries
- **Warning**: Permanently deletes all data
- **Duration**: ~2-3 minutes

### CloudFront Scripts

**`scripts/setup-cloudfront.sh`**
- Creates CloudFront distribution with ACM certificate
- Configures Route53 A record for splunk.bittikens.com
- Generates and stores origin secret header
- Verifies HEC token exists (created during Splunk installation)
- Polls for CloudFront deployment completion
- Stores distribution ID and endpoint in Parameter Store
- **Prerequisites**: Splunk instance must be running with HEC configured
- **Duration**: ~4-5 minutes

**`scripts/destroy-cloudfront.sh`**
- Destroys CloudFront distribution, ACM certificate, Route53 records
- Removes CloudFront-related Parameter Store entries
- Cleans up local Terraform state directory
- **Duration**: ~4-5 minutes (CloudFront deletion is slow)

### Management Scripts

**`scripts/start-instance.sh`**
- Starts stopped EC2 instance
- Waits for instance to be running
- Verifies SSM agent connectivity
- Checks Splunk service status
- **Use Case**: Resume work after stopping instance to save costs

**`scripts/stop-instance.sh`**
- Gracefully stops Splunk service
- Stops EC2 instance
- **Cost Savings**: No compute charges while stopped (EBS charges still apply)
- **Use Case**: Pause work without destroying infrastructure

**`scripts/verify-installation.sh`**
- Checks EC2 instance state
- Verifies CloudWatch Log Group exists
- Checks SNS topic for cost alarms
- Verifies Splunk installation completion (if instance running)
- Checks HEC token configuration
- Provides connection instructions
- **Use Case**: Troubleshooting, status checks

**`scripts/test-splunk-hec.sh`**
- Retrieves HEC token and CloudFront endpoint from Parameter Store
- Generates unique channel GUID for acknowledgment workflow
- Sends 3 test events to Splunk via CloudFront with channel ID
- Captures ackId from each response
- Queries `/services/collector/ack` endpoint to verify indexing
- Reports indexing status for all events
- **Use Case**: Verify end-to-end connectivity and acknowledgment workflow

**`scripts/enable-hec-acknowledgment.sh`**
- Enables indexer acknowledgment on running Splunk instance
- Modifies inputs.conf to set useACK = 1
- Restarts Splunk to apply changes
- Verifies Splunk is running after restart
- **Use Case**: Enable acknowledgment without redeploying infrastructure

### Utility Scripts

**`scripts/verify-prerequisites.sh`**
- Checks required tools (tofu, aws, jq)
- Verifies git repository state (clean, up-to-date)
- Validates AWS credentials
- Checks foundation infrastructure availability
- Verifies default VPC exists
- **Called by**: deploy.sh, destroy.sh

**`scripts/list-deployed-resources.sh`**
- Lists all deployed resources and their states
- Shows Parameter Store values
- Displays access commands
- Provides HEC endpoint information
- **Use Case**: Quick reference for deployed infrastructure

**`scripts/get-splunk-installer.sh`**
- Downloads Splunk installer from S3
- Installs Splunk Enterprise
- Configures HEC with HTTP (no SSL)
- Creates HEC token for Firehose
- Stores HEC token in Parameter Store
- **Execution**: Runs automatically via EC2 user data
- **Logs**: /var/log/splunk-installer.log and CloudWatch Logs

## Cost Model

**Idle Costs**: $0 (no infrastructure when destroyed)

**Active Costs (per hour):**
- EC2 spot instance (m5.xlarge): ~$0.05/hour (60-70% savings vs on-demand)
- EBS (50GB gp3): ~$0.007/hour ($5/month prorated)
- CloudFront: $0.085/GB data transfer + $0.01/10,000 requests
- **Total**: ~$0.06/hour + data transfer

**Typical Usage:**
- 3-hour session: ~$0.20 + data transfer
- Weekly 3-hour sessions: ~$10/year + data transfer
- Stopped instance (no compute): ~$5/month (EBS only)

**Cost Optimization:**
- Destroy infrastructure when not in use ($0 idle cost)
- Use spot instances (60-70% savings)
- Stop instance between sessions (saves compute, keeps data)
- Monitor with CloudWatch billing alarms

## Configuration

**Environment Variables** (`config.env`):
```bash
AWS_REGION=us-east-1
DEPLOYMENT_ENVIRONMENT=prd
TAG_OWNER="Platform Team"
EC2_INSTANCE_TYPE=m5.xlarge
EBS_VOLUME_SIZE=50
COST_ALARM_EMAIL=abbotnh@yahoo.com
COST_THRESHOLDS="5,10,20"
SPLUNK_S3_INSTALLER_PARAM=/splunk-s3-installer/installer-url
```

**Parameter Store Values** (created by scripts):
- `/ephemeral-splunk/instance-id` - EC2 instance ID
- `/ephemeral-splunk/hec-token` - Splunk HEC authentication token (SecureString)
- `/ephemeral-splunk/origin-secret` - CloudFront origin verification header (SecureString)
- `/ephemeral-splunk/cloudfront-distribution-id` - CloudFront distribution ID
- `/ephemeral-splunk/cloudfront-endpoint` - Public HEC endpoint URL

## Manual Steps

After deployment completes:

1. Wait 5-10 minutes for Splunk installation
2. Run `./scripts/setup-cloudfront.sh` to configure CloudFront
3. Test with `./scripts/test-splunk-hec.sh`
4. Access Splunk web UI via SSM port forwarding
5. Login with admin/changeme
6. Apply Splunk license manually through web interface
7. Configure Kinesis Firehose with HEC endpoint and token

## Troubleshooting

**Splunk installation failed:**
- Check CloudWatch Logs: `/ec2/ephemeral-splunk`
- SSH via SSM: `aws ssm start-session --target <instance-id>`
- Check logs: `/var/log/user-data.log` and `/var/log/splunk-installer.log`

**CloudFront 502 errors:**
- Verify instance is running: `./scripts/verify-installation.sh`
- Check security group allows CloudFront prefix list
- Verify HEC is listening: `sudo netstat -tlnp | grep 8088`

**HEC token invalid:**
- Token may have changed after Splunk restart
- Retrieve current token: `./scripts/verify-installation.sh`
- Update Parameter Store if needed

**Spot instance interrupted:**
- Instance stops (not terminates) on interruption
- EBS volume preserved with all data
- Restart with `./scripts/start-instance.sh`

## Integration

- Uses terraform-aws-cfn-foundation for backend configuration
- Integrates with terraform-aws-deployment-roles for secure deployments
- Follows established project patterns for consistency
- Stores outputs in SSM Parameter Store for consuming projects
- Compatible with AWS Kinesis Firehose for data ingestion

## Development

The user data script includes comprehensive logging to CloudWatch Logs. On installation failures, the instance remains running for debugging via SSM Session Manager. Check `/var/log/user-data.log` and `/var/log/splunk-installer.log` for installation details.

For planned changes and improvements, see `TODO.md`.

## Documentation

### Scripts Reference

All scripts are located in the `scripts/` directory:

- **[deploy.sh](scripts/deploy.sh)** - Deploy complete Splunk infrastructure
- **[destroy.sh](scripts/destroy.sh)** - Destroy all Splunk infrastructure
- **[setup-cloudfront.sh](scripts/setup-cloudfront.sh)** - Create CloudFront distribution
- **[destroy-cloudfront.sh](scripts/destroy-cloudfront.sh)** - Destroy CloudFront distribution
- **[start-instance.sh](scripts/start-instance.sh)** - Start stopped EC2 instance
- **[stop-instance.sh](scripts/stop-instance.sh)** - Stop running EC2 instance
- **[verify-installation.sh](scripts/verify-installation.sh)** - Check deployment status
- **[test-splunk-hec.sh](scripts/test-splunk-hec.sh)** - Test HEC with acknowledgment workflow
- **[enable-hec-acknowledgment.sh](scripts/enable-hec-acknowledgment.sh)** - Enable acknowledgment on running instance
- **[list-deployed-resources.sh](scripts/list-deployed-resources.sh)** - List all deployed resources
- **[verify-prerequisites.sh](scripts/verify-prerequisites.sh)** - Verify required tools and AWS resources
- **[get-splunk-installer.sh](scripts/get-splunk-installer.sh)** - Download and install Splunk (runs via user data)

### Additional Documentation

Documentation files are located in the `docs/` directory:

- **[splunk_ack_details.md](docs/splunk_ack_details.md)** - Complete guide to Splunk HEC indexer acknowledgment including sending events with channel IDs, querying ack status, and best practices
- **[hec_acknowledgment_implementation.md](docs/hec_acknowledgment_implementation.md)** - Implementation summary of acknowledgment changes made to this project, including test results and configuration details
- **[get_blocked_url.md](docs/get_blocked_url.md)** - Guide for retrieving content from browser-protected URLs using curl with User-Agent spoofing
- **[cw_log_data_to_splunk.md](docs/cw_log_data_to_splunk.md)** - Guide for sending CloudWatch Logs data to Splunk via Kinesis Firehose

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

© 2025 Stephen Abbot - MIT License
