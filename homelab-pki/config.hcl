# homelab-pki/config.hcl
#
# oids: registry mapping a human-readable name -> the real OID. Users reference
# extensions by these names (below), so the dotted-decimal numbers live in one
# place. Fill in each REPLACE_ME_OID_* with the actual dotted-decimal OID.
#   oid      = dotted-decimal string, e.g. "1.3.6.1.4.1.<your-arc>.1"
#   critical = true | false
oids = {
  user_id = { oid = "REPLACE_ME_OID_USER_ID", critical = false }
  # add more named OIDs here, e.g.:
  # device_class = { oid = "REPLACE_ME_OID_DEVICE_CLASS", critical = false }
}

revoked_serials = []

users = {
  nick = {
    key  = { algorithm = "RSA", size = 2048 }
    ekus = ["clientAuth"]
    # plain map: OID name (a key from `oids`) -> value_b64.
    # value_b64 = base64 of the extension's DER value bytes.
    extra_extensions = {
      user_id = "REPLACE_ME_NICK_USER_ID_VALUE_B64"
    }
    devices = ["nick-desktop", "nick-ipad", "nick-xps", "pixel7"]
  }
  kara = {
    key  = { algorithm = "RSA", size = 2048 }
    ekus = ["clientAuth"]
    extra_extensions = {
      user_id = "REPLACE_ME_KARA_USER_ID_VALUE_B64"
    }
    devices = ["kara-iphone"]
  }
}
