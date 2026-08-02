# Bundles OpenTofu + the tofu/ config; entrypoint is /bin/sh (homelab-pki.yaml
# runs `tofu init && tofu apply` in the Job/CronJob).
#
# NOTE on base image: `ghcr.io/opentofu/opentofu:1.12` (the full image)
# cannot be used as a Dockerfile FROM base -- as of OpenTofu 1.10 it ships an
# ONBUILD trigger (`ONBUILD RUN exit 1`) that deliberately fails any build
# that FROMs it, per https://opentofu.org/docs/intro/install/docker/ ("direct
# usage of the official images is no longer supported"). The supported
# pattern (Method 1 in that doc) is a multi-stage build that copies the
# `tofu` binary out of the `-minimal` tag (a scratch image containing only
# the static binary at /usr/local/bin/tofu, no ONBUILD trap) onto a plain
# alpine base -- which is what this Dockerfile does below.
#
# Build + push (manual, until CI step lands):
#   cd homelab-pki
#   docker build -t registry.apps.nickv.me/nijave/homelab-pki:0.2.5 .
#   docker push registry.apps.nickv.me/nijave/homelab-pki:0.2.5

FROM ghcr.io/opentofu/opentofu:1.12-minimal AS tofu

FROM alpine:3.24.1
COPY --from=tofu /usr/local/bin/tofu /usr/local/bin/tofu

RUN apk add --no-cache ca-certificates=20260611-r0

COPY tofu/ /app/tofu/

WORKDIR /app
ENTRYPOINT ["/bin/sh"]
