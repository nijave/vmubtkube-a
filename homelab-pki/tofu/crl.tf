# homelab-pki/tofu/crl.tf
resource "pki_crl" "ca" {
  ca_certificate_pem = pki_certificate_authority.ca.certificate_pem
  ca_private_key_pem = pki_certificate_authority.ca.private_key_pem

  next_update = "168h"

  dynamic "revoked" {
    for_each = local.revoked_serials
    content {
      serial_number = revoked.value.serial_number
      reason        = lookup(revoked.value, "reason", null)
      revoked_at    = lookup(revoked.value, "revoked_at", null)
    }
  }
}

resource "kubernetes_secret" "crl" {
  metadata {
    name      = "pki-crl"
    namespace = "homelab-pki"
  }

  binary_data = { "crl.pem" = pki_crl.ca.crl_base64 }
  type        = "Opaque"
}
