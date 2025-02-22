################################################################################
# (Optional) Integrating Terraform Cloud
################################################################################

# To use Terraform Cloud, follow these steps:

# 1. Uncomment the code block below.
# 2. Replace placeholders "your-organization-name" and "your-workspace-name" with your actual Terraform Cloud organization and workspace names.
# 3. Refer to the Terraform Cloud documentation for details: https://developer.hashicorp.com/terraform/cloud-docs/overview


terraform {
  cloud {
    organization = "kumura"
    workspaces {
      name = "kumura"
    }
  }
}


locals {
  name           = "webapp-formbricks"
  container_port = 3000
  container_name = "webapp-formbricks-container"
  tags = {
    Application = "formbricks"
  }
}

provider "aws" {
  region = var.region
}

################################################################################
# Supporting Resources
################################################################################

data "aws_vpc" "vpc" {
  filter {
    name   = "tag:Name"
    values = ["core-infra-formbricks-vpc"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "tag:Name"
    values = ["core-infra-formbricks-vpc-public-*"]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "tag:Name"
    values = ["core-infra-formbricks-vpc-private-*"]
  }
}

data "aws_subnet" "private_cidr" {
  for_each = toset(data.aws_subnets.private.ids)
  id       = each.value
}

data "aws_ecs_cluster" "core_infra" {
  cluster_name = "core-infra-formbricks-cluster"
}

data "aws_service_discovery_dns_namespace" "this" {
  name = "core-infra-formbricks-service-discovery-private-dns-namespace"
  type = "DNS_PRIVATE"
}

################################################################################
# ECS Blueprint
################################################################################

module "ecs_service" {
  source  = "terraform-aws-modules/ecs/aws//modules/service"
  version = "~> 5.6"

  name        = "${local.name}-service"
  cluster_arn = data.aws_ecs_cluster.core_infra.arn

  desired_count      = 2
  enable_autoscaling = false

  enable_ecs_managed_tags = true
  requires_compatibilities = ["FARGATE"]

  # Task Definition IAM Roles
  create_task_exec_iam_role = true
  task_exec_iam_role_name   = "webapp-formbricks-ecsTaskExecRole"
  create_task_exec_policy   = true
  # task_exec_secret_arns     = values(var.secrets_manager_data)[*] # Uncomment this line if you are using Secrets Manager

  container_definitions = {
    (local.container_name) = {
      image                    = var.TF_VAR_container_image # By default, this uses the latest image available at ghcr.io/formbricks/formbricks
      cpu                      = "1024"
      memory                   = "2048"
      readonly_root_filesystem = false
      port_mappings = [
        {
          protocol      = "tcp"
          containerPort = local.container_port
        }
      ]

      environment = [
        {
          name  = "DATABASE_URL"
          value = var.DATABASE_URL
        },
        {
          name  = "ENCRYPTION_KEY"
          value = var.ENCRYPTION_KEY
        },
        {
          name  = "NEXTAUTH_SECRET"
          value = var.ENCRYPTION_KEY
        },
        {
          name  = "NEXTAUTH_URL"
          value = "https://${module.alb.dns_name}"
        },
        {
          name  = "WEBAPP_URL"
          value = "https://${module.alb.dns_name}"
        }
      ]

      # Security Note: We recommend using Secrets Manager or a similar service for sensitive data sharing with ECS Task.
      # You can read more at:
      # https://docs.aws.amazon.com/AmazonECS/latest/developerguide/specifying-sensitive-data.html
      # https://docs.aws.amazon.com/AmazonECS/latest/developerguide/specifying-sensitive-data-tutorial.html
      /*
      secrets = [
        for key, value in var.secrets_manager_data :
        {
          name      = key
          valueFrom = "${value}:${key}::"
        }
      ]
      */
    }
  }

  service_registries = {
    registry_arn = aws_service_discovery_service.this.arn
  }

  load_balancer = {
    service = {
      target_group_arn = module.alb.target_groups["ecs-task"].arn
      container_name   = local.container_name
      container_port   = local.container_port
    }
  }

  subnet_ids = data.aws_subnets.private.ids

  security_group_rules = {
    ingress_alb_service = {
      type                     = "ingress"
      from_port                = local.container_port
      to_port                  = local.container_port
      protocol                 = "tcp"
      description              = "Service port"
      source_security_group_id = module.alb.security_group_id
    }
    egress_all = {
      type        = "egress"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  tags = local.tags
}

resource "aws_service_discovery_service" "this" {
  name = "${local.name}-service-discovery"

  dns_config {
    namespace_id = data.aws_service_discovery_dns_namespace.this.id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 9.0"

  name = "${local.name}-alb"

  enable_deletion_protection = false

  vpc_id  = data.aws_vpc.vpc.id
  subnets = data.aws_subnets.public.ids

  security_group_ingress_rules = {

    all_http = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      description = "HTTP web traffic"
      cidr_ipv4   = "0.0.0.0/0"
    }

    # Uncomment the following code block to enable HTTPS

    all_https = {
      from_port   = 443
      to_port     = 443
      ip_protocol = "tcp"
      description = "HTTPS web traffic"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }


  security_group_egress_rules = {
    for subnet in data.aws_subnet.private_cidr :
    (subnet.availability_zone) => {
      ip_protocol = "-1"
      cidr_ipv4   = subnet.cidr_block
    }
  }

  listeners = {
    http = {
      port     = "80"
      protocol = "HTTP"
      forward = {
        target_group_key = "ecs-task"
      }
    }

    # Uncomment the following code block to enable HTTPS
    https = {
      port            = 443
      protocol        = "HTTPS"
      certificate_arn = "your_ssl_certificate_arn"
      forward = {
        target_group_key = "ecs-task"
      }
    }
  }

  target_groups = {
    ecs-task = {
      backend_protocol = "HTTP"
      backend_port     = local.container_port
      target_type      = "ip"

      health_check = {
        enabled             = true
        healthy_threshold   = 5
        interval            = 30
        matcher             = "200-299"
        path                = "/health"
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }

      # There's nothing to attach here in this definition. Instead,
      # ECS will attach the IPs of the tasks to this target group
      create_attachment = false
    }
  }

  tags = local.tags
}
