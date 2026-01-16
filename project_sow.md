# Ephemeral Splunk Infrastructure - Project Statement of Work

## Project Overview

This project provides automated infrastructure for deploying ephemeral Splunk Enterprise instances on AWS EC2 using a true fresh install approach. The infrastructure enables complete deploy/destroy cycles for Splunk environments used in proof-of-concept work, data analysis, and development tasks with zero idle costs when not in use.

## Architecture Decisions

### True Fresh Install Approach

**Decision**: Deploy complete infrastructure stack with fresh Splunk installation for each usage session, followed by complete teardown when finished.

**Reasoning**: 
- Zero idle costs when no infrastructure exists
- Always provides latest Splunk version and security patches
- Eliminates state management complexity entirely
- Simplifies automation by avoiding persistent storage
- Aligns with ephemeral use case where data persistence is not required
- Reduces operational complexity to deploy/destroy cycles

**Trade-offs**: 
- 5-10 minute deployment time for fresh installation
- Manual license application required for each deployment
- Complete loss of indexed data when infrastructure is destroyed
- No state preservation between usage sessions

### Manual License Management

**Decision**: Require manual license application through Splunk web interface after each deployment.

**Reasoning**:
- License automation is complex and error-prone
- Fresh install approach requires license application anyway
- Avoids storing license files in Parameter Store
- Maintains clear licensing compliance
- Reduces automation complexity significantly

**Trade-offs**:
- Manual step required after each deployment
- Cannot achieve fully automated deployment

### Network Access Pattern

**Decision**: Deploy EC2 instances in default VPC with SSM Session Manager access and port forwarding for web UI.

**Reasoning**:
- Eliminates need for VPN or bastion host infrastructure
- Provides secure shell access without SSH key management
- Enables secure web UI access through SSM port forwarding
- Uses existing default VPC infrastructure
- Minimizes network complexity and costs

**Trade-offs**:
- Requires AWS CLI and Session Manager plugin for access
- Port forwarding setup required for each session
- No direct internet access to Splunk interface

### Infrastructure as Code Tool Selection

**Decision**: Use OpenTofu for infrastructure deployment rather than CloudFormation.

**Reasoning**:
- Consistency with existing project patterns (static-website-infrastructure, deployment-roles)
- Superior Lambda@Edge and CloudFront integration for future enhancements
- Better Lambda function deployment capabilities (inline code, zip packaging)
- Established patterns for backend configuration, deployment roles, and tagging
- More flexible for complex multi-service orchestration

**Trade-offs**:
- Requires OpenTofu installation and familiarity
- Less native AWS integration than CloudFormation

### Single Environment Design

**Decision**: Support only production environment initially, using projects/prd/ structure for consistency.

**Reasoning**:
- Ephemeral nature reduces need for multiple environments
- Maintains consistency with existing project patterns
- Allows future expansion to multiple environments if needed
- Simplifies initial implementation and testing

**Trade-offs**:
- Cannot test different configurations simultaneously
- All usage shares same environment designation

## Implementation Architecture

### Project Structure

```
ephemeral-splunk/
├── config.env              # Non-sensitive configuration defaults
├── scripts/
│   ├── deploy.sh          # Create complete stack with fresh Splunk
│   ├── destroy.sh         # Destroy complete stack
│   ├── start-instance.sh  # Start stopped instance
│   ├── stop-instance.sh   # Stop running instance
│   ├── verify-installation.sh  # Check Splunk status
│   └── verify-prerequisites.sh # Validate deployment requirements
├── projects/
│   └── prd/
│       └── splunk.tf      # Production environment configuration
├── modules/
│   ├── splunk-instance/   # EC2 instance with user data automation
│   └── standard-tags/     # Consistent resource tagging
├── templates/
│   └── user-data.sh       # Splunk installation and startup script
└── main.tf               # Root Terraform configuration
```

### Infrastructure Components

**Core Resources**:
- EC2 instance (t3.large, x86_64, Amazon Linux)
- EBS volume (100GB gp3, delete-on-termination enabled)
- Security group (outbound HTTPS for SSM and Splunk downloads)
- IAM instance profile (SSM Session Manager and CloudWatch Logs permissions)
- CloudWatch Log Group (`/ec2/ephemeral-splunk`)
- CloudWatch Cost Alarms ($5, $10, $20 thresholds)
- SNS Topic (`ephemeral-splunk-cost-alarm`) with email subscription

**Network Configuration**:
- Default VPC deployment
- Public subnet for internet access during installation
- Security group allowing outbound HTTPS (443) and HTTP (80)
- No inbound rules required (SSM uses outbound connections only)
- No load balancer or additional networking components

**Access Methods**:
- SSM Session Manager for shell access
- SSM port forwarding for Splunk web UI (localhost:8000)
- No direct internet access to Splunk interface

**Monitoring and Alerting**:
- CloudWatch Logs integration for user data script output
- Cost monitoring with email alerts at $5, $10, and $20 spending thresholds
- Instance state monitoring through EC2 API calls

### Configuration Management

**Environment Variables (config.env)**:
```bash
AWS_REGION=us-east-1
DEPLOYMENT_ENVIRONMENT=prd
TAG_OWNER="Platform Team"
EC2_INSTANCE_TYPE=t3.large
EBS_VOLUME_SIZE=100
AMI_ARCHITECTURE=x86_64
AMI_OS=amazon-linux
USE_DEFAULT_VPC=true
ENABLE_SSM_ACCESS=true
```

**SSM Parameter Store Integration**:
- Store deployment outputs for consuming projects
- Retrieve backend configuration from foundation
- No sensitive data storage (license handled manually)

### Deployment Role Integration

**Authentication Pattern**:
- Automatic project name detection from git remote URL
- Deployment role lookup at `/deployment-roles/{project-name}/role-arn`
- Role assumption for secure deployments
- Fallback to local credentials for development

**Required Permissions**:
- EC2 instance management (create, start, stop, terminate)
- VPC and security group management
- IAM instance profile creation
- SSM Parameter Store read/write
- S3 backend access for Terraform state

## Operational Workflows

### Complete Deployment Lifecycle

**Fresh Deployment (`scripts/deploy.sh`)**:
1. Verify prerequisites and assume deployment role
2. Configure OpenTofu backend from foundation parameters
3. Deploy complete infrastructure stack including EC2, CloudWatch, SNS
4. Wait for user data script completion via CloudWatch Logs
5. Store instance details in SSM Parameter Store
6. Output connection instructions for SSM access

**Instance Management During Session**:
- `scripts/start-instance.sh` - Start stopped instance, verify Splunk status
- `scripts/stop-instance.sh` - Stop running instance, preserve for session
- `scripts/verify-installation.sh` - Check infrastructure and Splunk service status
- `scripts/destroy.sh` - Complete infrastructure teardown and cleanup

**Complete Teardown (`scripts/destroy.sh`)**:
1. Terminate EC2 instances (EBS volumes auto-delete)
2. Remove CloudWatch Log Groups and alarms
3. Delete SNS topic and subscriptions
4. Clean up SSM Parameter Store entries
5. Destroy all OpenTofu-managed resources

**User Data Script Development Pattern**:
- Comprehensive logging to `/var/log/user-data.log`
- CloudWatch Logs streaming for remote inspection
- Exit on first error with detailed error context
- Status signaling via SSM Parameter Store or CloudWatch
- On failure: preserve instance for debugging via SSM Session Manager

### Cost Optimization Strategy

**True Ephemeral Costs**:
- Idle costs: $0 (no infrastructure exists when not in use)
- Active session costs: EC2 instance hours + EBS storage during session
- t3.large instance: ~$0.08/hour
- 100GB gp3 EBS: ~$8/month prorated for session duration
- Typical 3-hour session: ~$0.25 total cost

**Cost Monitoring**:
- CloudWatch billing alarms at $5, $10, and $20 thresholds
- SNS email notifications to `abbotnh@yahoo.com`
- Automatic cost tracking through resource tagging
- No persistent infrastructure costs between sessions

**Annual Cost Projection**:
- Weekly 3-hour sessions: ~$13/year
- Monthly 3-hour sessions: ~$3/year
- Compared to persistent Splunk: $200-400/year savings

## Integration Patterns

### Foundation Dependencies

**Required Infrastructure**:
- terraform-aws-cfn-foundation for S3 backend and DynamoDB locking
- terraform-aws-deployment-roles for secure deployment authentication
- Existing AWS account with appropriate service quotas

**Backend Configuration**:
- S3 state bucket from `/terraform/foundation/s3-state-bucket`
- DynamoDB lock table from `/terraform/foundation/dynamodb-lock-table`
- State key pattern: `ephemeral-splunk/{github-repo}/terraform.tfstate`

### GitHub Actions Integration

**Workflow Triggers**:
- Manual workflow dispatch for ad-hoc deployments
- Scheduled workflows for predictable usage patterns
- Pull request workflows for testing (future enhancement)

**Security Model**:
- OIDC authentication to deployment roles
- No long-lived AWS credentials in GitHub secrets
- Deployment role permissions scoped to project resources only

## Implementation Phases

### Phase 1: Core Infrastructure (Weeks 1-2)

**Deliverables**:
- Complete OpenTofu configuration for EC2 deployment
- CloudWatch Log Group and cost monitoring alarms
- SNS topic with email subscription for cost alerts
- User data script for automated Splunk installation with comprehensive logging
- Basic deploy/destroy scripts with error handling
- Local development and testing validation

**Success Criteria**:
- Fresh Splunk deployment completes in <10 minutes
- SSM Session Manager access works correctly
- Splunk web interface accessible via port forwarding
- CloudWatch Logs capture user data script output
- Cost alarms trigger correctly at defined thresholds
- Manual license application process documented and reliable

### Phase 2: Operational Scripts (Week 3)

**Deliverables**:
- Enhanced start/stop scripts for session management
- Comprehensive verify-installation script checking infrastructure and Splunk status
- Prerequisites verification script
- Error handling and recovery procedures
- Documentation for all operational procedures

**Success Criteria**:
- All scripts handle error conditions gracefully
- Clear status reporting for all operations
- Reliable instance state detection and management
- User data script failures preserve instance for debugging
- CloudWatch Logs provide sufficient debugging information

### Phase 3: GitHub Actions Integration (Week 4)

**Deliverables**:
- Workflow files for deploy/start/stop/destroy operations
- Integration with deployment roles via OIDC
- Workflow documentation and usage examples
- Manual approval gates for destructive operations

**Success Criteria**:
- Remote deployment works without local AWS credentials
- Workflows integrate with existing OIDC patterns
- Cost monitoring works in automated deployments
- Manual approval prevents accidental resource destruction

## Risk Assessment

### Technical Risks

**Splunk Installation Reliability**:
- Risk: User data script failures during Splunk installation with no retry mechanism
- Mitigation: Comprehensive logging, CloudWatch integration, preserve failed instances for debugging
- Impact: High - requires complete redeployment on failure, but debugging capability reduces resolution time

**Splunk Download Automation**:
- Risk: Non-static download URLs requiring page scraping may become unreliable
- Mitigation: Implement robust URL extraction with fallback mechanisms, version pinning options
- Impact: Medium - affects deployment reliability but has workaround paths

**Cost Control**:
- Risk: Forgotten running instances accumulating unexpected charges
- Mitigation: CloudWatch billing alarms, automated notifications, clear operational procedures
- Impact: Low - costs are bounded and monitored, but requires operational discipline

### Operational Risks

**Cost Overruns**:
- Risk: Forgotten running instances accumulating charges
- Mitigation: CloudWatch alarms, scheduled stop workflows, cost monitoring
- Impact: Low - t3.large costs are predictable and bounded

**Access Management**:
- Risk: Loss of access to running instances
- Mitigation: Multiple access methods, documented recovery procedures
- Impact: Medium - may require instance restart to regain access

### Compliance Risks

**Splunk Licensing**:
- Risk: Inadvertent license violations through automation
- Mitigation: Manual license process, clear documentation, compliance review
- Impact: High - could affect Splunk licensing relationship

## Success Criteria

### Functional Requirements

**Deployment Success**:
- Fresh Splunk deployment completes reliably in <10 minutes
- All operational scripts execute without errors
- SSM access and port forwarding work consistently
- Manual license application process is documented and reliable
- CloudWatch Logs provide comprehensive debugging information
- Cost monitoring and alerting function correctly

**Cost Efficiency**:
- Idle costs remain at $0 when no infrastructure is deployed
- Active usage costs are predictable and bounded
- Cost alarms trigger appropriately at defined thresholds
- No unexpected charges from forgotten resources

**Operational Reliability**:
- Scripts handle error conditions gracefully with clear error messages
- Infrastructure state detection works reliably
- User data script failures preserve instances for debugging
- Integration with existing deployment patterns works seamlessly

### Non-Functional Requirements

**Maintainability**:
- Code follows established patterns from other projects
- Documentation enables new team members to understand and modify
- Integration points use loose coupling through SSM Parameter Store

**Security**:
- No direct internet access to Splunk interface
- All access requires AWS IAM authentication
- No long-lived credentials stored in code or configuration

**Scalability**:
- Architecture supports multiple environments if needed
- Patterns can be replicated for additional use cases
- No hard-coded limitations preventing expansion

## Areas of Concern

### Implementation Unknowns

**User Data Script Reliability**:
- Splunk installation timing varies with network conditions and AWS service performance
- Installation verification methods need validation across different failure scenarios
- CloudWatch Logs streaming timing and reliability during instance startup
- Error recovery procedures when user data scripts fail partially

**Splunk Download Automation**:
- Reliability of download page scraping for latest version URLs
- Handling of Splunk website changes that break URL extraction
- Network timeout and retry strategies for large installer downloads
- Fallback mechanisms when automated download fails

### Operational Considerations

**Manual License Step Impact**:
- User experience workflow from deployment completion to licensed Splunk access
- Documentation clarity for license application process across different user skill levels
- Time required for license application and potential user errors
- Integration of manual step into overall deployment workflow

**Session Management**:
- Reliable detection of EC2 instance states and Splunk service status
- Handling of partial failure scenarios during start/stop operations
- Recovery procedures when instances become unresponsive
- SSM Session Manager reliability for extended usage sessions

### Technical Validation Requirements

**CloudWatch Integration**:
- Log streaming performance and reliability during user data execution
- Cost alarm accuracy and notification delivery timing
- SNS topic subscription management and email delivery reliability
- Log retention and cleanup procedures

**Security Group Configuration**:
- Validation that outbound-only rules provide sufficient access for SSM and Splunk downloads
- Testing of port forwarding through restrictive security groups
- Verification that no inbound access is possible while maintaining functionality

This project statement of work provides the foundation for implementation while acknowledging areas requiring discovery and validation during development. The approach prioritizes simplicity and reliability over feature completeness, enabling rapid deployment of functional Splunk environments for ephemeral use cases.
