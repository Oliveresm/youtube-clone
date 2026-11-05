variable "aws_region" {
  description = "AWS region for the bootstrap stack."
  type        = string
  default     = "us-east-1"
}

variable "budget_email" {
  description = "Email address subscribed to the AWS Budget notifications."
  type        = string
}
