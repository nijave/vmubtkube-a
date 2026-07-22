# homelab-pki/config.hcl
#
# oids: registry mapping a human-readable name -> the real OID. This is the
# catalog of every custom extension the certs can carry; add one entry per OID.
# Fill in each REPLACE_ME_OID_* with the actual dotted-decimal OID.
#   oid      = dotted-decimal string, e.g. "1.3.6.1.4.1.<your-arc>.1"
#   critical = true | false
oids = {
  user_id = { oid = "REPLACE_ME_OID_user_id", critical = false }
  # Add every other OID you want available here, e.g.:
  # role     = { oid = "REPLACE_ME_OID_role",     critical = false }
  # tenant   = { oid = "REPLACE_ME_OID_tenant",   critical = false }
}

revoked_serials = []

# Each user lists a value for every OID it should carry. Keys are the names from
# `oids` above. Values are PLAIN ASCII strings (encoded as an ASN.1 UTF8String at
# issue time) — not base64. Omit an OID entry to leave that extension off a user.
users = {
  nick = {
    key  = { algorithm = "RSA", size = 2048 }
    ekus = ["clientAuth"]
    extra_extensions = {
      user_id = "REPLACE_ME_ASCII_nick_user_id"
    }
    devices = ["nick-desktop", "nick-ipad", "nick-xps", "pixel7"]
  }
  kara = {
    key  = { algorithm = "RSA", size = 2048 }
    ekus = ["clientAuth"]
    extra_extensions = {
      user_id = "REPLACE_ME_ASCII_kara_user_id"
    }
    devices = ["kara-iphone"]
  }
}
