output "instance_id" {
  description = "EC2 instance ID — pass to `aon tunnel up --instance`"
  value       = aws_instance.nats.id
}

output "region" {
  description = "AWS region the instance lives in"
  value       = data.aws_region.current.name
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.nats.id
}

output "subnet_id" {
  description = "Private subnet ID"
  value       = aws_subnet.nats.id
}

output "iam_role_arn" {
  description = "IAM role ARN attached to the EC2 instance"
  value       = aws_iam_role.nats.arn
}

output "aon_tunnel_cmd" {
  description = "Operator convenience: exact `aon tunnel up` invocation for this deployment"
  value       = "aon tunnel up --instance ${aws_instance.nats.id} --region ${data.aws_region.current.name} --profile ${var.aws_profile}"
}
