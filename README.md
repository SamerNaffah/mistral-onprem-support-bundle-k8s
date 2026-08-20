# mistral-furball

A single, dependency-light Bash script that collects a **read-only, redacted
diagnostic bundle** from a Kubernetes cluster running a Mistral LLM deployment.
It produces one local archive you can attach to a support ticket — with **no
cluster mutation, no upload, and no telemetry**.

- One file: `mistral-furball.sh`. No install, no runtime dependencies
  beyond `kubectl` and a POSIX shell.
- Targets **bash 3.2+** (works on stock macOS) and `set -u` safe.
- Everything in the bundle is plain text or JSON. Inspect it before you send it.

## Why

On-prem and air-gapped Mistral deployments fail in the usual Kubernetes ways —
wrong driver, missing device plugin, OOMKills, bad serving flags. Getting the
right diagnostic context out of a locked-down cluster, *without* leaking
prompts, secrets, or customer data, is slow and error-prone. This tool
standardises that first data pull: it knows where a Mistral serving stack lives,
grabs the relevant read-only state, and scrubs it on the way out.

Think Red Hat `must-gather` / `sosreport`, scoped to Mistral-on-Kubernetes and
built so a security team can read the whole script top to bottom before running
it. The only `kubectl` verbs used are `get`, `describe`, `logs`, `top`,
`version`, and `config current-context`, plus a best-effort read-only `exec` of
`nvidia-smi` in an already-running GPU pod and read-only pod-proxy `GET`s for
metrics. No `apply`/`create`/`patch`/`delete`/`edit`/`scale`/`cordon`.

## How it works

A run is a short, linear pipeline — every step is read-only and local:

1. **Preflight.** Verify `kubectl` is present and the cluster is reachable,
   detect optional tools (`helm`/`jq`/`zip`), then echo the current context and
   ask you to confirm before touching anything (skip with `-y`).
2. **Resolve namespace.** Use `-n`, or auto-detect namespaces whose pods request
   `nvidia.com/gpu` and prompt you to pick one.
3. **Collect** into a temporary working directory: `cluster/`, `gpu/`,
   `workload/`, `state/`, `logs/`, `metrics/`. Each collector is best-effort — a
   failure is recorded in `manifest.json` and the run continues, so a partial
   bundle is still useful.
4. **Redact once.** A single pass scrubs the entire working directory before
   anything is archived (see [Redaction](#redaction)).
5. **Summarize.** Generate `SUMMARY.txt`, `README-INSIDE.txt`, and
   `manifest.json` from the already-redacted tree.
6. **Archive and clean up.** Pack a single `.zip` (or `.tar.gz`) and delete the
   temp dir. The only artifact left on disk is the archive — plus a local
   name-map file if you used `--anonymize-names`.

## What it collects

```
cluster/    kubectl + Kubernetes versions, nodes, storage classes, distro/CNI hints
gpu/        GPU node labels/capacity, device plugin, GPU Operator, nvidia-smi, DCGM
workload/   serving Deployment/StatefulSet spec, images, resources, engine args,
            referenced ConfigMaps, Helm values
state/      namespace events, pod/container status, OOMKill/CrashLoop detection
logs/       bounded recent logs (current + previous containers)
metrics/    kubectl top nodes/pods, serving /metrics (best-effort)
manifest.json        machine-readable run record
SUMMARY.txt          at-a-glance findings a support engineer reads first
README-INSIDE.txt    what is (and is not) in the bundle
redaction-summary.txt per-file count of scrubbed values
```

## What it never collects

- **No** prompt / completion / request / response content. Inference payloads
  are never touched.
- **No** Secret values. At most, Secret and key *names* are recorded.
- **No** environment-variable values, except a short audited allow-list of
  non-sensitive serving parameters (e.g. `TENSOR_PARALLEL_SIZE`, `MAX_MODEL_LEN`).

## Redaction

A single redaction pass runs over every file *before* archiving:

- Environment-variable values are wiped.
- A regex safety net scrubs tokens, keys, JWTs, private-key blocks, padded
  base64 blobs, and email addresses.
- `--redact-ips` additionally scrubs IPv4 addresses (off by default — IPs
  usually help troubleshooting).
- `--anonymize-names` consistently hashes node/pod/namespace names in file
  content, filenames, paths, and `manifest.json` notes. The reverse map is kept
  **outside** the archive, next to it on the machine that ran the tool.

Per-file counts land in `redaction-summary.txt` and the total in `manifest.json`.

## Install

No build step and nothing to compile. Clone the repo (or download a release) and
run the script in place:

```bash
git clone https://github.com/SamerNaffah/mistral-onprem-support-bundle-k8s.git
cd mistral-onprem-support-bundle-k8s
chmod +x mistral-furball.sh   # if needed
./mistral-furball.sh --help
```

For an air-gapped host, copy `mistral-furball.sh` across on any medium you
already trust and run it there — the redaction patterns are inline, so there is
a single file and nothing to fetch at runtime.

## Usage

```bash
# Simplest: auto-detect the GPU namespace, write a .zip to the current dir
./mistral-furball.sh

# Target a namespace and output path
./mistral-furball.sh -n mistral -o ./bundles/

# Preview what would be collected, without contacting the cluster
./mistral-furball.sh --dry-run

# Extra privacy for sharing outside your org
./mistral-furball.sh -n mistral --anonymize-names --redact-ips
```

### Flags

| Flag | Description |
| --- | --- |
| `-n, --namespace <ns>` | Target namespace. If omitted, GPU workloads are auto-detected and you are prompted to choose. |
| `-o, --output <path>` | Output directory, or explicit file ending in `.zip` / `.tar.gz`. Default: current directory. |
| `--since <dur>` | Log window for `kubectl logs` (default: `1h`). |
| `--tail <n>` | Max log lines per container (default: `500`). |
| `--anonymize-names` | Consistently hash node/pod/namespace names. Off by default. |
| `--redact-ips` | Also redact IPv4 addresses. Off by default. |
| `--no-redact` | **Disable** the redaction pass. Discouraged; only for debugging the tool. Prints a loud warning. |
| `--dry-run` | Show what would be collected and exit. Does not contact the cluster. |
| `-y, --yes` | Skip the interactive context confirmation (non-interactive use). |
| `-h, --help` | Show help. |

Output archive is named `mistral-furball-<context>-<UTC-timestamp>.zip`
(falls back to `.tar.gz` if `zip` is unavailable).

## Safety model

- **Read-only.** The tool only runs `get`/`describe`/`logs`/`top` and best-effort
  read-only pod proxies and execs. It never creates, patches, or deletes.
- **Local-only.** No network egress beyond the Kubernetes API server you are
  already talking to. Nothing is uploaded.
- **Inspectable.** Everything is plain text/JSON with no obfuscation. List and
  read it before it leaves your machine:

  ```bash
  unzip -l mistral-furball-<context>-<timestamp>.zip      # list contents
  unzip -p mistral-furball-<context>-<timestamp>.zip \
        '*/SUMMARY.txt'                                          # read the summary
  # or, for the tar.gz fallback:
  tar -tzf mistral-furball-<context>-<timestamp>.tar.gz
  ```

  Start with `SUMMARY.txt` and `redaction-summary.txt`, then grep the extracted
  tree for anything you consider sensitive before attaching it to a ticket.

The redactor is a best-effort backstop, not a guarantee — see
[KNOWN-LIMITATIONS.md](KNOWN-LIMITATIONS.md) for exactly where it stops.

## Requirements

- `kubectl` configured with a context for the target cluster.
- A POSIX shell (bash 3.2+).
- Optional: `helm` (Helm values), `jq` (manifest validation), `zip` (else
  `tar.gz`). All degrade gracefully when missing.

## Examples

See [`examples/`](examples/) for a synthetic, pre-redacted sample bundle,
including a generated `SUMMARY.txt`, `README-INSIDE.txt`, and `manifest.json`.

## Testing

```bash
bash test/redaction-test.sh
```

The harness sources the script in library-only mode (`MFB_LIB_ONLY=1`) and
exercises the redaction and anonymization functions without contacting a
cluster.

## License

Apache-2.0. See [LICENSE](LICENSE).
