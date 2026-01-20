#!/bin/bash
# Minimal user data script for ephemeral Splunk installation
# Downloads and executes the main installer from Parameter Store

# Set up comprehensive logging
exec > >(tee /var/log/user-data.log) 2>&1
set -euxo pipefail

echo "=== Ephemeral Splunk Bootstrap Started at $(date) ==="

# Install required packages
yum update -y
yum install -y amazon-cloudwatch-agent awscli jq curl wget

# Configure CloudWatch agent
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'EOF'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/user-data.log",
            "log_group_name": "${log_group_name}",
            "log_stream_name": "{instance_id}/user-data.log"
          },
          {
            "file_path": "/var/log/splunk-installer.log",
            "log_group_name": "${log_group_name}",
            "log_stream_name": "{instance_id}/splunk-installer.log"
          }
        ]
      }
    }
  }
}
EOF

# Start CloudWatch agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s

echo "CloudWatch agent configured and started"

# Ensure SSM agent is running
echo "=== Starting SSM Agent ==="
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent
systemctl status amazon-ssm-agent

# Wait for SSM agent to register
echo "Waiting for SSM agent registration..."
sleep 30

# Verify SSM agent registration
if systemctl is-active --quiet amazon-ssm-agent; then
  echo "SUCCESS: SSM agent is running"
else
  echo "ERROR: SSM agent failed to start"
  exit 1
fi

# Download and execute Splunk installer script from Parameter Store
echo "=== Downloading Splunk Installer Script ==="
aws ssm get-parameter \
  --name "/ephemeral-splunk/get-splunk-installer" \
  --query 'Parameter.Value' \
  --output text \
  --region ${aws_region} > /tmp/get-splunk-installer.sh

chmod +x /tmp/get-splunk-installer.sh

echo "=== Executing Splunk Installation ==="
if /tmp/get-splunk-installer.sh; then
  echo "SUCCESS: Splunk installation completed"
else
  echo "ERROR: Splunk installation failed"
  exit 1
fi

# Cleanup
rm -f /tmp/get-splunk-installer.sh

echo "=== User Data Script Completed Successfully at $(date) ==="
