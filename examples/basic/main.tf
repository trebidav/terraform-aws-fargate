terraform {
  required_version = "~> 0.11.11"
}

provider "aws" {
  version = "~> 1.54.0"
  region  = "us-east-1"
  profile = "playground"
}

module "fargate" {
  source = "../../"

  name = "basic-example"

  services = {
    api = {
      task_definition = "api.json"
      container_port  = 3000
      cpu             = "256"
      memory          = "512"
      replicas        = 3

      registry_retention_count = 15 # Optional. 20 by default
      logs_retention_days      = 14 # Optional. 30 by default
    }
  }

  # If you want to set up a SNS topic receiving CodePipeline current status
  # SNS's ARN could be use by getting the output of the module eg =>
  # arn = "${module.fargate.codepipeline_events_sns_arn}"
  codepipeline_events_enabled = true
}
