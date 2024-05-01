provider "aws" {
  region = var.region
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.47"
    }
  }
}

// Currently has to be existing vpc
resource "aws_vpc" "velody-vpc" {
  cidr_block = "172.31.0.0/16"
}

resource "aws_subnet" "velody-subnet-1" {
  vpc_id     = aws_vpc.velody-vpc.id
  cidr_block = "172.31.0.0/20"

  availability_zone = "${var.region}a"
}

resource "aws_subnet" "velody-subnet-2" {
  vpc_id     = aws_vpc.velody-vpc.id
  cidr_block = "172.31.16.0/20"

  availability_zone = "${var.region}b"
}

resource "aws_subnet" "velody-subnet-3" {
  vpc_id     = aws_vpc.velody-vpc.id
  cidr_block = "172.31.32.0/20"

  availability_zone = "${var.region}c"
}

// Define security group
resource "aws_security_group" "velody-sg" {
  vpc_id = aws_vpc.velody-vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # -1 means all protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.velody-vpc.cidr_block]
  }

  name = "velody-sg"
}

// Create a new ECS cluster
resource "aws_ecs_cluster" "velody-cluster" {
  name = "velody-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "velody-cluster-capacity-providers" {
  cluster_name = aws_ecs_cluster.velody-cluster.name

  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = "FARGATE"
  }
}

// Create a new task definition
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "velody-ecs-task-execution-role"
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/SecretsManagerReadWrite",
    "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
    "arn:aws:iam::637423239061:policy/ecs-task-execution-cloudwatch-access"
  ]

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_policy" "cloudwatch_access" {
  name        = "ecs-task-execution-cloudwatch-access"
  path        = "/"
  description = "Policy to allow ECS tasks to write logs and metrics to CloudWatch."

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "cloudwatch:PutMetricData"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "cloudwatch_access_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.cloudwatch_access.arn
}


#      ~ managed_policy_arns   = [
#          - "arn:aws:iam::aws:policy/SecretsManagerReadWrite",
#          - "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy",
#        ] -> (known after apply)


resource "aws_ecs_task_definition" "velody-task" {
  family                   = "velody-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  cpu    = "4096"
  memory = "8192"

  // Define log configuration

  container_definitions = jsonencode([
    {
      name      = "velody-container"
      image     = "ghcr.io/linusromland/velody:latest"
      essential = true

      cpu    = 2048
      memory = 4096

      secrets = [
        {
          name      = "BOT_TOKEN"
          valueFrom = "${var.secret_arn}:BOT_TOKEN::"
        },
        {
          name      = "OPENAI_API_KEY"
          valueFrom = "${var.secret_arn}:OPENAI_API_KEY::"
        },
        {
          name      = "YOUTUBE_API_KEY"
          valueFrom = "${var.secret_arn}:YOUTUBE_API_KEY::"
        }
      ]

      environment = [
        {
          name  = "MONGODB_URI"
          value = "mongodb://127.0.0.1:27017/velody"
        },
        {
          name  = "OPENAI_MODEL"
          value = "gpt-4-turbo"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-create-group"  = "true"
          "awslogs-group"         = "/ecs/velody-task"
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    },
    {
      name      = "mongodb"
      image     = "mongo:latest"
      essential = true

      cpu    = 2048
      memory = 4096

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-create-group"  = "true"
          "awslogs-group"         = "/ecs/velody-task"
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

}



// Create a new service
resource "aws_ecs_service" "velody-service" {
  name            = "velody-service"
  cluster         = aws_ecs_cluster.velody-cluster.id
  task_definition = aws_ecs_task_definition.velody-task.arn
  desired_count   = 1

  network_configuration {
    subnets          = [aws_subnet.velody-subnet-1.id, aws_subnet.velody-subnet-2.id, aws_subnet.velody-subnet-3.id]
    security_groups  = [aws_security_group.velody-sg.id]
    assign_public_ip = true
  }

  deployment_controller {
    type = "ECS"
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 100
    base              = 1
  }
}
