# Ephemeral Splunk Infrastructure

This project provides automated infrastructure for deploying ephemeral Splunk Enterprise instances on AWS EC2 using a true fresh install approach. The infrastructure enables complete deploy/destroy cycles for Splunk environments used in proof-of-concept work, data analysis, and development tasks with zero idle costs when not in use.

## Quick Start

1. **Prerequisites**: Ensure you have OpenTofu, AWS CLI, and jq installed
2. **Deploy**: `./scripts/deploy.sh`
3. **Verify**: `./scripts/verify-installation.sh`
4. **Connect**: Use SSM Session Manager and port forwarding
5. **Destroy**: `./scripts/destroy.sh` when finished

## Architecture

- **True Fresh Install**: Complete deploy/destroy cycles with zero idle costs
- **EC2 Instance**: t3.large with Amazon Linux, 100GB gp3 EBS (delete-on-termination)
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
- **Active**: ~$0.08/hour for t3.large + EBS prorated
- **Typical 3-hour session**: ~$0.25
- **Annual usage (weekly 3-hour sessions)**: ~$13/year

## Manual Steps

After deployment completes:
1. Wait 5-10 minutes for Splunk installation
2. Connect via SSM Session Manager
3. Set up port forwarding: `aws ssm start-session --target INSTANCE_ID --document-name AWS-StartPortForwardingSession --parameters 'portNumber=8000,localPortNumber=8000'`
4. Access Splunk at http://localhost:8000
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
