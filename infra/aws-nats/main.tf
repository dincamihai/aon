terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Latest Amazon Linux 2023 ARM64 AMI
data "aws_ami" "al2023_arm" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }
  filter {
    name   = "architecture"
    values = ["arm64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  tags = merge(
    {
      Name        = var.name_prefix
      team        = "aon"
      cost-center = "dev"
      managed-by  = "terraform"
    },
    var.tags,
  )
}

# ── Networking ──

resource "aws_vpc" "nats" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${var.name_prefix}-vpc" })
}

resource "aws_subnet" "nats" {
  vpc_id                  = aws_vpc.nats.id
  cidr_block              = var.subnet_cidr
  availability_zone       = "${data.aws_region.current.name}a"
  map_public_ip_on_launch = false
  tags                    = merge(local.tags, { Name = "${var.name_prefix}-subnet" })
}

# Route table (no IGW — private only)
resource "aws_route_table" "nats" {
  vpc_id = aws_vpc.nats.id
  tags   = merge(local.tags, { Name = "${var.name_prefix}-rt" })
}

resource "aws_route_table_association" "nats" {
  subnet_id      = aws_subnet.nats.id
  route_table_id = aws_route_table.nats.id
}

# ── VPC Endpoints for SSM (no NAT gateway needed) ──
# SSM requires three Interface endpoints + one Gateway endpoint (S3 for
# agent bootstrapping). Without these, the instance can't reach SSM at all.

resource "aws_security_group" "ssm_endpoint" {
  name        = "${var.name_prefix}-ssm-endpoint-sg"
  description = "Allow HTTPS from VPC to SSM VPC endpoints"
  vpc_id      = aws_vpc.nats.id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.tags, { Name = "${var.name_prefix}-ssm-endpoint-sg" })
}

locals {
  ssm_services = ["ssm", "ssmmessages", "ec2messages"]
}

resource "aws_vpc_endpoint" "ssm_interface" {
  for_each = toset(local.ssm_services)

  vpc_id              = aws_vpc.nats.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.nats.id]
  security_group_ids  = [aws_security_group.ssm_endpoint.id]
  private_dns_enabled = true
  tags                = merge(local.tags, { Name = "${var.name_prefix}-${each.value}-endpoint" })
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.nats.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.nats.id]
  tags              = merge(local.tags, { Name = "${var.name_prefix}-s3-endpoint" })
}

# ── Security group for EC2 ──
# Zero ingress — SSM tunnels via the SSM endpoints (no inbound SG needed).
resource "aws_security_group" "nats_ec2" {
  name        = "${var.name_prefix}-ec2-sg"
  description = "NATS EC2 — no ingress; SSM tunnels via VPC endpoint"
  vpc_id      = aws_vpc.nats.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.tags, { Name = "${var.name_prefix}-ec2-sg" })
}

# ── IAM role for EC2 (SSM managed instance) ──

resource "aws_iam_role" "nats" {
  name = "${var.name_prefix}-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.nats.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "nats" {
  name = "${var.name_prefix}-ec2-profile"
  role = aws_iam_role.nats.name
  tags = local.tags
}

# ── EBS volume for persistent NATS state ──

resource "aws_ebs_volume" "nats_data" {
  availability_zone = "${data.aws_region.current.name}a"
  size              = var.ebs_size_gb
  type              = "gp3"
  encrypted         = true
  tags              = merge(local.tags, { Name = "${var.name_prefix}-data" })

  lifecycle {
    prevent_destroy = true
  }
}

# ── EC2 instance ──

resource "aws_instance" "nats" {
  ami                    = data.aws_ami.al2023_arm.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.nats.id
  iam_instance_profile   = aws_iam_instance_profile.nats.name
  vpc_security_group_ids = [aws_security_group.nats_ec2.id]
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/user_data.sh", {
    nats_version = var.nats_version
  })

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    encrypted             = true
    delete_on_termination = true
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-server" })

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

resource "aws_volume_attachment" "nats_data" {
  device_name  = "/dev/xvdf"
  volume_id    = aws_ebs_volume.nats_data.id
  instance_id  = aws_instance.nats.id
  force_detach = false
}

# ── CloudWatch log group (7-day retention) ──

resource "aws_cloudwatch_log_group" "nats" {
  name              = "/aon/${var.name_prefix}"
  retention_in_days = 7
  tags              = local.tags
}
