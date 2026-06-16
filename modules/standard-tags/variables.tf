variable "project" {
  description = "Project name from git remote"
  type        = string
}

variable "repository" {
  description = "Full repository URL"
  type        = string
}

variable "environment" {
  description = "Environment (prd, stg, tst, dev)"
  type        = string
}

variable "managed_by" {
  description = "Deployment tool (OpenTofu, CloudFormation, Bash)"
  type        = string
  default     = "OpenTofu"
}

variable "deployed_by" {
  description = "IAM principal ARN that deployed the resources"
  type        = string
}

variable "account_alias" {
  description = "AWS account alias"
  type        = string
}

variable "additional_tags" {
  description = "Additional tags to merge"
  type        = map(string)
  default     = {}
}
