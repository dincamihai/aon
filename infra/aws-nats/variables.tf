variable "name_prefix" {
  description = "Prefix for all resource names/tags"
  type        = string
  default     = "aon-nats"
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use"
  type        = string
  default     = "aon-dev"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.99.0.0/16"
}

variable "subnet_cidr" {
  description = "Private subnet CIDR block"
  type        = string
  default     = "10.99.1.0/24"
}

variable "instance_type" {
  description = "EC2 instance type — t4g.nano is ARM and ~$3/mo in us-east-1"
  type        = string
  default     = "t4g.nano"
}

variable "ebs_size_gb" {
  description = "EBS volume size (GB) for NATS JetStream + auth state"
  type        = number
  default     = 8
}

variable "nats_version" {
  description = "NATS server version to install"
  type        = string
  default     = "2.10.22"
}

variable "tags" {
  description = "Extra tags to merge on all resources"
  type        = map(string)
  default     = {}
}
