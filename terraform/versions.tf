terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"
    }
  }
}

provider "aws" {
  region = var.region

  # Tag everything so `terraform destroy` leftovers are easy to spot in the console.
  default_tags {
    tags = {
      Project   = "private-gitlab-lab"
      ManagedBy = "terraform"
    }
  }
}
