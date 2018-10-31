# Main Module file

terraform {
  required_version = "~> 0.11.8"
}

# VPC CONFIGURATION

data "aws_availability_zones" "this" {}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  create_vpc = "${var.vpc_create}"

  name = "${var.name}-${terraform.workspace}-vpc"
  cidr = "${var.vpc_cidr}"
  azs  = "${data.aws_availability_zones.this.names}"

  public_subnets  = "${var.vpc_public_subnets}"
  private_subnets = "${var.vpc_private_subnets}"

  # NAT gateway for private subnets
  enable_nat_gateway = "${!var.development_mode}"
  single_nat_gateway = "${!var.development_mode}"

  # Every instance deployed within the VPC will get a hostname
  enable_dns_hostnames = true

  # Every instance will have a dedicated internal endpoint to communicate with S3
  enable_s3_endpoint = true
}

# ECR

resource "aws_ecr_repository" "this" {
  count = "${length(var.services) > 0 ? length(var.services) : 0}"

  name = "${element(keys(var.services), count.index)}-${terraform.workspace}"
}

data "template_file" "ecr-lifecycle" {
  count = "${length(var.services) > 0 ? length(var.services) : 0}"

  template = "${file("${path.module}/policies/ecr-lifecycle-policy.json")}"

  vars {
    count = "${lookup(var.services[element(keys(var.services), count.index)], "registry_retention_count", var.ecr_default_retention_count)}"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  count = "${length(var.services) > 0 ? length(var.services) : 0}"

  repository = "${element(aws_ecr_repository.this.*.name, count.index)}"

  policy = "${element(data.template_file.ecr-lifecycle.*.rendered, count.index)}"
}

# ECS CLUSTER

resource "aws_ecs_cluster" "this" {
  name = "${var.name}-${terraform.workspace}-cluster"
}

# ECS TASKS DEFINITIONS

resource "aws_iam_role" "tasks" {
  name               = "${var.name}-${terraform.workspace}-task-execution-role"
  assume_role_policy = "${file("${path.module}/policies/ecs-task-execution-role.json")}"
}

resource "aws_iam_role_policy" "tasks" {
  name   = "${var.name}-${terraform.workspace}-task-execution-policy"
  policy = "${file("${path.module}/policies/ecs-task-execution-role-policy.json")}"
  role   = "${aws_iam_role.tasks.id}"
}

data "template_file" "tasks" {
  count = "${length(var.services) > 0 ? length(var.services) : 0}"

  template = "${file("${path.cwd}/${lookup(var.services[element(keys(var.services), count.index)], "task_definition")}")}"

  vars {
    container_name = "${element(keys(var.services), count.index)}"
    container_port = "${lookup(var.services[element(keys(var.services), count.index)], "container_port")}"
    repository_url = "${element(aws_ecr_repository.this.*.repository_url, count.index)}"
    log_group      = "${element(aws_cloudwatch_log_group.this.*.name, count.index)}"
    region         = "${var.region}"
  }
}

data "template_file" "development" {
  count = "${var.development_mode && length(var.services) > 0 ? length(var.services) : 0}"

  template = "${file("${path.module}/development/task.json")}"

  vars {
    app_host = "${element(aws_service_discovery_service.development.*.name, count.index)}.${element(aws_service_discovery_private_dns_namespace.development.*.name, count.index)}"
    app_port = "${lookup(var.services[element(keys(var.services), count.index)], "container_port")}"
  }
}

resource "aws_ecs_task_definition" "this" {
  count = "${length(var.services) > 0 ? length(var.services) : 0}"

  family                   = "${var.name}-${terraform.workspace}-${element(keys(var.services), count.index)}"
  container_definitions    = "${element(data.template_file.tasks.*.rendered, count.index)}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "${lookup(var.services[element(keys(var.services), count.index)], "cpu")}"
  memory                   = "${lookup(var.services[element(keys(var.services), count.index)], "memory")}"
  execution_role_arn       = "${aws_iam_role.tasks.arn}"
  task_role_arn            = "${aws_iam_role.tasks.arn}"
}

resource "aws_ecs_task_definition" "development" {
  count = "${var.development_mode && length(var.services) > 0 ? length(var.services) : 0}"

  family                   = "${var.name}-${terraform.workspace}-development-web-entry"
  container_definitions    = "${element(data.template_file.development.*.rendered, count.index)}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = "${aws_iam_role.tasks.arn}"
  task_role_arn            = "${aws_iam_role.tasks.arn}"
}


resource "aws_cloudwatch_log_group" "this" {
  count = "${length(var.services) > 0 ? length(var.services) : 0}"

  name = "/ecs/${var.name}-${element(keys(var.services), count.index)}"

  retention_in_days = "${lookup(var.services[element(keys(var.services), count.index)], "logs_retention_days", var.cloudwatch_logs_default_retention_days)}"
}

# SECURITY GROUPS

resource "aws_security_group" "web" {
  vpc_id = "${module.vpc.vpc_id}"
  name   = "${var.name}-${terraform.workspace}-web-sg"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "services" {
  count = "${length(var.services) > 0 ? length(var.services) : 0}"

  vpc_id = "${module.vpc.vpc_id}"
  name   = "${var.name}-${terraform.workspace}-services-sg"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port       = "${lookup(var.services[element(keys(var.services), count.index)], "container_port")}"
    to_port         = "${lookup(var.services[element(keys(var.services), count.index)], "container_port")}"
    protocol        = "tcp"
    security_groups = ["${aws_security_group.web.id}"]
  }
}

# ALBs

resource "random_id" "target_group_sufix" {
  byte_length = 2
}

resource "aws_lb_target_group" "this" {
  count = "${length(var.services) > 0 && !var.development_mode ? length(var.services) : 0}"

  name        = "${var.name}-${element(keys(var.services), count.index)}-${random_id.target_group_sufix.hex}"
  port        = "${lookup(var.services[element(keys(var.services), count.index)], "container_port")}"
  protocol    = "HTTP"
  vpc_id      = "${module.vpc.vpc_id}"
  target_type = "ip"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb" "this" {
  count = "${length(var.services) > 0 && !var.development_mode ? length(var.services) : 0}"

  name            = "${var.name}-${terraform.workspace}-${element(keys(var.services), count.index)}-alb"
  subnets         = ["${module.vpc.public_subnets}"]
  security_groups = ["${aws_security_group.web.id}"]
}

resource "aws_lb_listener" "this" {
  count = "${length(var.services) > 0 && !var.development_mode ? length(var.services) : 0}"

  load_balancer_arn = "${element(aws_lb.this.*.arn, count.index)}"
  port              = "80"
  protocol          = "HTTP"
  depends_on        = ["aws_lb_target_group.this"]

  default_action {
    target_group_arn = "${element(aws_lb_target_group.this.*.arn, count.index)}"
    type             = "forward"
  }
}

# ECS SERVICES

resource "aws_ecs_service" "this" {
  count = "${!var.development_mode && length(var.services) > 0 ? length(var.services) : 0}"

  name            = "${element(keys(var.services), count.index)}"
  cluster         = "${aws_ecs_cluster.this.name}"
  task_definition = "${element(aws_ecs_task_definition.this.*.arn, count.index)}"
  desired_count   = "${var.development_mode ? 1 : lookup(var.services[element(keys(var.services), count.index)], "replicas")}"
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  network_configuration {
    security_groups = ["${element(aws_security_group.services.*.id, count.index)}"]
    subnets         = ["${module.vpc.private_subnets}"]
  }

  load_balancer {
    target_group_arn = "${element(aws_lb_target_group.this.*.arn, count.index)}"
    container_name   = "${element(keys(var.services), count.index)}"
    container_port   = "${lookup(var.services[element(keys(var.services), count.index)], "container_port")}"
  }

  depends_on = ["aws_lb_target_group.this", "aws_lb_listener.this"]
}

resource "aws_ecs_service" "this_dev" {
  count = "${var.development_mode && length(var.services) > 0 ? length(var.services) : 0}"

  name            = "${element(keys(var.services), count.index)}"
  cluster         = "${aws_ecs_cluster.this.name}"
  task_definition = "${element(aws_ecs_task_definition.this.*.arn, count.index)}"
  desired_count   = "1"
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    security_groups  = ["${element(aws_security_group.services.*.id, count.index)}"]
    subnets          = ["${module.vpc.public_subnets}"]
    assign_public_ip = true
  }

  service_registries {
    registry_arn = "${element(aws_service_discovery_service.development.*.arn, count.index)}"
  }

  depends_on = ["aws_ecs_service.development"]
}

resource "aws_ecs_service" "development" {
  count = "${var.development_mode && length(var.services) > 0 ? length(var.services) : 0}"

  name = "development_web_entry"
  cluster         = "${aws_ecs_cluster.this.name}"
  task_definition = "${element(aws_ecs_task_definition.development.*.arn, count.index)}"
  desired_count   = 1
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  network_configuration {
    security_groups  = ["${aws_security_group.web.id}"]
    subnets          = ["${module.vpc.public_subnets}"]
    assign_public_ip = true
  }
}

# Service Discovery for Development Mode

resource "aws_service_discovery_private_dns_namespace" "development" {
  count = "${var.development_mode ? 1 : 0}"

  name = "${var.name}.${terraform.workspace}.development"
  vpc  = "${module.vpc.vpc_id}"
}

resource "aws_service_discovery_service" "development" {
  count = "${var.development_mode && length(var.services) > 0 ? length(var.services) : 0}"

  name = "${element(keys(var.services), count.index)}"

  dns_config {
    namespace_id = "${aws_service_discovery_private_dns_namespace.development.id}"
    dns_records {
      ttl = 15
      type = "A"
    }
  }

  health_check_custom_config {
    failure_threshold = 2
  }
}

# CODEBUILD

resource "aws_s3_bucket" "this" {
  bucket        = "${var.name}-${terraform.workspace}-builds"
  acl           = "private"
  force_destroy = true
}

resource "aws_iam_role" "codebuild" {
  name               = "${var.name}-${terraform.workspace}-codebuild-role"
  assume_role_policy = "${file("${path.module}/policies/codebuild-role.json")}"
}

data "template_file" "codebuild" {
  template = "${file("${path.module}/policies/codebuild-role-policy.json")}"

  vars {
    aws_s3_bucket_arn = "${aws_s3_bucket.this.arn}"
  }
}

resource "aws_iam_role_policy" "codebuild" {
  name   = "${var.name}-${terraform.workspace}-codebuild-role-policy"
  role   = "${aws_iam_role.codebuild.id}"
  policy = "${data.template_file.codebuild.rendered}"
}

data "template_file" "buildspec" {
  count = "${length(var.services) > 0 ? length(var.services) : 0}"

  template = "${file("${path.module}/build/buildspec.yml")}"

  vars {
    container_name = "${element(keys(var.services), count.index)}"
    repository_url = "${element(aws_ecr_repository.this.*.repository_url, count.index)}"
    region         = "${var.region}"
  }
}

resource "aws_codebuild_project" "this" {
  count = "${length(var.services) > 0 ? length(var.services) : 0}"

  name          = "${var.name}-${terraform.workspace}-${element(keys(var.services), count.index)}-builds"
  build_timeout = "10"
  service_role  = "${aws_iam_role.codebuild.arn}"

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"

    // https://docs.aws.amazon.com/codebuild/latest/userguide/build-env-ref-available.html
    image           = "aws/codebuild/docker:17.09.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "${element(data.template_file.buildspec.*.rendered, count.index)}"
  }
}

# CODEPIPELINE
resource "aws_iam_role" "codepipeline" {
  name = "${var.name}-${terraform.workspace}-codepipeline-role"

  assume_role_policy = "${file("${path.module}/policies/codepipeline-role.json")}"
}

data "template_file" "codepipeline" {
  template = "${file("${path.module}/policies/codepipeline-role-policy.json")}"

  vars {
    aws_s3_bucket_arn = "${aws_s3_bucket.this.arn}"
  }
}

resource "aws_iam_role_policy" "codepipeline" {
  name   = "${var.name}-${terraform.workspace}-codepipeline-role-policy"
  role   = "${aws_iam_role.codepipeline.id}"
  policy = "${data.template_file.codepipeline.rendered}"
}

resource "aws_codepipeline" "this" {
  count = "${length(var.services) > 0 ? length(var.services) : 0}"

  name     = "${var.name}-${terraform.workspace}-${element(keys(var.services), count.index)}-pipeline"
  role_arn = "${aws_iam_role.codepipeline.arn}"

  artifact_store {
    location = "${aws_s3_bucket.this.bucket}"
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["source"]

      configuration {
        Owner  = "${var.repo_owner}"
        Repo   = "${var.repo_name}"
        Branch = "${terraform.workspace == "default" ? "master" : terraform.workspace}"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source"]
      output_artifacts = ["imagedefinitions"]

      configuration {
        ProjectName = "${var.name}-${terraform.workspace}-${element(keys(var.services), count.index)}-builds"
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      input_artifacts = ["imagedefinitions"]
      version         = "1"

      configuration {
        ClusterName = "${aws_ecs_cluster.this.name}"
        ServiceName = "${element(keys(var.services), count.index)}"
        FileName    = "imagedefinitions.json"
      }
    }
  }

  depends_on = ["aws_iam_role_policy.codebuild", "aws_ecs_service.this"]
}
