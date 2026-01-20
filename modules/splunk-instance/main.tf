# Get default VPC
data "aws_vpc" "default" {
  default = true
}

# Get default subnet
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Detect architecture from instance type
locals {
  is_arm = can(regex("^(a1|t4g|c6g|c7g|m6g|m7g|r6g|r7g|g5g|im4gn|is4gen|x2gd)", var.instance_type))
  architecture = local.is_arm ? "arm64" : "x86_64"
}

# Get latest Amazon Linux 2 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-${local.architecture}-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# CloudWatch Log Group for user data logs
resource "aws_cloudwatch_log_group" "splunk_logs" {
  name              = "/ec2/ephemeral-splunk"
  retention_in_days = 7
  tags              = var.tags
}

# SNS Topic for cost alarms
resource "aws_sns_topic" "cost_alarms" {
  name = "ephemeral-splunk-cost-alarm"
  tags = var.tags
}

# SNS Topic Subscription
resource "aws_sns_topic_subscription" "cost_alarm_email" {
  topic_arn = aws_sns_topic.cost_alarms.arn
  protocol  = "email"
  endpoint  = var.cost_alarm_email
}

# CloudWatch Billing Alarms
resource "aws_cloudwatch_metric_alarm" "cost_alarm" {
  count = length(var.cost_thresholds)

  alarm_name          = "ephemeral-splunk-cost-${var.cost_thresholds[count.index]}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = "86400"
  statistic           = "Maximum"
  threshold           = var.cost_thresholds[count.index]
  alarm_description   = "This metric monitors AWS estimated charges for ephemeral-splunk"
  alarm_actions       = [aws_sns_topic.cost_alarms.arn]

  dimensions = {
    Currency = "USD"
  }

  tags = var.tags
}

# IAM Role for EC2 instance
resource "aws_iam_role" "splunk_instance_role" {
  name = "ephemeral-splunk-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

# IAM Policy for CloudWatch Logs and SSM
resource "aws_iam_role_policy" "splunk_instance_policy" {
  name = "ephemeral-splunk-instance-policy"
  role = aws_iam_role.splunk_instance_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "${aws_cloudwatch_log_group.splunk_logs.arn}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:UpdateInstanceInformation",
          "ssm:SendCommand",
          "ssm:ListCommands",
          "ssm:ListCommandInvocations",
          "ssm:DescribeInstanceInformation",
          "ssm:GetCommandInvocation",
          "ssm:DescribeInstanceAssociationsStatus",
          "ssm:DescribeEffectiveInstanceAssociations",
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2messages:AcknowledgeMessage",
          "ec2messages:DeleteMessage",
          "ec2messages:FailMessage",
          "ec2messages:GetEndpoint",
          "ec2messages:GetMessages",
          "ec2messages:SendReply"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "arn:aws:s3:::${var.splunk_s3_bucket}/*"
      }
    ]
  })
}

# Attach AWS managed policy for SSM
resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  role       = aws_iam_role.splunk_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance Profile
resource "aws_iam_instance_profile" "splunk_instance_profile" {
  name = "ephemeral-splunk-instance-profile"
  role = aws_iam_role.splunk_instance_role.name
  tags = var.tags
}

# Get CloudFront prefix list for ingress rules
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# Security Group
resource "aws_security_group" "splunk_instance_sg" {
  name_prefix = "ephemeral-splunk-"
  vpc_id      = data.aws_vpc.default.id
  description = "Security group for ephemeral Splunk instance"

  # Inbound rule for CloudFront to HEC
  ingress {
    from_port       = 8088
    to_port         = 8088
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
    description     = "Allow CloudFront to Splunk HEC"
  }

  # Outbound rules for SSM, package downloads, and Splunk downloads
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS for SSM and downloads"
  }

  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP for package downloads"
  }

  tags = merge(var.tags, {
    Name = "ephemeral-splunk-sg"
  })
}

# SSM Parameter for Splunk installer script
resource "aws_ssm_parameter" "splunk_installer_script" {
  name  = "/ephemeral-splunk/get-splunk-installer"
  type  = "String"
  tier  = "Advanced"
  value = file("${path.module}/../../scripts/get-splunk-installer.sh")
  
  description = "Splunk Enterprise installer utility script"
  tags        = var.tags
}

# User Data Script
locals {
  user_data = base64encode(templatefile("${path.module}/../../templates/user-data.sh", {
    log_group_name = aws_cloudwatch_log_group.splunk_logs.name
    aws_region     = data.aws_region.current.name
  }))
}

# EC2 Instance
resource "aws_instance" "splunk_instance" {
  ami                     = data.aws_ami.amazon_linux.id
  instance_type           = var.instance_type
  subnet_id               = data.aws_subnets.default.ids[0]
  vpc_security_group_ids  = [aws_security_group.splunk_instance_sg.id]
  iam_instance_profile    = aws_iam_instance_profile.splunk_instance_profile.name
  user_data               = local.user_data

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.volume_size
    delete_on_termination = false
    encrypted             = true
  }

  tags = merge(var.tags, {
    Name = "ephemeral-splunk-${var.environment}"
  })

  lifecycle {
    create_before_destroy = false
  }
}

# Elastic IP for CloudFront origin
resource "aws_eip" "splunk_instance" {
  domain = "vpc"
  tags = merge(var.tags, {
    Name = "ephemeral-splunk-eip-${var.environment}"
  })
}

# Associate EIP with instance
resource "aws_eip_association" "splunk_instance" {
  instance_id   = aws_instance.splunk_instance.id
  allocation_id = aws_eip.splunk_instance.id
}

# Get current AWS region
data "aws_region" "current" {}
