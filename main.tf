terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    # Configuration loaded dynamically by deploy script
  }
}

provider "aws" {
  region = var.aws_region
}

# Get current caller identity and region
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Get git remote URL for project identification
data "external" "git_info" {
  program = ["bash", "-c", <<-EOT
    REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
      PROJECT_NAME="$${BASH_REMATCH[2]}"
      REPO_URL="$REMOTE_URL"
      GITHUB_REPO="$${BASH_REMATCH[1]}/$${BASH_REMATCH[2]}"
    else
      PROJECT_NAME="unknown"
      REPO_URL="unknown"
      GITHUB_REPO="unknown/unknown"
    fi
    echo "{\"project_name\":\"$PROJECT_NAME\",\"repository\":\"$REPO_URL\",\"github_repository\":\"$GITHUB_REPO\"}"
  EOT
  ]
}

# Local variables
locals {
  git_project_name = data.external.git_info.result.project_name
  git_repository   = data.external.git_info.result.repository
  git_github_repo  = data.external.git_info.result.github_repository
  
  # Environment configuration
  environment_config = {
    prd = {
      instance_type = var.ec2_instance_type
      volume_size   = var.ebs_volume_size
    }
  }
}

# Standard tags for all resources
module "standard_tags" {
  source = "./modules/standard-tags"

  project       = local.git_project_name
  repository    = local.git_repository
  environment   = var.deployment_environment
  owner         = var.tag_owner
  deployed_by   = data.aws_caller_identity.current.arn
}

# Deploy Splunk instance
module "splunk_instance" {
  source = "./modules/splunk-instance"

  environment         = var.deployment_environment
  instance_type       = local.environment_config[var.deployment_environment].instance_type
  volume_size         = local.environment_config[var.deployment_environment].volume_size
  cost_alarm_email    = var.cost_alarm_email
  cost_thresholds     = var.cost_thresholds
  splunk_s3_bucket    = var.splunk_s3_bucket
  tags                = module.standard_tags.tags
}

# Variables
variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "deployment_environment" {
  description = "Deployment environment"
  type        = string
  default     = "prd"
}

variable "tag_owner" {
  description = "Owner tag for resources"
  type        = string
  default     = "Platform Team"
}

variable "ec2_instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.large"
}

variable "ebs_volume_size" {
  description = "EBS volume size in GB"
  type        = number
  default     = 100
}

variable "cost_alarm_email" {
  description = "Email address for cost alarms"
  type        = string
  default     = "abbotnh@yahoo.com"
}

variable "cost_thresholds" {
  description = "Cost alarm thresholds"
  type        = list(number)
  default     = [5, 10, 20]
}

variable "splunk_s3_bucket" {
  description = "S3 bucket containing Splunk installer"
  type        = string
}

# Outputs
# Store instance ID in Parameter Store for easy retrieval by scripts
resource "aws_ssm_parameter" "instance_id" {
  name  = "/ephemeral-splunk/instance-id"
  type  = "String"
  value = module.splunk_instance.instance_id
  tags  = module.standard_tags.tags
}

output "instance_info" {
  description = "Splunk instance information"
  value = {
    instance_id       = module.splunk_instance.instance_id
    instance_ip       = module.splunk_instance.instance_ip
    log_group_name    = module.splunk_instance.log_group_name
    sns_topic_arn     = module.splunk_instance.sns_topic_arn
  }
}

output "connection_info" {
  description = "Connection instructions"
  value = {
    ssm_command = "aws ssm start-session --target ${module.splunk_instance.instance_id}"
    port_forward_command = "aws ssm start-session --target ${module.splunk_instance.instance_id} --document-name AWS-StartPortForwardingSession --parameters 'portNumber=8000,localPortNumber=8000'"
    splunk_url = "http://localhost:8000"
  }
}

output "git_info" {
  description = "Git repository information"
  value = {
    project_name = local.git_project_name
    repository   = local.git_repository
    github_repo  = local.git_github_repo
  }
}
