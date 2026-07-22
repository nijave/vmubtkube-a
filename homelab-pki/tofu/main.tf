# homelab-pki/tofu/main.tf
terraform {
  required_version = ">= 1.11.0"
  backend "kubernetes" {
    secret_suffix     = "homelab-pki"
    namespace         = "homelab-pki"
    in_cluster_config = true
  }
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.0" }
  }
}

provider "kubernetes" {}

resource "kubernetes_secret" "cert" {
  for_each = var.pki_secrets
  metadata {
    name      = each.key
    namespace = var.namespace
    labels    = { "pki/name" = each.value.name, "pki/serial" = each.value.serial }
  }
  # data values arrive already base64-encoded from the reconciler (tls.crt/
  # tls.key are text but the <name>.p12 bundle is binary). The resource's
  # `data` attribute expects RAW (non-base64) strings and base64-encodes them
  # itself, so HCL's base64decode() would be needed first -- but that fails
  # on the p12 bytes with "the result of decoding the provided string is not
  # valid UTF-8" (verified via `tofu apply`), since HCL's base64decode()
  # requires the decoded bytes to themselves be valid UTF-8 text, which
  # binary PKCS12 data is not. `binary_data` is the resource's attribute for
  # exactly this case: its values are passed through as already-base64 (per
  # `tofu providers schema`: "A map of the secret data in base64 encoding.
  # Use this for binary data."), so the reconciler's map is passed straight
  # through with no decode/re-encode round trip.
  binary_data = each.value.data
  type        = "Opaque"
}

resource "kubernetes_secret" "crl" {
  count = var.crl_pem_b64 == "" ? 0 : 1
  metadata {
    name      = "pki-crl"
    namespace = var.namespace
  }
  binary_data = { "crl.pem" = var.crl_pem_b64 }
  type        = "Opaque"
}

output "issued" {
  value = sort(keys(var.pki_secrets))
}
