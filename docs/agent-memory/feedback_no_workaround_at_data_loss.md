---
name: don't strip declarative fields to work around tooling bugs
description: rejected suggestion to remove BGPConfiguration.serviceClusterIPs from git as a workaround for an Argo SMD bug
type: feedback
originSessionId: 759ae1ed-d669-42e2-b247-717183ee9894
---
Don't propose removing important declarative fields from git just to work around tooling/library bugs. If a field is part of the desired state (e.g. `BGPConfiguration.serviceClusterIPs` for Calico BGP), keep it managed declaratively — even if a downstream tool (Argo/SMD) currently fails on it.

**Why:** Loss of declarative config is worse than a noisy SyncError on a single resource. The user pushed back when I suggested moving `serviceClusterIPs` to out-of-band kubectl management to suppress an Argo gitops-engine SMD bug.

**How to apply:** When a sync error is caused by an upstream library bug, prefer (a) file the upstream bug, (b) tolerate the localized error, (c) narrow workarounds (annotations, ignoreDifferences). Do not propose deleting the field from git as a "fix".
