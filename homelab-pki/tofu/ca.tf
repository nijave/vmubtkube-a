# The CA cert+key are delivered from Bitwarden via ExternalSecret into the
# `pki-ca` Secret (never in git) -- see homelab-pki.yaml. This resource
# never regenerates or re-signs the CA.
data "kubernetes_secret_v1" "ca" {
  metadata {
    name      = "pki-ca"
    namespace = "homelab-pki"
  }
}

resource "pki_certificate_authority" "ca" {
  private_key_pem = data.kubernetes_secret_v1.ca.data["tls.key"]

  validity      = "175320h"
  serial_number = "4d71d760878eb0a8831ce2e1d6028f61f1fc7d5f"

  subject {
    attribute {
      oid   = provider::pki::oid("organizationalUnit")
      value = "apps"
    }
    attribute {
      oid   = provider::pki::oid("organization")
      value = "homelab"
    }
  }

  # Declared explicitly, not omitted, even though they equal this
  # resource's schema defaults: an omitted block is null, and re-importing
  # this CA after a state loss would then plan as a mismatch -- not a
  # no-op -- forcing a reissue with a fresh not_before.
  basic_constraints {
    ca       = true
    critical = true
  }

  key_usage {
    critical = true
    usages   = ["keyCertSign", "crlSign"]
  }

  name_constraints {
    permitted_dns_domains = ["ha.apps.somemissing.info", ".ha.apps.somemissing.info"]
  }
}

output "ca_certificate_pem" {
  value = pki_certificate_authority.ca.certificate_pem
}
