# Known limitations

This tool is deliberately conservative and auditable rather than clever. The
primary privacy controls are **not collecting** secrets in the first place and
**wiping environment-variable values at collection time**. The regex pass
(`build_redaction_sed` in `mistral-furball.sh`) is a defence-in-depth
*backstop*, not the main defence. That backstop has real limits — documented
here so operators inspect bundles with the right expectations.

As of **v0.1.0**.

## Redaction (regex safety net)

The rules live inline in `build_redaction_sed`, written to `redact.sed` in the
temp working dir and applied with `sed -E`. A reviewer can read every rule in
one place.

- **Line-oriented.** Redaction runs `sed -E` line by line. A secret spanning
  multiple lines is not matched as a unit. PEM private keys are the exception:
  the `BEGIN/END PRIVATE KEY` block is collapsed to a single marker. An
  arbitrary multi-line secret in another format could slip through.
- **The base64 rule requires padding.** It matches base64 blobs of length ≥ 24
  that end in `=`/`==`. This is intentional — it keeps `sha256:` image digests,
  hex IDs, and unpadded identifiers readable — but an unpadded base64 secret is
  not caught by that rule (it may still be caught by a more specific token rule
  if its shape matches, e.g. `hf_`, `ghp_`, `AKIA…`, JWT).
- **Shape/length thresholds can miss short or unusual secrets.** Token rules key
  off known prefixes and lengths (`hf_`, `gh[pousr]_`, `xox[baprs]-`, `sk-`,
  AWS key-id prefixes, JWT `eyJ…`). A secret that matches no known shape and
  does not sit under a sensitive-looking key name can survive.
- **Key/value rule is key-name driven.** The `key: value` / `key = value` rule
  only wipes the value when the key name contains a sensitive fragment
  (`token`, `secret`, `password`, `passwd`, `credential(s)`, `api[_-]key`,
  `access[_-]key`, `key`). A sensitive value under an unexpected key name is
  missed; a value with embedded spaces, commas, or `}` is only redacted up to
  the first such character.
- **`/` is the `sed` substitution delimiter.** Rules use `s/…/…/`, so a pattern
  or replacement containing a literal `/` needs escaping. Keep this in mind when
  adding rules.
- **`--no-redact` disables this pass entirely.** Use it only to debug the tool,
  never on a bundle you intend to send.

**Mitigation:** the archive is plain text — always inspect it (grep for your own
tokens, domains, and hostnames) before sending.

## `--anonymize-names`

Effective in this build: node, pod, and target-namespace names are replaced with
stable `kind-<8 hex>` tokens across file content, file names, and directory
names, and the token → real-name map is written **next to** the archive (never
inside it). Limits:

- **Fixed-string substring replacement.** Names are matched as substrings
  (longest-first to avoid corrupting longer names). A very short or very generic
  name could still over-match unrelated text.
- **Scope is nodes, pods, and the target namespace only.** Other identifiers —
  PVC/Service/ConfigMap names, image repositories, cluster domains, IP addresses
  (unless `--redact-ips`) — are **not** anonymized.
- **Pods are enumerated once** from the target namespace at map-build time; a pod
  name that appears in logs but no longer exists at collection time is not
  mapped.

## Output / scope

- **Kubernetes only.** An OpenShift (`oc`) variant is designed for but not
  implemented.
- **Best-effort collectors.** `nvidia-smi` (via read-only `exec`), DCGM
  `/metrics`, serving `/metrics`, and `kubectl top` all depend on cluster state
  (running GPU pods, metrics-server, exporters). When unavailable they are
  recorded as skipped/partial rather than failing the run.
- **GPU vendor coverage.** GPU collection targets NVIDIA (GPU Operator / Node
  Feature Discovery labels, `nvidia.com/gpu`). Other accelerators are not
  covered.
- **Serving-config extraction is tuned for the `mistral-inference-engine`
  chart.** Non-standard deployments may surface fewer parsed values (the raw
  spec is still collected).

## Platform / portability

- Targets **bash 3.2+** (macOS system bash) and POSIX-ish `grep`/`sed`/`awk`.
  Exotic userlands (e.g. BusyBox) are untested.
- Redaction runs per file, per rule. On very large bundles this is linear but
  not parallelized.

## Reporting

Found a leak the redactor missed, or a false positive that shredded a useful
diagnostic? Open an issue with a **synthetic** reproduction (never paste a real
secret) and, if possible, a proposed rule change to `build_redaction_sed`.
