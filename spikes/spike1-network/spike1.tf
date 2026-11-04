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

# 1. Red (VPC + Subredes Públicas + IGW, sin NAT)
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

resource "aws_subnet" "pub2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
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

resource "aws_route_table_association" "a2" {
  subnet_id      = aws_subnet.pub2.id
  route_table_id = aws_route_table.rt.id
}

# 2. Security Groups
resource "aws_security_group" "vpc_link" {
  name   = "spike1-vpclink-sg"
  vpc_id = aws_vpc.main.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Ingress SOLO desde el SG del VPC Link
resource "aws_security_group" "fargate" {
  name   = "spike1-fargate-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.vpc_link.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 3. Cloud Map (Service Discovery SRV)
resource "aws_service_discovery_private_dns_namespace" "this" {
  name = "spike.local"
  vpc  = aws_vpc.main.id
}

resource "aws_service_discovery_service" "this" {
  name = "api"
  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.this.id
    routing_policy = "MULTIVALUE"
    dns_records {
      ttl  = 10
      type = "SRV"
    }
  }
}

# 4. ECS Fargate Spot
resource "aws_ecs_cluster" "main" {
  name = "spike1-cluster"
}

# CAMBIO: asociar explícitamente el capacity provider al cluster
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE_SPOT"]
}

resource "aws_ecs_task_definition" "app" {
  family                   = "spike1-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  container_definitions = jsonencode([{
    name      = "app"
    image     = "nginxdemos/hello" # muestra la URI que recibe en su página
    essential = true
    portMappings = [{
      containerPort = 80
    }]
  }])
}

resource "aws_ecs_service" "app" {
  name            = "spike1-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
  }

  network_configuration {
    subnets          = [aws_subnet.pub1.id, aws_subnet.pub2.id]
    security_groups  = [aws_security_group.fargate.id]
    assign_public_ip = true
  }

  service_registries {
    registry_arn = aws_service_discovery_service.this.arn
    port         = 80
  }

  depends_on = [aws_ecs_cluster_capacity_providers.main]
}

# 5. API Gateway + VPC Link
resource "aws_apigatewayv2_api" "this" {
  name          = "spike1-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "spike1-vpclink"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = [aws_subnet.pub1.id, aws_subnet.pub2.id]
}

resource "aws_apigatewayv2_integration" "this" {
  api_id             = aws_apigatewayv2_api.this.id
  integration_type   = "HTTP_PROXY"
  integration_uri    = aws_service_discovery_service.this.arn
  integration_method = "ANY"
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.this.id
}

# CAMBIO: {proxy+} para atrapar subrutas (/api/foo/bar)
resource "aws_apigatewayv2_route" "proxy" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /api/{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.this.id}"
}

# {proxy+} no coincide con "/api" exacto, así que se deja también esta ruta
resource "aws_apigatewayv2_route" "root" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /api"
  target    = "integrations/${aws_apigatewayv2_integration.this.id}"
}

resource "aws_apigatewayv2_stage" "this" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true
}

output "api_base_url" {
  value = trimsuffix(aws_apigatewayv2_stage.this.invoke_url, "/")
}
