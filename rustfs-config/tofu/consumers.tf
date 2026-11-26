locals {
  # One entry per consumer. The key is the rustfs user name (its access key)
  # and the bucket name. Example:
  #
  #   immich = {
  #     namespace = "immich"   # where Secret s3-<key> is written
  #     access    = "readwrite" # or "readonly"
  #   }
  #
  # The consumer namespace needs a RoleBinding to ClusterRole
  # rustfs-config-secret-writer (see README.md) before the entry is added.
  consumers = {}

  policy_actions = {
    readwrite = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    readonly = ["s3:GetObject"]
  }
}

# force_destroy stays false: removing a consumer whose bucket still holds
# objects fails the apply instead of deleting data.
resource "minio_s3_bucket" "consumer" {
  for_each = local.consumers
  bucket   = each.key
}

resource "minio_iam_policy" "consumer" {
  for_each = local.consumers
  name     = "consumer-${each.key}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
        Resource = ["arn:aws:s3:::${minio_s3_bucket.consumer[each.key].bucket}"]
      },
      {
        Effect   = "Allow"
        Action   = local.policy_actions[each.value.access]
        Resource = ["arn:aws:s3:::${minio_s3_bucket.consumer[each.key].bucket}/*"]
      },
    ]
  })
}

resource "random_password" "consumer" {
  for_each = local.consumers
  length   = 40
  special  = false
}

resource "minio_iam_user" "consumer" {
  for_each = local.consumers
  name     = each.key
  secret   = random_password.consumer[each.key].result
}

resource "minio_iam_user_policy_attachment" "consumer" {
  for_each    = local.consumers
  user_name   = minio_iam_user.consumer[each.key].id
  policy_name = minio_iam_policy.consumer[each.key].id
}

resource "kubernetes_secret_v1" "consumer" {
  for_each = local.consumers
  metadata {
    name      = "s3-${each.key}"
    namespace = each.value.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "rustfs-config"
    }
  }
  data = {
    AWS_ACCESS_KEY_ID     = minio_iam_user.consumer[each.key].name
    AWS_SECRET_ACCESS_KEY = random_password.consumer[each.key].result
    AWS_ENDPOINT_URL      = "https://s3.k8s.somemissing.info"
    AWS_REGION            = "us-east-1"
    BUCKET                = minio_s3_bucket.consumer[each.key].bucket
  }
}
