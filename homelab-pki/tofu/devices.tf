# homelab-pki/tofu/devices.tf
resource "pki_private_key" "device" {
  for_each = local.devices

  algorithm = each.value.key.algorithm
  rsa_bits  = each.value.key.size
}

resource "pki_certificate" "device" {
  for_each = local.devices

  ca_certificate_pem = pki_certificate_authority.ca.certificate_pem
  ca_private_key_pem = pki_certificate_authority.ca.private_key_pem
  public_key_pem     = pki_private_key.device[each.key].public_key_pem

  validity = local.device_validity

  subject {
    dynamic "attribute" {
      for_each = local.device_attributes[each.key]
      content {
        oid   = provider::pki::oid(attribute.value.oid)
        value = attribute.value.value
      }
    }
  }

  san {
    dns_names = ["${each.key}.${local.device_domain}"]
    email_addresses = compact(concat(
      [lookup(each.value, "primary_email", "")],
      lookup(each.value, "additional_email_addresses", [])
    ))
  }

  # Declared explicitly -- see the comment on pki_certificate_authority.ca in
  # ca.tf for why (applies to every imported device cert; harmless for new
  # ones created fresh, since a create has no prior state to mismatch).
  basic_constraints {
    ca       = false
    critical = true
  }

  key_usage {
    usages = ["digitalSignature", "keyEncipherment"]
  }

  extended_key_usage {
    usages = each.value.ekus
  }
}

resource "pki_bundle" "device" {
  for_each = local.devices

  format          = "pkcs12"
  certificate_pem = pki_certificate.device[each.key].certificate_pem
  private_key_pem = pki_private_key.device[each.key].private_key_pem
  chain_pem       = [pki_certificate_authority.ca.certificate_pem]
  friendly_name   = each.key

  # Write-only: preserves the current (non-secret) hardcoded password
  # exactly -- never stored in state.
  password_wo         = "password"
  password_wo_version = 1
}

resource "kubernetes_secret_v1" "device" {
  for_each = local.devices

  metadata {
    name      = "pki-${each.key}"
    namespace = "homelab-pki"
    labels = {
      "pki/name"   = each.key
      "pki/serial" = pki_certificate.device[each.key].serial_number
    }
  }

  binary_data = {
    "tls.crt"         = base64encode(pki_certificate.device[each.key].certificate_pem)
    "tls.key"         = base64encode(pki_private_key.device[each.key].private_key_pem)
    "${each.key}.p12" = pki_bundle.device[each.key].content_base64
  }
  type = "Opaque"
}

# Look up a device's current serial for revocation: `tofu output device_serials`.
output "device_serials" {
  value = { for name, cert in pki_certificate.device : name => cert.serial_number }
}
