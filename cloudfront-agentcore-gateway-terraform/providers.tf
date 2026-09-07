terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # AgentCore Gateway resources are recent additions. 6.61 is the version this
      # pattern was developed and tested against.
      version = "~> 6.61"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# The Gateway, the Lambda target and the REST API all live here.
provider "aws" {
  region = var.region

  default_tags {
    tags = var.tags
  }
}

# CloudFront requires two things to be in us-east-1 no matter where the rest of the
# stack lives: the ACM certificate for an alternate domain name, and any Lambda@Edge
# function. This alias exists so `region` can be anything without those breaking.
#
# When var.region is already us-east-1 this is simply a second handle on the same
# region, which is harmless.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = var.tags
  }
}
