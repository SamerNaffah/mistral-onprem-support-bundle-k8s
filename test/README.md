# Tests

Offline, no-cluster tests for `mistral-furball.sh`.

## Run

```sh
bash test/redaction-test.sh
```

Exit code `0` = all assertions passed; non-zero = at least one failed.
Output is TAP-ish (`ok N - ...` / `not ok N - ...`).

## What `redaction-test.sh` covers

It sources the main script in **library-only mode** (`MFB_LIB_ONLY=1`, honored
by the source guard at the bottom of the script) so the redaction functions can
be called directly without contacting a cluster or running a collection. It then
plants files containing **fake** secrets into a throwaway bundle dir and asserts:

- **Regex safety net** — Hugging Face / GitHub / Slack-style / `sk-` / AWS key
  IDs / JWTs / `Bearer` tokens / sensitive `key: value` pairs / padded base64
  blobs / emails / PEM private-key blocks are each replaced with a
  `<REDACTED...>` marker, and the raw secret is gone.
- **No over-redaction** — image digests (unpadded hex) and version strings like
  `1.29.1` survive.
- **`--redact-ips`** — IPv4 addresses are redacted only when the flag is on;
  version strings still survive.
- **`--anonymize-names`** — node/pod/namespace names are replaced with stable,
  deterministic `kind-<8hex>` tokens; the same name maps to the same token across
  files; the reverse map is written **outside** the bundle and the in-bundle
  breadcrumb never contains real names.
- **Binary/empty files** are skipped without error.

Cluster-facing helpers (`get_nodes`, `kc`) are stubbed *after* sourcing, so the
name-anonymization path is exercised entirely offline.
