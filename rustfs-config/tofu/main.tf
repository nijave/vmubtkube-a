terraform {
  required_version = ">= 1.11.0"

  backend "kubernetes" {
    secret_suffix     = "rustfs-config"
    namespace         = "rustfs"
    in_cluster_config = true
  }

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    minio = {
      source  = "aminueza/minio"
      version = "~> 3.46.3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

provider "kubernetes" {}

# rustfs serves MinIO's admin API, so this provider manages its buckets,
# policies and users. Root keys arrive as MINIO_USER / MINIO_PASSWORD from
# Secret rustfs/rustfs-root (see reconcile-job.yaml).
provider "minio" {
  minio_server = "s3.k8s.somemissing.info"
  minio_ssl    = true
  minio_region = "us-east-1"
}
