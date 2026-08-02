# homelab-pki/tofu/imports.tf
#
# TEMPORARY -- delete this file, locals.tf's `legacy_device_secrets` map, and
# the `legacy-*` volumes/volumeMounts in homelab-pki.yaml once the real
# cutover `tofu apply` has run successfully once. These import blocks bind
# the CA and 5 real devices' pre-existing keys/certs (from the old,
# serial-suffixed Secrets) into this config's new pki_certificate_authority /
# pki_private_key / pki_certificate resource addresses, so the cutover
# preserves them byte-identically instead of reissuing from scratch.
#
# Certificate imports read via a `kubernetes_secret` data source, `id` built
# as `base64://${base64encode(nonsensitive(...))}`. `nonsensitive(...)` is
# required (OpenTofu's `import` block rejects a sensitive `id` outright,
# confirmed against a real in-cluster Secret), and it's safe here: a
# certificate is public by design, so it appearing unmasked in `tofu plan`'s
# "Preparing import... [id=...]" log line (which is NOT redacted the way a
# resource's own sensitive-marked attributes are -- Core prints the literal
# `id` expression before any provider ever sees it) carries no real exposure.
#
# Private key imports do NOT use that pattern. A `pki_private_key`'s `id` is
# the private key itself, and `nonsensitive(base64encode(...))`-ing a real
# key would print the ENTIRE key, unmasked and fully decodable, into the
# Job's pod logs -- confirmed with a throwaway key against a real in-cluster
# Secret before writing this comment: the exact `base64://<key>` string came
# back verbatim in `tofu plan`'s output. `file://` avoids this: the `id` is
# just a path (`/legacy/<device>/tls.key`, built from `each.key`, never from
# secret data), so the log line never contains anything but a path string.
# The actual key bytes reach the container only via a `secret` volume mount
# in homelab-pki.yaml (kubelet-fetched, no RBAC needed beyond what already
# exists) -- never through a value OpenTofu could print.
#
# Rollout is staged across multiple changes, not one big-bang apply:
#   1. Ship this file with the Job/CronJob running `tofu plan` only (see
#      homelab-pki.yaml) -- safe to merge/deploy immediately, since plan
#      never mutates the cluster. Review the plan in the Job's pod logs:
#      expect "N to import", the documented one-time `private_key_pem`
#      pending-set, and creates for the brand-new kubernetes_secret/
#      pki_bundle/pki_crl resources -- no unexpected reissues.
#   2. Once that plan looks right, flip the Job/CronJob command to
#      `tofu apply -auto-approve`. This one apply imports the CA/devices,
#      destroys the now-orphaned old kubernetes_secret.cert[*]/crl[0]
#      resources (same backend, old resource addresses no longer in config),
#      and creates the new pki-<device>/pki-crl Secrets -- all atomically:
#      `tofu apply` computes its whole plan (including every data source and
#      import-target read below) before executing any create/update/destroy,
#      so reading the old Secrets' data for import always happens-before
#      their destroy in the same apply, never racing it.
#   3. Immediately after that apply succeeds, delete this file,
#      `legacy_device_secrets`, and the `legacy-*` volumes/volumeMounts in a
#      follow-up change. The data sources below read Secrets this same
#      apply destroys -- left in place, every later plan/apply (including
#      the CronJob's next 6-hourly run) would fail trying to read Secrets
#      that no longer exist.
data "kubernetes_secret" "legacy_device" {
  for_each = local.legacy_device_secrets

  metadata {
    name      = each.value
    namespace = "homelab-pki"
  }
}

import {
  to = pki_certificate_authority.ca
  id = "base64://${base64encode(nonsensitive(data.kubernetes_secret.ca.data["tls.crt"]))}"
}

import {
  for_each = local.legacy_device_secrets
  to       = pki_private_key.device[each.key]
  id       = "file:///legacy/${each.key}/tls.key"
}

import {
  for_each = local.legacy_device_secrets
  to       = pki_certificate.device[each.key]
  id       = "base64://${base64encode(nonsensitive(data.kubernetes_secret.legacy_device[each.key].data["tls.crt"]))}"
}
