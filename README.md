# Ephemeral Splunk Infrastructure

This project provides automated infrastructure for deploying ephemeral Splunk Enterprise instances on AWS EC2 using a true fresh install approach. The infrastructure enables complete deploy/destroy cycles for Splunk environments used in proof-of-concept work, data analysis, and development tasks with zero idle costs when not in use.

## Prerequisites

This project requires the [splunk-s3-installer](https://github.com/stephenabbot/splunk-s3-installer) project to be deployed first. The splunk-s3-installer manages the Splunk installation package in S3 and publishes the installer URL to Parameter Store at `/splunk-s3-installer/installer-url`.

## Quick Start

1. **Prerequisites**: Ensure you have OpenTofu, AWS CLI, and jq installed
2. **Deploy**: `./scripts/deploy.sh`
3. **Verify**: `./scripts/verify-installation.sh`
4. **Connect**: Use SSM Session Manager and port forwarding
5. **Destroy**: `./scripts/destroy.sh` when finished
6. **Connect locally** aws ssm start-session --target i-0fdf214380b572370 --document-name AWS-StartPortForwardingSession --parameters 'portNumber=8000,localPortNumber=8000'
7. Open browser to: <http://localhost:8000>

## Architecture

- **True Fresh Install**: Complete deploy/destroy cycles with zero idle costs
- **EC2 Instance**: t3.large with Amazon Linux, 100GB gp3 EBS (delete-on-termination)
- **Spot Instance Support**: Optional capacity-optimized spot instances for 60-70% cost savings
- **Access**: SSM Session Manager with port forwarding for Splunk web UI
- **Monitoring**: CloudWatch Logs, cost alarms at $5/$10/$20 thresholds
- **Security**: No inbound access, outbound HTTPS only for SSM and downloads

## Scripts

- `scripts/deploy.sh` - Deploy complete infrastructure with fresh Splunk installation
- `scripts/verify-installation.sh` - Check infrastructure and Splunk status
- `scripts/start-instance.sh` - Start stopped instance during session
- `scripts/stop-instance.sh` - Stop running instance to save costs
- `scripts/destroy.sh` - Complete infrastructure teardown (zero costs)

## Cost Model

- **Idle**: $0 (no infrastructure when destroyed)
- **Active (on-demand)**: ~$0.08/hour for t3.large + EBS prorated
- **Active (spot)**: ~$0.03/hour for t3.large spot + EBS prorated (60-70% savings)
- **Typical 3-hour session (on-demand)**: ~$0.25
- **Typical 3-hour session (spot)**: ~$0.10
- **Annual usage (weekly 3-hour sessions, on-demand)**: ~$13/year
- **Annual usage (weekly 3-hour sessions, spot)**: ~$5/year

### Spot Instance Configuration

Enable spot instances in `config.env`:
```bash
USE_SPOT_INSTANCES=true
```

**Spot instance features:**
- **Capacity-optimized strategy**: AWS automatically selects pools with lowest interruption risk
- **Persistent requests**: Instance stops (not terminates) on interruption
- **EBS preservation**: Volume persists when spot instance is interrupted
- **No max price**: Defaults to on-demand price cap
- **60-70% cost savings**: Typical savings vs on-demand pricing

**Interruption handling:**
- Instance stops gracefully on spot interruption
- EBS volume preserved with all data intact
- Restart with `./scripts/start-instance.sh` when capacity available
- 2-minute warning before interruption (CloudWatch Events)

## Manual Steps

After deployment completes:

1. Wait 5-10 minutes for Splunk installation
2. Connect via SSM Session Manager
3. Set up port forwarding: `aws ssm start-session --target INSTANCE_ID --document-name AWS-StartPortForwardingSession --parameters 'portNumber=8000,localPortNumber=8000'`
4. Access Splunk at <http://localhost:8000>
5. Login with admin/changeme
6. Apply Splunk license manually through web interface

## Integration

- Uses terraform-aws-cfn-foundation for backend configuration
- Integrates with terraform-aws-deployment-roles for secure deployments
- Follows established project patterns for consistency
- Stores outputs in SSM Parameter Store for consuming projects

## Development

The user data script includes comprehensive logging to CloudWatch Logs. On installation failures, the instance remains running for debugging via SSM Session Manager. Check `/var/log/user-data.log` for installation details.

For more details, see `project_sow.md`.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

© 2025 Stephen Abbot - MIT License
