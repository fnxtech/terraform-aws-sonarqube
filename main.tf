#------------------------------------------------------------------------------
# Variables
#------------------------------------------------------------------------------
locals {
  sonar_db_engine_version = "11.6"
  sonar_db_port           = 5432
  sonar_db_instance_size  = var.db_instance_size
  sonar_db_name           = var.db_name
  sonar_db_username       = var.db_username
  sonar_db_password       = var.db_password == "" ? random_password.master_password.result : var.db_password
}

#------------------------------------------------------------------------------
# Random password for RDS
#------------------------------------------------------------------------------
resource "random_password" "master_password" {
  length  = 10
  special = false
}

#------------------------------------------------------------------------------
# AWS Cloudwatch Logs
#------------------------------------------------------------------------------
module aws_cw_logs {
  source  = "cn-terraform/cloudwatch-logs/aws"
  version = "1.0.7"
  # source  = "../terraform-aws-cloudwatch-logs"

  logs_path = "/ecs/service/${var.name_prefix}-sonar"
}

#------------------------------------------------------------------------------
# ECS Fargate Service
#------------------------------------------------------------------------------
module "ecs_fargate" {
  source  = "git@github.com:mo-hit/terraform-aws-ecs-fargate.git"
  # source = "../terraform-aws-ecs-fargate"

  name_prefix                  = "${var.name_prefix}-sonar"
  vpc_id                       = var.vpc_id
  public_subnets_ids           = var.public_subnets_ids
  private_subnets_ids          = var.private_subnets_ids
  container_name               = "${var.name_prefix}-sonar"
  container_image              = "sonarqube:8.5-community"
  container_cpu                = 1024
  container_memory             = 8192
  container_memory_reservation = 4096

  command = [
    "-Dsonar.search.javaAdditionalOpts=-Dnode.store.allow_mmapfs=false"
  ]
  ulimits = [
    {
      "name" : "nofile",
      "softLimit" : 65535,
      "hardLimit" : 65535
    }
  ]
  port_mappings = [
    {
      containerPort = 9000
      hostPort      = 9000
      protocol      = "tcp"
    }
  ]
  environment = [
    {
      name  = "SONAR_JDBC_USERNAME"
      value = local.sonar_db_username
    },
    {
      name  = "SONAR_JDBC_PASSWORD"
      value = local.sonar_db_password
    },
    {
      name  = "SONAR_JDBC_URL"
      value = "jdbc:postgresql://${aws_rds_cluster.aurora_db.endpoint}/${local.sonar_db_name}"
    },
  ]
  log_configuration = {
    logDriver = "awslogs"
    options = {
      "awslogs-region"        = var.region
      "awslogs-group"         = "/ecs/service/${var.name_prefix}-sonar"
      "awslogs-stream-prefix" = "ecs"
    }
    secretOptions = null
  }
}

resource "aws_security_group" "lb_access_sg" {
  name        = "${var.name_prefix}-lb-access-sg"
  description = "Controls access to the Load Balancer"
  vpc_id      = var.vpc_id
  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "${var.name_prefix}-lb-access-sg"
  }
}

resource "aws_security_group_rule" "ingress_through_https" {
  for_each          = var.https_ports
  security_group_id = aws_security_group.lb_access_sg.id
  type              = "ingress"
  from_port         = each.value.listener_port
  to_port           = each.value.listener_port
  protocol          = "tcp"
  cidr_blocks       = var.https_ingress_cidr_blocks
  prefix_list_ids   = var.https_ingress_prefix_list_ids
}

resource "aws_lb" "lb" {
  name                             = "fnx-sonar-lb"
  internal                         = false
  load_balancer_type               = "application"
  drop_invalid_header_fields       = var.drop_invalid_header_fields
  subnets                          = var.internal ? var.private_subnets : var.public_subnets
  idle_timeout                     = var.idle_timeout
  enable_deletion_protection       = var.enable_deletion_protection
  enable_cross_zone_load_balancing = var.enable_cross_zone_load_balancing
  enable_http2                     = var.enable_http2
  ip_address_type                  = var.ip_address_type
  security_groups = compact(
    concat(var.security_groups, [aws_security_group.lb_access_sg.id]),
  )

  access_logs {
    bucket  = aws_s3_bucket.logs.id
    enabled = true
  }

  tags = {
    Name = "${var.name_prefix}-lb"
  }
}
