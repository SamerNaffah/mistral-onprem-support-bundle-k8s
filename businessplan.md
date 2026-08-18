# Claude Code prompt — Mistral on-prem Kubernetes support bundle collector

> Paste everything below into Claude Code as your initial project brief.

---

## Project

Build an open-source **support diagnostic bundle collector** for customers running Mistral LLM deployments on **Kubernetes** (on-prem / air-gapped). A customer runs one command; the tool inspects their cluster, redacts sensitive data, and produces a **single ZIP** they can attach to a support ticket. Think Red Hat `must-gather` / `sosreport`, but scoped to Mistral-on-K8s and privacy-first.

The customer will install it from GitHub (git clone or download a release), **read the script** (this must be auditable), and run it. Output is one ZIP for troubleshooting.

## Non-negotiable constraints

1. **Language: Bash + `kubectl`.** POSIX-friendly `bash`, no compiled binary, no Python/Node runtime. The only hard dependency is `kubectl` (which the customer already has). Optional tools (`helm`, `jq`, `zip`) must be detected and degrade gracefully if missing. The point is that a security team can read the whole thing top to bottom.
2. **Strictly read-only.** The tool must NEVER mutate the cluster. No `apply`, `create`, `patch`, `delete`, `edit`, `scale`, `label`, `annotate`, `cordon`, `exec` that writes. Only `get`, `describe`, `logs`, `top`, `version`, and **read-only** `exec` (e.g. running `nvidia-smi`). If you ever need a write verb, stop and flag it instead.
3. **Privacy-first (see dedicated section).** When unsure whether something is sensitive, redact or skip it.
4. **Air-gap friendly.** Everything runs locally against the customer's cluster and writes a local ZIP. No network calls, no upload, no telemetry, no phone-home. Auto-upload is explicitly out of scope for v0.
5. **Kubernetes only for v0.** Structure the code so an OpenShift (`oc`) variant can be added later, but do not implement it now.

## What to collect

Organize collected files into a clean directory tree inside the ZIP. All commands below are read-only.

### `cluster/`
- `kubectl version` (client + server), detected distro/flavour (from kubelet version + node labels).
- `kubectl get nodes -o wide`; per-node `describe` (capacity, allocatable, labels, taints, conditions).
- Relevant cluster-scoped info: storage classes, CNI hints from node labels. Keep it lightweight.

### `gpu/`
GPU data is the #1 source of on-prem inference failures (driver/CUDA mismatch, device plugin misbehaving). Note: **`nvidia-smi` is not directly available via kubectl** — collect it via, in order of preference:
- **Node labels** from GPU Operator / Node Feature Discovery (`nvidia.com/gpu.product`, `nvidia.com/cuda.driver.*`, `nvidia.com/mig.*`) — always available if the operator is installed.
- **`nvidia-device-plugin` DaemonSet** status + pod status + recent logs.
- **NVIDIA GPU Operator** pods/status if present.
- **Best-effort read-only exec** of `nvidia-smi` inside a running GPU/serving pod (try; capture output if it works, record "unavailable" if not — never fail the run over this).
- **DCGM exporter** `/metrics` if present (best-effort).

### `workload/`
The Mistral serving deployment. Auto-detect the workload in the target namespace (Deployment/StatefulSet whose pods request `nvidia.com/gpu`), or take it from a flag.
- Workload spec (Deployment/StatefulSet/Pod): image tags/digest → **model + version**, container args, resource requests/limits, replica count.
- **Serving-engine config** — this is where "why is it OOMing / slow" lives. Extract from container args / env / mounted ConfigMaps: `tensor-parallel-size`, `max-model-len` / `max_model_len`, `quantization` / `dtype`, `gpu-memory-utilization`, KV-cache settings, batch settings.
- **Helm** (if `helm` present): `helm list -n <ns>`, `helm get values <release>`, `helm get manifest <release>` — **all passed through the redactor** (values commonly contain registry creds / HF tokens).
- Mounted ConfigMaps referenced by the workload (redacted).

### `state/` and `logs/`
- `kubectl get events` for the namespace, sorted by timestamp, bounded window.
- Pod status: restart counts, `lastState.terminated.reason` (detect **OOMKilled / CrashLoopBackOff**), readiness/liveness from `describe`.
- Recent logs for serving + init containers: `kubectl logs --since=<window> --tail=<N>`, **both current and previous** (`-p`) containers. Bounded — never dump unbounded logs.

### `metrics/`
- `kubectl top nodes` and `kubectl top pods -n <ns>` (needs metrics-server → best-effort).
- Serving metrics: vLLM/TGI-style Prometheus `/metrics` scraped read-only from within a pod if exposed (best-effort).

## Privacy / redaction (the core of this tool)

Design principle: **the primary control is NOT collecting secrets, not clever regex.** Layer it:

1. **Never collect, ever:**
   - Any prompt / completion / request / response **content**. This tool touches config and infra only, never inference payloads.
   - `Secret` object **values**. Record only Secret **names and key names** (never `data`/`stringData` values), or skip Secrets entirely.

2. **Wipe by default (keep the key, drop the value):**
   - **All environment variable values** in pod/workload specs. Env vars are the #1 leak vector — keep `NAME=<REDACTED>`, never the value. (Exception: a short allowlist of known-safe, non-sensitive keys like `TENSOR_PARALLEL_SIZE`, `MAX_MODEL_LEN` may keep values — make this list explicit and easy to read.)

3. **Regex safety-net pass** over every collected file before zipping (this is the net, not the main defense). Redact at minimum: HF tokens (`hf_...`), bearer/JWT tokens, AWS-style keys, anything matching `*_TOKEN|*_KEY|*_SECRET|*_PASSWORD|*_CREDENTIAL`, private key blocks, long base64 blobs over a length threshold, email addresses. Keep the redaction patterns in a **single, human-readable file** so a security reviewer can see exactly what's scrubbed.

4. **Optional flags:**
   - `--anonymize-names` (off by default): hash node/pod/namespace names consistently. Off by default because names are usually needed for troubleshooting; on for the paranoid.
   - IP address redaction: configurable.

5. **Transparency for the customer:**
   - The ZIP must be **openable and inspectable** — plain text/JSON, no obfuscation.
   - Emit a **redaction summary**: count of values redacted per file / total.
   - Include a `README-INSIDE.txt` in the ZIP stating what was collected, what was redacted, that no inference content or secret values are included, and that they should feel free to inspect before sending.

## Output

- A single archive: `mistral-support-bundle-<context-or-cluster>-<UTC-timestamp>.zip`.
- Prefer `zip`; if unavailable, fall back to `tar.gz` and tell the user.
- **Flow:** collect into a temp working dir → run **one** redaction pass over the whole dir → generate summary → archive → clean up temp dir.
- Inside the ZIP:
  - The directory tree above.
  - `manifest.json`: tool version, timestamp, kubectl/server versions, flags used, target namespace, list of collectors that ran/failed, redaction counts.
  - `SUMMARY.txt`: human-readable at-a-glance — k8s version, node & GPU count, detected model + serving config (TP size, max-model-len, quant), top red flags (OOMKills, restart counts, driver mismatch hints), redaction summary. This is what a support engineer reads first.
  - `README-INSIDE.txt` (privacy statement, above).

## CLI / UX

- `mistral-support-bundle.sh [flags]`
- Flags:
  - `-n, --namespace <ns>` (target namespace; if omitted, auto-detect GPU workloads and prompt/choose)
  - `-o, --output <path>` (output dir/file; default: cwd)
  - `--since <dur>` (log window, default e.g. `1h`)
  - `--tail <n>` (max log lines per container, sane default)
  - `--anonymize-names` (default off)
  - `--no-redact` (default off; **discouraged**, only for debugging the tool itself — must print a loud warning)
  - `--dry-run` (list what *would* be collected, run nothing)
  - `-h, --help`
- **Preflight:** verify `bash`, `kubectl` present; verify cluster reachable; check current context and **echo it prominently** ("collecting from context: X — correct? [proceed]"); detect optional tools and report which collectors will be skipped. Fail fast with clear messages.
- Never hard-fail on a single collector — record the failure in `manifest.json` and continue. A partial bundle is still useful.
- Clear progress output; final line prints the ZIP path and the redaction summary.

## Repository deliverables

- `mistral-support-bundle.sh` (main entrypoint). Split reusable pieces into a readable `lib/` (e.g. `lib/collect.sh`, `lib/redact.sh`, `lib/redact-patterns.txt`, `lib/archive.sh`) if it improves auditability — but keep it simple.
- `README.md`: what it is, install (git clone / download release), usage + flags, **exactly what it collects and what it redacts** (privacy section front and center), example output tree, requirements, "how to inspect before sending."
- `LICENSE`: Apache-2.0.
- `examples/`: a sample (fully synthetic, pre-redacted) output tree + `SUMMARY.txt` so support engineers and customers know what to expect.
- Optional: a `test/` harness using mocked `kubectl` output so the redaction pass can be tested without a live cluster.

## Build order (milestones — do these in sequence, keep each runnable)

1. **Skeleton:** arg parsing, help, preflight (kubectl + context echo + optional-tool detection), temp-dir setup, `--dry-run`, ZIP packaging of an empty tree, `manifest.json` scaffolding.
2. **Cluster + nodes + GPU** collectors (`cluster/`, `gpu/`), including the nvidia-smi-via-exec best-effort logic.
3. **Workload + Helm + serving-config extraction** (`workload/`).
4. **State + logs + events** (`state/`, `logs/`), with OOMKill / CrashLoop detection.
5. **Metrics** (`metrics/`), all best-effort.
6. **Redaction engine** applied as a single pass over the temp dir before archiving; env-value wipe + Secret-skip + regex safety net + redaction counts. Add the `test/` harness here.
7. **SUMMARY.txt generator**, `README-INSIDE.txt`, README.md, examples, LICENSE, polish.

## Guardrails while building

- If any step seems to require a cluster-mutating verb, a network upload, or collecting inference content, **stop and ask** — those are out of scope by design.
- Prefer clarity and auditability over cleverness. A reviewer reading this cold should understand every command and every redaction.
- Ask me before adding any new external dependency beyond `kubectl` / `helm` / `jq` / `zip`.

## Progress

- [x] Milestone 1 — skeleton: arg parsing, help, preflight (context echo + optional-tool detection), namespace auto-detect, temp dir, `--dry-run`, zip/tar.gz packaging, `manifest.json`
- [x] Milestone 2 — `cluster/` + `gpu/` collectors (nvidia-smi via read-only exec, DCGM via pod proxy)
- [x] Milestone 3 — `workload/` + Helm + serving-config extraction (tailored to the `mistral-inference-engine` chart)
- [x] Milestone 4 — `state/` + `logs/` + OOMKill/CrashLoop detection
- [x] Milestone 5 — `metrics/` (kubectl top nodes/pods; serving Prometheus /metrics via read-only pod proxy — all best-effort)
- [x] Milestone 6 — redaction engine (in-script regex safety net + `--redact-ips` + `--anonymize-names` for content, filenames, paths & manifest notes; per-file counts in `redaction-summary.txt` and `manifest.json`) + `test/` harness
- [x] Milestone 7 — `SUMMARY.txt`, `README-INSIDE.txt`, README, examples, LICENSE, polish
