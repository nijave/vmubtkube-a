# homelab-pki/config.hcl
revoked_serials = []

users = {
  nick = {
    key              = { algorithm = "RSA", size = 2048 }
    ekus             = ["clientAuth"]
    extra_extensions = []
    devices          = ["nick-desktop", "nick-ipad", "nick-xps", "pixel7"]
  }
  kara = {
    key              = { algorithm = "RSA", size = 2048 }
    ekus             = ["clientAuth"]
    extra_extensions = []
    devices          = ["kara-iphone"]
  }
}
