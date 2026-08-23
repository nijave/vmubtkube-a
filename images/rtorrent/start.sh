#!/bin/sh

# RPC credential plumbing for the k8s migration: nginx htpasswd and the
# exporter's password file are generated at startup from $RPC_PASSWORD
# (mounted from Secret rtorrent-rpc-auth) instead of being baked into the
# image. The VM image had both baked in; that is the only functional delta.
if [ -n "$RPC_PASSWORD" ]; then
  mkdir -p /etc/nginx /var/lib/secrets
  echo -n 'admin:' > /etc/nginx/.htpasswd
  openssl passwd -apr1 "$RPC_PASSWORD" >> /etc/nginx/.htpasswd
  printf '%s' "$RPC_PASSWORD" > /var/lib/secrets/rtorrent.password
fi

(
while true; do
  flood \
      --rundir /var/lib/flood \
      --host 0.0.0.0 --port 3000
done
) &

(
while true; do
  sudo nginx
done
) &

(
while true; do
  /usr/local/bin/rtorrent-exporter \
	--rtorrent.insecure \
	--rtorrent.trackers.enabled=false \
	--rtorrent.addr http://127.0.0.1:5000/RPC2 \
	--rtorrent.username admin \
	--rtorrent.password "$(cat /var/lib/secrets/rtorrent.password)"
  sleep 1
done
) &

set -ex

mkdir -p /mnt/config/session && \
  mkdir -p /mnt/config/watch && \
  rm -f /mnt/config/session/rtorrent.lock

# exec python3 /usr/local/bin/rtorrent-runner.py
exec rtorrent -p 16312-16312
