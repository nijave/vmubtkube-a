# homelab-pki/config.hcl
#
# Each user's `identity` block is baked into every one of that user's device
# certs (subject DN + SAN email). Field names mirror python-envoy-authz's
# ClientIdentity model exactly, so whatever you set here is what that service
# reads back. All values are plain ASCII. Every field is optional — delete a
# line to leave that attribute off the cert.
#
#   common_name                -> DN 2.5.4.3   (optional; defaults to <device>.ha.apps.somemissing.info)
#   surname                    -> DN 2.5.4.4
#   given_name                 -> DN 2.5.4.42
#   display_name               -> DN 2.16.840.1.113730.3.1.241
#   organization               -> DN 2.5.4.10
#   organizational_units       -> DN 2.5.4.11  (list, repeatable)
#   uid                        -> DN 0.9.2342.19200300.100.1.1
#   primary_email              -> SAN rfc822Name (first)
#   additional_email_addresses -> SAN rfc822Name (rest, list)
#
# NOTE: `common_name` is per-USER here, so setting it makes all of that user's
# devices share one CN; leave it unset to keep the per-device hostname CN.

revoked_serials = []

users = {
  nick = {
    key  = { algorithm = "RSA", size = 2048 }
    ekus = ["clientAuth"]
    identity = {
      # common_name                = "REPLACE_ME_nick_common_name"   # uncomment to override per-device CN
      surname                    = "REPLACE_ME_nick_surname"
      given_name                 = "REPLACE_ME_nick_given_name"
      display_name               = "REPLACE_ME_nick_display_name"
      organization               = "REPLACE_ME_nick_organization"
      organizational_units       = ["REPLACE_ME_nick_ou"]
      uid                        = "REPLACE_ME_nick_uid"
      primary_email              = "REPLACE_ME_nick_primary_email"
      additional_email_addresses = ["REPLACE_ME_nick_additional_email"]
    }
    devices = ["nick-desktop", "nick-ipad", "nick-xps", "pixel7"]
  }
  kara = {
    key  = { algorithm = "RSA", size = 2048 }
    ekus = ["clientAuth"]
    identity = {
      # common_name                = "REPLACE_ME_kara_common_name"
      surname                    = "REPLACE_ME_kara_surname"
      given_name                 = "REPLACE_ME_kara_given_name"
      display_name               = "REPLACE_ME_kara_display_name"
      organization               = "REPLACE_ME_kara_organization"
      organizational_units       = ["REPLACE_ME_kara_ou"]
      uid                        = "REPLACE_ME_kara_uid"
      primary_email              = "REPLACE_ME_kara_primary_email"
      additional_email_addresses = ["REPLACE_ME_kara_additional_email"]
    }
    devices = ["kara-iphone"]
  }
}
