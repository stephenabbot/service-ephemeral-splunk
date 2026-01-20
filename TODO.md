# TODO: Codify Manual CloudFront/HEC Configuration Changes

## Overview
The following manual changes were made to get CloudFront → Splunk HEC working. These need to be codified in the deployment scripts so fresh deployments work without manual intervention.

---

## 1. Update `scripts/get-splunk-installer.sh`

**Location:** After Splunk installation completes (after `splunk enable boot-start`)

**Add the following HEC configuration section:**

```bash
# Configure HEC for CloudFront integration
log_message "INFO" "Configuring HTTP Event Collector for CloudFront"

# Enable HEC globally with HTTP (no SSL)
sudo -u splunk /opt/splunk/bin/splunk http-event-collector enable \
    -uri https://localhost:8089 \
    -auth admin:changeme \
    -enable-ssl 0

# Create HEC token for Firehose
HEC_TOKEN=$(sudo -u splunk /opt/splunk/bin/splunk http-event-collector create firehose-token \
    -uri https://localhost:8089 \
    -auth admin:changeme \
    -description "Firehose ingestion token" \
    -disabled 0 \
    -index main \
    -indexes main \
    -use-ack 0 | grep "token=" | cut -d= -f2)

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
```

**Key settings:**
- `enable-ssl 0` - HEC uses HTTP (CloudFront can't validate self-signed certs)
- `use-ack 0` - Disable indexer acknowledgement (Firehose doesn't support channel IDs)
- `index main` - Default index for events
- `indexes main` - Allowed indexes

---

## 2. Update `scripts/setup-cloudfront.sh`

**Remove the following sections (lines ~35-75):**
- HEC enablement via SSM
- HEC token creation via SSM
- Splunk restart via SSM
- Protocol testing via SSM

**Replace with:**
```bash
# Verify HEC token exists (created during installation)
print_status "Verifying HEC token exists..."
HEC_TOKEN=$(aws ssm get-parameter --name /ephemeral-splunk/hec-token --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "")

if [ -z "$HEC_TOKEN" ]; then
    print_error "HEC token not found in Parameter Store"
    print_error "HEC should be configured during Splunk installation"
    exit 1
fi

print_success "HEC token found"

# HEC is configured to use HTTP during installation
ORIGIN_PROTOCOL="http"
print_status "Using HTTP origin protocol (HEC configured without SSL)"
```

**Rationale:**
- HEC is now configured during initial Splunk installation
- No need to restart Splunk or test protocols
- Protocol is always HTTP (configured in installer script)
- Simplifies CloudFront setup to just infrastructure

---

## 3. Verification Steps

After making these changes, test with a fresh deployment:

```bash
# 1. Destroy existing infrastructure
./scripts/destroy.sh
./scripts/destroy-cloudfront.sh

# 2. Deploy fresh
./scripts/deploy.sh

# 3. Wait for Splunk installation (5-10 minutes)
./scripts/verify-installation.sh

# 4. Setup CloudFront
./scripts/setup-cloudfront.sh

# 5. Test sending events
HEC_TOKEN=$(aws ssm get-parameter --name /ephemeral-splunk/hec-token --with-decryption --query Parameter.Value --output text)

curl -X POST https://splunk.bittikens.com/services/collector/event \
  -H "Authorization: Splunk $HEC_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"event": "Test event", "sourcetype": "manual", "index": "main"}'

# Expected response: {"text":"Success","code":0}
```

---

## 4. Update Documentation

**Update `README.md` to reflect:**
- HEC is automatically configured during deployment
- CloudFront uses HTTP to origin (client → CloudFront is still HTTPS)
- No manual HEC configuration required
- Indexer acknowledgement is disabled (Firehose compatibility)

**Add to "Manual Steps" section:**
```markdown
After deployment completes:

1. Wait 5-10 minutes for Splunk installation
2. Run `./scripts/setup-cloudfront.sh` to configure CloudFront distribution
3. HEC is automatically configured with HTTP and ready for Firehose
4. Access Splunk at http://localhost:8000 (via SSM port forwarding)
5. Login with admin/changeme
6. Apply Splunk license manually through web interface
```

---

## 5. Configuration Summary

**HEC Configuration (automatic):**
- Protocol: HTTP (port 8088)
- SSL: Disabled (enable-ssl=0)
- Indexer ACK: Disabled (use-ack=0)
- Default Index: main
- Token: Stored in `/ephemeral-splunk/hec-token` (SecureString)

**CloudFront Configuration:**
- Client → CloudFront: HTTPS (ACM certificate)
- CloudFront → Origin: HTTP (port 8088)
- Origin: Public DNS from EIP
- Custom Header: X-Origin-Verify (random secret)
- Endpoint: https://splunk.bittikens.com/services/collector/event

**Security:**
- Security group allows port 8088 only from CloudFront prefix list
- Origin secret header prevents direct access
- No public access to HEC without CloudFront

---

## 6. Testing Checklist

- [ ] Fresh deployment creates HEC token automatically
- [ ] HEC responds on HTTP port 8088
- [ ] HEC token stored in Parameter Store
- [ ] CloudFront setup script doesn't try to create HEC
- [ ] CloudFront uses HTTP origin protocol
- [ ] Test events succeed via CloudFront endpoint
- [ ] Direct access to public IP:8088 is blocked by security group
- [ ] Documentation updated with new workflow

---

## Notes

- The key issue was CloudFront can't validate Splunk's self-signed certificate
- Solution: Use HTTP between CloudFront and origin (client → CloudFront still HTTPS)
- Indexer acknowledgement requires channel IDs which Firehose doesn't support
- All configuration is now automated in deployment scripts
