---
name: private-registry-nickv
description: private container registry at registry.apps.nickv.me hosts forked/patched images for this cluster
metadata: 
  node_type: memory
  type: reference
  originSessionId: f172211b-5ef8-4420-bf69-3fb2d3bb7b61
---

`registry.apps.nickv.me` is the user's private container registry. It hosts forked/patched versions of upstream images (e.g., `registry.apps.nickv.me/qdm12/gluetun:latest` is a patched gluetun). When you see this hostname in a manifest's `image:` field, assume the image is a local fork rather than a vanilla upstream pull-through.
