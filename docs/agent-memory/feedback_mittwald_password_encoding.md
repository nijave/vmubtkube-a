---
name: mittwald password encoding for URI use
description: Force hex encoding when a mittwald-generated password will be embedded in a URI
type: feedback
originSessionId: 7d8a2847-0a77-447f-a703-d7f6ded2e27e
---
When using `secret-generator.v1.mittwald.de/autogenerate: password` for credentials that will end up inside a URI (e.g., `mongodb://user:pass@host`, `postgres://...`, `redis://...`), also set:

```yaml
secret-generator.v1.mittwald.de/encoding: hex
secret-generator.v1.mittwald.de/length: "48"
```

**Why:** Default encoding is base64, which contains `/` and `+`. An unescaped `/` in a URI password crashes every URL parser (hit this with percona/mongodb_exporter connecting to a mongodb:// URI — "unescaped slash in password"). Hex is `[0-9a-f]`, always URL-safe, no escaping needed.

**How to apply:** Only needed for secrets consumed via URI. For secrets referenced as a raw password string (clickhouse `secretKeyRef`, HTTP basic-auth headers, etc.) the default base64 is fine.
