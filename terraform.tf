terraform {
  required_version = ">= 1.5.0"

  required_providers {
    alicloud = {
      source = "aliyun/alicloud"
      # assume_role_policy_document / role_name 需要 >= 1.252.0
      version = "~> 1.252"
    }
  }
}

provider "alicloud" {
  region = var.region
}
