variable "environment" {
  description = "Environment name"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
}

variable "volume_size" {
  description = "EBS volume size in GB"
  type        = number
}

variable "cost_alarm_email" {
  description = "Email address for cost alarms"
  type        = string
}

variable "cost_thresholds" {
  description = "Cost alarm thresholds"
  type        = list(number)
}

variable "splunk_s3_bucket" {
  description = "S3 bucket containing Splunk installer"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
}
