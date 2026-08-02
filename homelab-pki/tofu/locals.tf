# homelab-pki/tofu/locals.tf
#
# Devices/identities are native Terraform data, not a separate config.hcl +
# ConfigMap (that required hand-syncing two copies of the same data).
# Adding or removing a device means editing this file and rebuilding the
# image (see homelab-pki/README.md).

locals {
  users = {
    nick = {
      key  = { algorithm = "RSA", size = 2048 }
      ekus = ["clientAuth"]
      identity = {
        surname                    = "Venenga"
        given_name                 = "Nick"
        display_name               = "Nick V"
        organization               = "homelab"
        uid                        = "nick"
        primary_email              = "nick@venenga.com"
        additional_email_addresses = ["nijave@gmail.com"]
      }
      devices = ["nick-desktop", "nick-ipad", "nick-xps", "pixel7"]
    }
    kara = {
      key  = { algorithm = "RSA", size = 2048 }
      ekus = ["clientAuth"]
      identity = {
        surname       = "Gilmore"
        given_name    = "Kara"
        display_name  = "Kara G"
        organization  = "homelab"
        uid           = "kara"
        primary_email = "karakgilmore@gmail.com"
      }
      devices = ["kara-iphone"]
    }
  }

  # Flatten users -> devices to device name -> merged identity + key/ekus,
  # so for_each can key on a stable identifier (device name) instead of a
  # provider-computed value like serial number.
  devices = merge([
    for uname, u in local.users : {
      for d in u.devices : d => merge(u.identity, {
        user = uname
        key  = u.key
        ekus = u.ekus
      })
    }
  ]...)

  device_domain   = "ha.apps.somemissing.info"
  device_validity = "175320h" # 20 years, matching the existing certificates

  # Ordered DN attribute list per device (commonName, uid, displayName,
  # givenName, surname, organization, then any organizationalUnits) --
  # order matters for byte-identical import; skips unset optional fields.
  device_attributes = {
    for name, d in local.devices : name => concat(
      [{ oid = "commonName", value = lookup(d, "common_name", "${name}.${local.device_domain}") }],
      lookup(d, "uid", null) != null ? [{ oid = "uid", value = d.uid }] : [],
      lookup(d, "display_name", null) != null ? [{ oid = "displayName", value = d.display_name }] : [],
      lookup(d, "given_name", null) != null ? [{ oid = "givenName", value = d.given_name }] : [],
      lookup(d, "surname", null) != null ? [{ oid = "surname", value = d.surname }] : [],
      lookup(d, "organization", null) != null ? [{ oid = "organization", value = d.organization }] : [],
      [for ou in lookup(d, "organizational_units", []) : { oid = "organizationalUnit", value = ou }]
    )
  }

  # Revoke a device: add { serial_number = "<serial>", reason = "..." } here
  # (look up the current serial via `tofu output device_serials`), then
  # rebuild/push/apply. See homelab-pki/README.md.
  revoked_serials = []

  # Pre-migration per-device Secret names, keyed by the new device name --
  # used only by imports.tf to bind each device's existing key/cert into the
  # new pki_private_key/pki_certificate resource addresses during the
  # one-time cutover. TEMPORARY: once the real `tofu apply` cutover has run
  # successfully once (old Secrets destroyed, new ones created), this map
  # and imports.tf must be deleted -- every subsequent plan/apply would
  # otherwise fail trying to read Secrets that no longer exist. See
  # imports.tf and the design spec's cutover procedure.
  legacy_device_secrets = {
    "kara-iphone"  = "pki-kara-iphone-2000"
    "nick-desktop" = "pki-nick-desktop-2001"
    "nick-ipad"    = "pki-nick-ipad-2002"
    "nick-xps"     = "pki-nick-xps-2003"
    "pixel7"       = "pki-pixel7-2004"
  }
}
