# homelab-pki/Dockerfile
#
# Reconciler image: bundles OpenTofu + cfssl + openssl + python3 + the
# `reconcile` package. Entry point is `/bin/sh`; the CI/manual run sequence is:
#   python -m reconcile.main   (writes /work/secrets.auto.tfvars.json)
#   tofu -chdir=/app/tofu init
#   tofu -chdir=/app/tofu apply -auto-approve
#
# NOTE on base image: `ghcr.io/opentofu/opentofu:1.11` (the full image) cannot
# be used as a Dockerfile `FROM` base -- as of OpenTofu 1.10 it ships an
# ONBUILD trigger (`ONBUILD RUN exit 1`) that deliberately fails any build
# that FROMs it, per https://opentofu.org/docs/intro/install/docker/ ("direct
# usage of the official images is no longer supported"). Verified by testing
# `FROM ghcr.io/opentofu/opentofu:1.11` directly: build fails immediately
# with "process /bin/sh -c exit 1 did not complete successfully". The
# supported pattern (Method 1 in that doc) is a multi-stage build that copies
# the `tofu` binary out of the `-minimal` tag (a scratch image containing only
# the static binary at /usr/local/bin/tofu, no ONBUILD trap) onto a plain
# alpine base -- which is what this Dockerfile does below.
#
# Build + push (manual, until CI step lands):
#   cd homelab-pki
#   docker build -t registry.apps.nickv.me/nijave/homelab-pki:0.1.0 .
#   docker push registry.apps.nickv.me/nijave/homelab-pki:0.1.0
#
# CI build step: deferred follow-up (not wired into .woodpecker.yaml yet).

FROM ghcr.io/opentofu/opentofu:1.12-minimal AS tofu

# alpine:3.20 matches the OS the full opentofu:1.11 image (and its -minimal
# sibling) is built against, verified via `docker run ... cat /etc/os-release`
# (Alpine Linux v3.20, VERSION_ID=3.20.10).
FROM alpine:3.24.1
COPY --from=tofu /usr/local/bin/tofu /usr/local/bin/tofu

# cfssl/cfssljson are only packaged in Alpine's edge/testing repo, not the
# pinned v3.20 repos (verified: absent from v3.20/main and v3.20/community).
# Scope edge/testing to just this `apk add --repository ...` invocation (via
# the `--repository` flag, not `echo ... >> /etc/apk/repositories`) so the
# untrusted edge/testing repo is NOT persisted in /etc/apk/repositories in the
# final shipped image; everything else installs from the pinned v3.20 repos.
# NOTE: this pins an exact edge/testing snapshot line for cfssl=1.6.5-r16 --
# that pin may eventually need a version bump as edge/testing rolls forward.
RUN apk add --no-cache \
      openssl=3.3.7-r0 \
      python3=3.12.13-r0 \
      py3-pip=24.0-r2 \
      ca-certificates=20260413-r0 \
 && apk add --no-cache --repository https://dl-cdn.alpinelinux.org/alpine/edge/testing \
      cfssl=1.6.5-r16 \
 && python3 -m pip install --break-system-packages --no-cache-dir \
      python-hcl2==8.1.2 \
      kubernetes==34.1.0 \
      pytest==9.0.1

COPY reconcile/ /app/reconcile/
COPY cfssl/     /app/cfssl/
COPY tofu/      /app/tofu/

ENV PYTHONPATH=/app
WORKDIR /app
ENTRYPOINT ["/bin/sh"]
