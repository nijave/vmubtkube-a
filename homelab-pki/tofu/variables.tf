# homelab-pki/tofu/variables.tf
variable "namespace" {
  type    = string
  default = "homelab-pki"
}

variable "pki_secrets" {
  type    = map(object({ name = string, serial = string, data = map(string) }))
  default = {}
}

variable "crl_pem_b64" {
  type    = string
  default = ""
}
