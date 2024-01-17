provider "aws" {
  region = local.region
}

locals {
  name   = "dev-webapp"
  region = "us-east-1"

  container_port = 3000
  container_name = "dev-webapp-container"

  tags = {
    Environment  = "dev"
  }
}

################################################################################
# ECS Blueprint
################################################################################

module "ecs_service" {
  source  = "terraform-aws-modules/ecs/aws//modules/service"
  version = "~> 5.6"

  name          = "dev-webapp-ecs-service"
  desired_count = 3
  cluster_arn   = data.aws_ecs_cluster.core_infra.arn

  # Task Definition IAM Roles
  # Allows access to secrets manager
  enable_execute_command = true
  create_task_exec_iam_role = true
  task_exec_iam_role_name = "ecsTaskExecutionRole-dev-webapp-tasks"
  create_task_exec_policy = true
  task_exec_secret_arns  = [
    "arn:aws:secretsmanager:us-east-1:050559574035:secret:dev/webapp/DATABASE_URL-g5t2hw",
    "arn:aws:secretsmanager:us-east-1:050559574035:secret:dev/webapp/NEXTAUTH_SECRET-PqyzXV",
    "arn:aws:secretsmanager:us-east-1:050559574035:secret:dev/webapp/ENCRYPTION_KEY-tOTAWb",
    "arn:aws:secretsmanager:us-east-1:050559574035:secret:dev/webapp/SMTP_CONFIG-Zo4jcK"
  ]
  # Restrict access to system manager => In dev, enabled (default allows all access) to debug tasks containers through exec
  # Eg: aws ecs execute-command  --region "us-east-1" --cluster XX_CLUSTER_NAME_XX --task XX_TASK_ID_XX --container XX_CONTAINER_NAME_XX --command "sh" --interactive
  # task_exec_ssm_param_arns = []

  container_definitions = {
    (local.container_name) = {
      image                    = "formbricks/formbricks"
      readonly_root_filesystem = false
      # command                  = ["tail", "-f", "/dev/null"] # Uncomment to debug
      port_mappings = [
        {
          protocol      = "tcp",
          containerPort = local.container_port
        }
      ]
      # TODO => Use Githubs secrets and TF variables to pass secrets
      secrets = [
        {
          name      = "DATABASE_URL"
          valueFrom = "arn:aws:secretsmanager:us-east-1:050559574035:secret:dev/webapp/DATABASE_URL-g5t2hw:DATABASE_URL::"
        },
        {
          name      = "NEXTAUTH_SECRET"
          valueFrom = "arn:aws:secretsmanager:us-east-1:050559574035:secret:dev/webapp/NEXTAUTH_SECRET-PqyzXV:NEXTAUTH_SECRET::"
        },
        {
          name      = "ENCRYPTION_KEY"
          valueFrom = "arn:aws:secretsmanager:us-east-1:050559574035:secret:dev/webapp/ENCRYPTION_KEY-tOTAWb:ENCRYPTION_KEY::"
        },
        {
          name      = "SMTP_HOST"
          valueFrom = "arn:aws:secretsmanager:us-east-1:050559574035:secret:dev/webapp/SMTP_CONFIG-Zo4jcK:SMTP_HOST::"
        },
        {
          name      = "SMTP_PORT"
          valueFrom = "arn:aws:secretsmanager:us-east-1:050559574035:secret:dev/webapp/SMTP_CONFIG-Zo4jcK:SMTP_PORT::"
        },
        {
          name      = "SMTP_USER"
          valueFrom = "arn:aws:secretsmanager:us-east-1:050559574035:secret:dev/webapp/SMTP_CONFIG-Zo4jcK:SMTP_USER::"
        },
        {
          name      = "SMTP_PASSWORD"
          valueFrom = "arn:aws:secretsmanager:us-east-1:050559574035:secret:dev/webapp/SMTP_CONFIG-Zo4jcK:SMTP_PASSWORD::"
        }
      ]
      # TODO: ROUTE 53 Connection
      environment = [
        {
          name  = "WEBAPP_URL",
          value = "http://ecsdemo-frontend-1330444932.us-east-1.elb.amazonaws.com"
        }
      ] 
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
  name = local.name

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

  name = local.name

  # For dev only
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
  }
  security_group_egress_rules = { for subnet in data.aws_subnet.private_cidr :
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
        path                = "/"
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

################################################################################
# Supporting Resources
################################################################################

data "aws_vpc" "vpc" {
  filter {
    name   = "tag:Name"
    values = ["core-infra"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "tag:Name"
    values = ["core-infra-public-*"]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "tag:Name"
    values = ["core-infra-private-*"]
  }
}

data "aws_subnet" "private_cidr" {
  for_each = toset(data.aws_subnets.private.ids)
  id       = each.value
}

data "aws_ecs_cluster" "core_infra" {
  cluster_name = "core-infra"
}

data "aws_service_discovery_dns_namespace" "this" {
  name = "default.${data.aws_ecs_cluster.core_infra.cluster_name}.local"
  type = "DNS_PRIVATE"
}

#aws ecs execute-command  --region "us-east-1" --cluster core-infra --task e717538742e64db980f074d700554c92 --container ecsdemo-frontend --command "sh" --interactive




# provider "aws" {
#   region = local.region
# }

# locals {
#   name   = "dev-webapp"
#   region = "us-east-1"

#   container_port = 3000
#   container_name = "webapp-container"

#   tags = {
#     Environment  = "dev"
#   }
# }

# variable "encryption-key" {
#   type    = string
#   default = "fc0739dbdd94db82dd6fd67867da0f8fdb2a5a8b0a7d566714ab7739bbda2449"
# }

# variable "nextauth" {
#   type    = string
#   default = "dfab71a0954f1d6f14a4e92745412f7e0ea53e6218b8925d3c3e5f13d11b23db"
# }


# ################################################################################
# # Supporting Resources
# ################################################################################

# data "aws_vpc" "vpc" {
#   filter {
#     name   = "tag:Name"
#     values = ["dev-core-infra-vpc"]
#   }
# }

# data "aws_subnets" "public" {
#   filter {
#     name   = "tag:Name"
#     values = ["dev-core-infra-vpc-public*"]
#   }
# }

# data "aws_subnets" "private" {
#   filter {
#     name   = "tag:Name"
#     values = ["dev-core-infra-vpc-private*"]
#   }
# }

# data "aws_subnet" "private_cidr" {
#   for_each = toset(data.aws_subnets.private.ids)
#   id       = each.value
# }

# data "aws_ecs_cluster" "dev_core_infra_ecs_cluster" {
#   cluster_name = "dev-core-infra-ecs-cluster"
# }

# data "aws_service_discovery_dns_namespace" "this" {
#   name = "default.dev-core-infra.local"
#   type = "DNS_PRIVATE"
# }


# ################################################################################
# # Task Execution IAM Role
# ################################################################################

# resource "aws_iam_role" "ecs_task_execution_role" {
#   name = "ecsTaskExecutionRole"
#   assume_role_policy = <<EOF
# {
#   "Version": "2012-10-17",
#   "Statement": [
#     {
#       "Effect": "Allow",
#       "Sid": "",
#       "Action": "sts:AssumeRole",
#       "Principal": {
#         "Service": "ecs-tasks.amazonaws.com"
#       }
#     }
#   ]
# }
# EOF
# }

# resource "aws_iam_policy" "secrets_manager_restricted_access" {
#   name        = "secrets_manager_restricted_access"
#   description = "Allows read-only access to specific secrets in Secrets Manager"

#   policy = <<EOF
# {
#   "Version": "2012-10-17",
#   "Statement": [
#     {
#       "Effect": "Allow",
#       "Action": [
#         "secretsmanager:GetSecretValue"
#       ],
#       "Resource": [
#         "arn:aws:secretsmanager:us-east-1:392512393796:secret:dev/webapp/DATABASE_URL-3uFL2t"
#       ]
#     }
#   ]
# }
# EOF
# }

# resource "aws_iam_role_policy_attachment" "secrets_manager_restricted_access_attachment" {
#   role       = aws_iam_role.ecs_task_execution_role.name  # Reference the declared resource
#   policy_arn = aws_iam_policy.secrets_manager_restricted_access.arn
# }

# ################################################################################
# # ECS Blueprint
# ################################################################################

# # module "ecs_service" {
# #   source  = "terraform-aws-modules/ecs/aws//modules/service"
# #   version = "~> 5.6"

# #   name          = "${local.name}-ecs-service"
# #   desired_count = 3
# #   cluster_arn = data.aws_ecs_cluster.dev_core_infra_ecs_cluster.arn


# #   # Task Definition => Should only be used for dev environments
# #   enable_execute_command = true

# #   container_definitions = {
# #     (local.container_name) = {
# #       image                    = "public.ecr.aws/aws-containers/ecsdemo-frontend"
# #       readonly_root_filesystem = false

# #       port_mappings = [
# #         {
# #           protocol      = "tcp",
# #           containerPort = local.container_port
# #         }
# #       ]
# #       environment = [
# #         {
# #           name  = "ENCRYPTION_KEY",
# #           value = var.encryption-key
# #         },
# #         {
# #           name  = "NEXTAUTH_SECRET",
# #           value = var.nextauth
# #         }
# #       ]
# #       secrets = [
# #         {
# #           name      = "DATABASE_URL"
# #           valueFrom = "arn:aws:secretsmanager:us-east-1:392512393796:secret:dev/webapp/DATABASE_URL-3uFL2t"
# #         }
# #       ]
# #     }
# #     execution_role_arn = aws_iam_role.ecs_task_execution_role.arn
# #   }

# #   # service_registries = {
# #   #   registry_arn = aws_service_discovery_service.this.arn
# #   # }

# #   load_balancer = {
# #     service = {
# #       target_group_arn = module.alb.target_groups["ecs-task"].arn
# #       container_name   = local.container_name
# #       container_port   = local.container_port
# #     }
# #   }

# #   subnet_ids = data.aws_subnets.private.ids
# #   security_group_rules = {
# #     ingress_alb_service = {
# #       type                     = "ingress"
# #       from_port                = local.container_port
# #       to_port                  = local.container_port
# #       protocol                 = "tcp"
# #       description              = "Service port"
# #       source_security_group_id = module.alb.security_group_id
# #     }
# #     egress_all = {
# #       type        = "egress"
# #       from_port   = 0
# #       to_port     = 0
# #       protocol    = "-1"
# #       cidr_blocks = ["0.0.0.0/0"]
# #     }
# #   }

# #   tags = local.tags
# # }

# resource "aws_service_discovery_service" "this" {
#   name = local.name

#   dns_config {
#     namespace_id = data.aws_service_discovery_dns_namespace.this.id

#     dns_records {
#       ttl  = 10
#       type = "A"
#     }

#     routing_policy = "MULTIVALUE"
#   }

#   health_check_custom_config {
#     failure_threshold = 1
#   }
# }

# module "alb" {
#   source  = "terraform-aws-modules/alb/aws"
#   version = "~> 9.0"

#   name = "dev-webapp-alb"

#   # For dev env only
#   enable_deletion_protection = false

#   vpc_id  = data.aws_vpc.vpc.id
#   subnets = data.aws_subnets.public.ids
#   security_group_ingress_rules = {
#     all_http = {
#       from_port   = 80
#       to_port     = 80
#       ip_protocol = "tcp"
#       description = "HTTP web traffic"
#       cidr_ipv4   = "0.0.0.0/0"
#     }
#   }
#   security_group_egress_rules = { for subnet in data.aws_subnet.private_cidr :
#     (subnet.availability_zone) => {
#       ip_protocol = "-1"
#       cidr_ipv4   = subnet.cidr_block
#     }
#   }

#   listeners = {
#     http = {
#       port     = "80"
#       protocol = "HTTP"
#       forward = {
#         target_group_key = "ecs-task"
#       }
#     }
#   }

#   target_groups = {
#     ecs-task = {
#       backend_protocol = "HTTP"
#       backend_port     = local.container_port
#       target_type      = "ip"
#       health_check = {
#         enabled             = true
#         healthy_threshold   = 5
#         interval            = 30
#         matcher             = "200-299"
#         path                = "/"
#         port                = "traffic-port"
#         protocol            = "HTTP"
#         timeout             = 5
#         unhealthy_threshold = 2
#       }

#       # There's nothing to attach here in this definition. Instead,
#       # ECS will attach the IPs of the tasks to this target group
#       create_attachment = false
#     }
#   }

#   tags = local.tags
# }

