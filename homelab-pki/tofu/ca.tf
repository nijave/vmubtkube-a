# homelab-pki/tofu/ca.tf
#
# The CA cert+key are delivered from Bitwarden via ExternalSecret into the
# `pki-ca` Secret (never in git, never regenerated) -- see homelab-pki.yaml.
# Imported once (see the migration procedure in the design spec); this
# resource never re-signs the CA itself.
data "kubernetes_secret" "ca" {
  metadata {
    name      = "pki-ca"
    namespace = "homelab-pki"
  }
}

resource "pki_certificate_authority" "ca" {
  private_key_pem = data.kubernetes_secret.ca.data["tls.key"]

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

  # Declared explicitly even though they equal this resource's own defaults:
  # ImportState always populates these blocks from the real certificate's
  # extensions, so an omitted block plans as null -- a block-shape mismatch,
  # not a no-op -- and would force a reissue with a fresh not_before.
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
