# homelab-pki/tofu/main.tf
terraform {
  required_version = ">= 1.11.0"

  backend "kubernetes" {
    secret_suffix     = "homelab-pki"
    namespace         = "homelab-pki"
    in_cluster_config = true
  }

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    pki = {
      source  = "registry.terraform.io/nijave/pki"
      version = "~> 1.0"
    }
  }
}

provider "kubernetes" {}
provider "pki" {}
