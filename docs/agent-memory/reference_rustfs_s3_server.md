---
name: rustfs-s3-server
description: S3 server behavior and verification when aws-cli calls hang
metadata: 
  node_type: memory
  type: reference
  originSessionId: 2c9444f7-85f4-4db4-9f5a-77b0cc5b1698
---

The S3 endpoint `https://vmubthh01.s.nickv.me` (volsync restic repos, CNPG barman buckets) is **rustfs**, not MinIO.

- Obtain credentials through the repository's approved secret-management
  workflow. Keep values out of commands that print to the transcript, shell
  history, agent memory, and documentation.
- Quirk (observed 2026-07-04): aws-cli requests intermittently hang until timeout (`head-bucket`, `list-buckets`, sometimes `create-bucket`) even though the operation succeeded server-side. An approved SigV4-capable client can provide an independent verification; do not expose credentials while invoking it.
- Buckets must be created here when adding a new volsync ReplicationSource or CNPG backup destination.
