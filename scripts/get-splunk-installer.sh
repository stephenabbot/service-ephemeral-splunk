#!/bin/bash
# Splunk Enterprise Installer Utility
# This script handles downloading and installing Splunk Enterprise
# Designed to be stored in SSM Parameter Store and executed by user data script

# Redirect all output to log file and console
exec > >(tee -a /var/log/splunk-installer.log) 2>&1
set -euxo pipefail

# Logging function
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    echo "[$timestamp] [$level] $message"
}

log_message "INFO" "Starting Splunk Enterprise installation"

# Function to download Splunk from S3
download_splunk() {
    log_message "INFO" "Fetching S3 installer URL from Parameter Store"
    
    local param_name="/splunk-s3-installer/installer-url"
    download_url=$(aws ssm get-parameter --region us-east-1 --name "$param_name" --query Parameter.Value --output text 2>/dev/null || echo "")
    
    if [ -z "$download_url" ]; then
        log_message "ERROR" "Failed to retrieve installer URL from Parameter Store: $param_name"
        return 1
    fi
    
    log_message "INFO" "S3 installer URL: $download_url"
    return 0
}

# Function to install Splunk
install_splunk() {
    local installer_file="$1"
    
    log_message "INFO" "Installing Splunk from $installer_file"
    
    # Install Splunk RPM
    if ! yum install -y "$installer_file"; then
        log_message "ERROR" "Failed to install Splunk RPM"
        return 1
    fi
    
    # Verify splunk user exists (created by RPM)
    if ! id splunk &>/dev/null; then
        log_message "ERROR" "Splunk user not created by RPM installation"
        return 1
    fi
    
    # Ensure proper ownership
    chown -R splunk:splunk /opt/splunk
    
    # Create user-seed.conf for admin user
    log_message "INFO" "Creating admin user configuration"
    mkdir -p /opt/splunk/etc/system/local
    cat > /opt/splunk/etc/system/local/user-seed.conf << 'EOF'
[user_info]
USERNAME = admin
PASSWORD = changeme
EOF
    chown splunk:splunk /opt/splunk/etc/system/local/user-seed.conf
    
    # Start Splunk
    log_message "INFO" "Starting Splunk for first time"
    if ! sudo -u splunk /opt/splunk/bin/splunk start --accept-license --answer-yes --no-prompt; then
        log_message "ERROR" "Failed to start Splunk"
        return 1
    fi
    
    # Enable boot start
    /opt/splunk/bin/splunk enable boot-start -user splunk --accept-license --answer-yes
    
    # Basic configuration
    sudo -u splunk /opt/splunk/bin/splunk add index test_data -auth admin:changeme
    
    # Configure HEC for CloudFront integration
    log_message "INFO" "Configuring HTTP Event Collector for CloudFront"
    
    # Enable HEC globally with HTTP (no SSL)
    sudo -u splunk /opt/splunk/bin/splunk http-event-collector enable \
        -uri https://localhost:8089 \
        -auth admin:changeme \
        -enable-ssl 0
    
    # Create HEC token with indexer acknowledgment enabled
    HEC_TOKEN=$(sudo -u splunk /opt/splunk/bin/splunk http-event-collector create firehose-token \
        -uri https://localhost:8089 \
        -auth admin:changeme \
        -description "Firehose ingestion token" \
        -disabled 0 \
        -index main \
        -indexes main \
        -use-ack 1 | grep "token=" | cut -d= -f2)
    
    if [ -z "$HEC_TOKEN" ]; then
        log_message "ERROR" "Failed to create HEC token"
        return 1
    fi
    
    log_message "INFO" "HEC token created: ${HEC_TOKEN:0:8}...${HEC_TOKEN: -8}"
    
    # Store HEC token in Parameter Store
    aws ssm put-parameter \
        --region us-east-1 \
        --name /ephemeral-splunk/hec-token \
        --value "$HEC_TOKEN" \
        --type SecureString \
        --overwrite
    
    log_message "INFO" "HEC token stored in Parameter Store"
    
    log_message "INFO" "Splunk installation completed successfully"
    return 0
}

# Main execution
main() {
    cd /tmp
    
    # Get download URL
    if ! download_splunk; then
        log_message "ERROR" "Failed to determine download URL"
        exit 1
    fi
    
    # Download installer
    log_message "INFO" "Downloading Splunk installer from: $download_url"
    
    # Use AWS CLI for S3 URLs, wget for HTTPS URLs
    if [[ "$download_url" =~ ^s3:// ]]; then
        if ! aws s3 cp "$download_url" splunk-installer.rpm --region us-east-1; then
            log_message "ERROR" "Failed to download Splunk installer from S3"
            exit 1
        fi
    else
        if ! wget -O splunk-installer.rpm "$download_url"; then
            log_message "ERROR" "Failed to download Splunk installer"
            exit 1
        fi
    fi
    
    # Verify download
    if [ ! -f splunk-installer.rpm ] || [ ! -s splunk-installer.rpm ]; then
        log_message "ERROR" "Downloaded file is missing or empty"
        exit 1
    fi
    
    # Check if it's actually an RPM file
    if ! file splunk-installer.rpm | grep -q "RPM"; then
        log_message "ERROR" "Downloaded file is not a valid RPM package"
        head -c 500 splunk-installer.rpm | log_message "ERROR" "File content preview: $(cat)"
        exit 1
    fi
    
    log_message "INFO" "Download successful, file size: $(wc -c < splunk-installer.rpm) bytes"
    
    # Install Splunk
    if ! install_splunk splunk-installer.rpm; then
        log_message "ERROR" "Splunk installation failed"
        exit 1
    fi
    
    # Verify installation
    if pgrep -f "splunkd" > /dev/null; then
        log_message "INFO" "SUCCESS: Splunk is running"
        echo "SPLUNK_INSTALLATION_COMPLETE" > /tmp/splunk-install-status
    else
        log_message "ERROR" "Splunk is not running after installation"
        exit 1
    fi
    
    # Cleanup
    rm -f splunk-installer.rpm
    
    log_message "INFO" "Splunk installation process completed"
}

# Execute main function
main "$@"
