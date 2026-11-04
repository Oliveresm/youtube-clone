terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "alert_email" {
  type        = string
  description = "Correo para la alarma de la DLQ (SNS pedira confirmar la suscripcion)"
}

# ---------------------------------------------------------------
# 1. Cola principal + DLQ (maxReceiveCount = 3)
# ---------------------------------------------------------------
resource "aws_sqs_queue" "dlq" {
  name                      = "spike5-video-events-dlq"
  message_retention_seconds = 345600
}

resource "aws_sqs_queue" "main" {
  name                       = "spike5-video-events"
  visibility_timeout_seconds = 60
  receive_wait_time_seconds  = 20
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}

# ---------------------------------------------------------------
# 2. Reglas de EventBridge. Una por estado: un input transformer no puede
#    traducir COMPLETE -> TRANSCODE_COMPLETE, asi que el "type" va fijo en cada plantilla.
#    En produccion el source sera "aws.mediaconvert" (aqui no se puede publicar
#    con un source que empiece por "aws.").
# ---------------------------------------------------------------
locals {
  rules = {
    complete = { status = "COMPLETE", type = "TRANSCODE_COMPLETE" }
    error    = { status = "ERROR", type = "TRANSCODE_ERROR" }
  }
}

resource "aws_cloudwatch_event_rule" "job" {
  for_each = local.rules
  name     = "spike5-mediaconvert-${each.key}"
  event_pattern = jsonencode({
    source        = ["spike.mediaconvert"]
    "detail-type" = ["MediaConvert Job State Change"]
    detail = {
      status       = [each.value.status]
      userMetadata = { videoId = [{ exists = true }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "to_sqs" {
  for_each = local.rules
  rule     = aws_cloudwatch_event_rule.job[each.key].name
  arn      = aws_sqs_queue.main.arn

  input_transformer {
    input_paths = {
      videoId = "$.detail.userMetadata.videoId"
      time    = "$.time"
    }
    input_template = "{\"type\":\"${each.value.type}\",\"videoId\":\"<videoId>\",\"occurredAt\":\"<time>\"}"
  }
}

# ---------------------------------------------------------------
# 3. Resource policy: solo estas reglas pueden enviar mensajes a la cola
# ---------------------------------------------------------------
resource "aws_sqs_queue_policy" "main" {
  queue_url = aws_sqs_queue.main.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgeRules"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.main.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = [for r in aws_cloudwatch_event_rule.job : r.arn] }
      }
    }]
  })
}

# ---------------------------------------------------------------
# 4. Alarma: DLQ con mensajes -> SNS -> correo
# ---------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name = "spike5-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "spike5-dlq-not-empty"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

output "queue_url" {
  value = aws_sqs_queue.main.url
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}
