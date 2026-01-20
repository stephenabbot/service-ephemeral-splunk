output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.splunk_instance.id
}

output "instance_ip" {
  description = "EC2 instance public IP"
  value       = aws_eip.splunk_instance.public_ip
}

output "instance_public_dns" {
  description = "EC2 instance public DNS"
  value       = aws_eip.splunk_instance.public_dns
}

output "log_group_name" {
  description = "CloudWatch log group name"
  value       = aws_cloudwatch_log_group.splunk_logs.name
}

output "sns_topic_arn" {
  description = "SNS topic ARN for cost alarms"
  value       = aws_sns_topic.cost_alarms.arn
}
