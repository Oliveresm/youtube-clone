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

# 1. Red Básica
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}
resource "aws_subnet" "pub1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
}
resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}
resource "aws_route_table_association" "a1" {
  subnet_id      = aws_subnet.pub1.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_security_group" "worker_sg" {
  name   = "spike3-worker-sg"
  vpc_id = aws_vpc.main.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 2. Cola SQS
resource "aws_sqs_queue" "video_queue" {
  name = "spike3-video-queue"
}

# 3. Repositorio ECR
resource "aws_ecr_repository" "worker_repo" {
  name         = "spike3-worker"
  force_delete = true
}

# 4. Roles IAM
resource "aws_iam_role" "ecs_execution_role" {
  name = "spike3-ecs-exec-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}
resource "aws_iam_role_policy_attachment" "ecs_exec_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task_role" {
  name = "spike3-ecs-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}
resource "aws_iam_policy" "sqs_policy" {
  name = "spike3-sqs-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Effect   = "Allow"
        Resource = aws_sqs_queue.video_queue.arn
      }
    ]
  })
}
resource "aws_iam_role_policy_attachment" "task_sqs_policy" {
  role       = aws_iam_role.ecs_task_role.name
  policy_arn = aws_iam_policy.sqs_policy.arn
}

# 5. CloudWatch Logs
resource "aws_cloudwatch_log_group" "worker_logs" {
  name              = "/ecs/spike3-worker"
  retention_in_days = 1
}

# 6. ECS Fargate
resource "aws_ecs_cluster" "main" {
  name = "spike3-cluster"
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "spike3-worker-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  container_definitions = jsonencode([
    {
      name      = "worker"
      image     = "${aws_ecr_repository.worker_repo.repository_url}:latest"
      essential = true
      environment = [
        {
          name  = "SQS_QUEUE_URL"
          value = aws_sqs_queue.video_queue.url
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.worker_logs.name
          "awslogs-region"        = "us-east-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "worker" {
  name            = "spike3-worker-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = 1
  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
  }
  network_configuration {
    subnets          = [aws_subnet.pub1.id]
    security_groups  = [aws_security_group.worker_sg.id]
    assign_public_ip = true
  }
}

output "sqs_queue_url" {
  value = aws_sqs_queue.video_queue.url
}
output "ecr_repo_url" {
  value = aws_ecr_repository.worker_repo.repository_url
}