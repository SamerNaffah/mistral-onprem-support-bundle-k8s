mistral-furball v0.1.0 — what is in this bundle
====================================================

This archive was produced by mistral-furball, a READ-ONLY diagnostic
collector for Mistral LLM deployments on Kubernetes. It is meant to be
attached to a support ticket. Everything in it is plain text or JSON —
open it and inspect it before you send it.

WHAT WAS COLLECTED
  cluster/   kubectl + Kubernetes versions, nodes, storage classes,
             distro / CNI hints
  gpu/       GPU node labels, device-plugin / GPU Operator status,
             nvidia-smi (best-effort read-only exec), DCGM metrics
  workload/  serving Deployment/StatefulSet spec, images, resources,
             serving-engine args, referenced ConfigMaps, Helm values
  state/     namespace events, pod/container status, OOMKill/CrashLoop
  logs/      bounded recent logs (current + previous containers)
  metrics/   kubectl top nodes/pods, serving /metrics (best-effort)
  manifest.json, SUMMARY.txt, redaction-summary.txt

WHAT WAS **NOT** COLLECTED, EVER
  - No prompt / completion / request / response content. This tool
    never touches inference payloads.
  - No Secret values. At most, Secret names and key names are recorded.
  - No environment-variable values, except a short, audited allow-list
    of non-sensitive serving parameters (e.g. TENSOR_PARALLEL_SIZE,
    MAX_MODEL_LEN).

REDACTION
  A single redaction pass ran over every file before archiving: env
  values are wiped, and a regex safety net scrubs tokens, keys, JWTs,
  private-key blocks, padded base64 blobs and email addresses.
  Values redacted: 17 (per-file counts in redaction-summary.txt).
  Node/pod/namespace names were anonymized (--anonymize-names). The
  reverse map is kept OUTSIDE this archive, next to it on the machine
  that ran the tool.

HOW TO INSPECT BEFORE SENDING
  unzip -l <archive>.zip     # or: tar tzf <archive>.tar.gz
  less SUMMARY.txt           # at-a-glance findings
  less redaction-summary.txt # what was scrubbed, per file

No network calls, no upload, and no telemetry were made by this tool.
