#!/usr/bin/env bash
#
# mistral-furball.sh
#
# Collects a read-only diagnostic bundle from a Kubernetes cluster running a
# Mistral LLM deployment, redacts sensitive data, and writes a single local
# archive you can attach to a support ticket.
#
# ---------------------------------------------------------------------------
# READ-ONLY GUARANTEE
#
#   This tool NEVER mutates your cluster. The only kubectl verbs used are:
#
#       get, describe, logs, top, version, config view/current-context
#
#   plus (later milestones, best-effort) a read-only `kubectl exec` that runs
#   `nvidia-smi` inside an already-running GPU pod. No apply/create/patch/
#   delete/edit/scale/label/annotate/cordon — ever. Grep this file for those
#   verbs; you will not find them.
#
# PRIVACY
#
#   - No prompt/completion/inference content is ever collected.
#   - Secret VALUES are never collected (names and key names only, at most).
#   - Env var values are wiped by default; a redaction pass runs over every
#     file before archiving (see build_redaction_sed for the exact rule list).
#
# AIR-GAP
#
#   Everything runs locally against your current kubectl context and writes a
#   local archive. No network calls other than kubectl -> your API server.
#   No upload, no telemetry.
#
# COMPATIBILITY
#
#   Targets bash 3.2+ (macOS default) — no associative arrays, no mapfile.
#   Hard dependency: kubectl. Optional: helm, jq, zip (degrade gracefully).
# ---------------------------------------------------------------------------

set -u

TOOL_NAME="mistral-furball"
TOOL_VERSION="0.1.0"

# ---------------------------------------------------------------------------
# Defaults / globals
# ---------------------------------------------------------------------------

NAMESPACE=""                 # -n/--namespace; auto-detected if empty
OUTPUT_PATH="$PWD"           # -o/--output; dir or explicit .zip/.tar.gz path
SINCE="1h"                   # --since; log window
TAIL_LINES=500               # --tail; max log lines per container
ANONYMIZE_NAMES=false        # --anonymize-names
REDACT_IPS=false             # --redact-ips (IPv4 addresses; off by default)
REDACT=true                  # --no-redact flips this (discouraged)
DRY_RUN=false                # --dry-run
ASSUME_YES=false             # -y/--yes; skip interactive confirmation

HAVE_HELM=false
HAVE_JQ=false
HAVE_ZIP=false

KUBE_CONTEXT=""
KUBECTL_CLIENT_VERSION=""
KUBE_SERVER_VERSION=""

WORK_DIR=""                  # temp working dir (cleaned up on exit)
BUNDLE_DIR=""                # $WORK_DIR/<bundle-name>/
BUNDLE_NAME=""
COLLECTOR_STATUS_FILE=""     # one line per collector: name|status|note
ARCHIVE_PATH=""              # final archive location

TIMESTAMP_UTC="$(date -u +%Y%m%dT%H%M%SZ)"
TIMESTAMP_HUMAN="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"  # readable form of the same run instant

# Collector registry. Milestone 1: all stubs. Order matters for output.
COLLECTORS="cluster gpu workload state logs metrics"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# kubectl wrapper + capture helpers
#
# kc()      — every kubectl call goes through here: read-only verbs only,
#             always bounded by --request-timeout.
# capture() — run a command, write stdout to a file inside the bundle,
#             log stderr to collect-errors.log. A failure increments
#             CAPTURE_FAILS (collector -> "partial") but never aborts.
# ---------------------------------------------------------------------------

ERRLOG=""            # $BUNDLE_DIR/collect-errors.log (set in setup_workdir)
CAPTURE_FAILS=0      # reset by each collector

kc() { kubectl --request-timeout=30s "$@"; }

capture() {
    # capture <bundle-relative-out-file> <command...>
    local rel="$1"; shift
    local out="$BUNDLE_DIR/$rel"
    mkdir -p "$(dirname "$out")"
    printf '### %s\n' "$*" >> "$ERRLOG"
    if ! "$@" > "$out" 2>> "$ERRLOG"; then
        CAPTURE_FAILS=$((CAPTURE_FAILS + 1))
        printf '# command failed: %s\n# stderr: see collect-errors.log\n' "$*" >> "$out"
        return 1
    fi
    return 0
}

# Node list is used by several collectors — fetch once.
NODES_CACHE=""
get_nodes() {
    if [ -z "$NODES_CACHE" ]; then
        NODES_CACHE="$(kc get nodes -o name 2>>"$ERRLOG" | sed 's|^node/||')"
    fi
    printf '%s\n' "$NODES_CACHE"
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
$TOOL_NAME v$TOOL_VERSION

Collect a READ-ONLY, redacted diagnostic bundle from a Kubernetes cluster
running a Mistral LLM deployment. Produces one local archive to attach to a
support ticket. No cluster mutation, no upload, no telemetry.

Usage:
  $(basename "$0") [flags]

Flags:
  -n, --namespace <ns>    Target namespace. If omitted, namespaces with GPU
                          workloads (pods requesting nvidia.com/gpu) are
                          auto-detected and you are prompted to choose.
  -o, --output <path>     Output directory, or explicit file path ending in
                          .zip / .tar.gz. Default: current directory.
      --since <dur>       Log window for kubectl logs (default: $SINCE).
      --tail <n>          Max log lines per container (default: $TAIL_LINES).
      --anonymize-names   Consistently hash node/pod/namespace names.
                          Off by default (names usually help troubleshooting).
      --redact-ips        Also redact IPv4 addresses. Off by default (IPs
                          usually help troubleshooting).
      --no-redact         DISABLE the redaction pass. Discouraged; only for
                          debugging this tool itself. Prints a loud warning.
      --dry-run           Show what would be collected and exit. Does not
                          contact the cluster.
  -y, --yes               Skip the interactive context confirmation
                          (for non-interactive use).
  -h, --help              Show this help.

Output:
  ${TOOL_NAME}-<context>-<UTC-timestamp>.zip   (tar.gz if zip is missing)

The archive is plain text/JSON — open and inspect it before sending.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

require_value() {
    # $1 = flag name, $2 = value (may be unset/empty)
    [ -n "${2:-}" ] || die "flag $1 requires a value (see --help)"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -n|--namespace)
                require_value "$1" "${2:-}"; NAMESPACE="$2"; shift 2 ;;
            -o|--output)
                require_value "$1" "${2:-}"; OUTPUT_PATH="$2"; shift 2 ;;
            --since)
                require_value "$1" "${2:-}"; SINCE="$2"; shift 2 ;;
            --tail)
                require_value "$1" "${2:-}"
                case "$2" in
                    ''|*[!0-9]*) die "--tail expects a positive integer, got: $2" ;;
                esac
                TAIL_LINES="$2"; shift 2 ;;
            --anonymize-names)
                ANONYMIZE_NAMES=true; shift ;;
            --redact-ips)
                REDACT_IPS=true; shift ;;
            --no-redact)
                REDACT=false; shift ;;
            --dry-run)
                DRY_RUN=true; shift ;;
            -y|--yes)
                ASSUME_YES=true; shift ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                die "unknown flag: $1 (see --help)" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

detect_optional_tools() {
    command -v helm >/dev/null 2>&1 && HAVE_HELM=true
    command -v jq   >/dev/null 2>&1 && HAVE_JQ=true
    command -v zip  >/dev/null 2>&1 && HAVE_ZIP=true
}

preflight() {
    command -v kubectl >/dev/null 2>&1 \
        || die "kubectl not found in PATH. kubectl is the only hard dependency."

    detect_optional_tools

    log "Optional tools:"
    log "  helm : $($HAVE_HELM && echo "found" || echo "missing -> helm release info will be skipped")"
    log "  jq   : $($HAVE_JQ   && echo "found" || echo "missing -> manifest.json will not be validated locally")"
    log "  zip  : $($HAVE_ZIP  && echo "found" || echo "missing -> will fall back to tar.gz")"
    log ""

    # Current context — local kubeconfig read, no network.
    if ! KUBE_CONTEXT="$(kubectl config current-context 2>/dev/null)"; then
        if $DRY_RUN; then
            KUBE_CONTEXT="<none set>"
            warn "no current kubectl context set (a real run requires one)."
        else
            die "no current kubectl context set. Run: kubectl config use-context <ctx>"
        fi
    fi

    $DRY_RUN && return 0

    # Reachability + versions. --request-timeout keeps failure fast.
    log "Checking cluster reachability (context: $KUBE_CONTEXT)..."
    local version_out
    if ! version_out="$(kubectl version --request-timeout=10s 2>/dev/null)"; then
        die "cluster not reachable via context '$KUBE_CONTEXT'. Check connectivity/credentials."
    fi
    KUBECTL_CLIENT_VERSION="$(printf '%s\n' "$version_out" | sed -n 's/^Client Version:[[:space:]]*//p' | head -1)"
    KUBE_SERVER_VERSION="$(printf '%s\n' "$version_out"  | sed -n 's/^Server Version:[[:space:]]*//p' | head -1)"
    log "  kubectl client : ${KUBECTL_CLIENT_VERSION:-unknown}"
    log "  server         : ${KUBE_SERVER_VERSION:-unknown}"
    log ""
}

# ---------------------------------------------------------------------------
# Namespace resolution
# ---------------------------------------------------------------------------

detect_namespace() {
    # Find namespaces containing pods that request nvidia.com/gpu (read-only).
    log "No namespace given — scanning for GPU workloads (pods requesting nvidia.com/gpu)..."
    local ns_list
    ns_list="$(kubectl get pods --all-namespaces \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.spec.containers[*].resources.limits.nvidia\.com/gpu}{"\n"}{end}' \
        2>/dev/null | awk -F'\t' '$2 != "" { print $1 }' | sort -u)"

    if [ -z "$ns_list" ]; then
        die "no GPU workloads found in any namespace. Specify one with -n <namespace>."
    fi

    local count
    count="$(printf '%s\n' "$ns_list" | wc -l | tr -d ' ')"

    if [ "$count" -eq 1 ]; then
        NAMESPACE="$ns_list"
        log "  found one GPU namespace: $NAMESPACE"
        return 0
    fi

    log "  found $count namespaces with GPU workloads:"
    local i=1 ns
    for ns in $ns_list; do
        log "    $i) $ns"
        i=$((i + 1))
    done

    if [ ! -t 0 ]; then
        die "multiple GPU namespaces found; non-interactive session. Pick one with -n <namespace>."
    fi

    printf 'Select a namespace [1-%s]: ' "$count"
    local choice
    read -r choice
    case "$choice" in
        ''|*[!0-9]*) die "invalid selection: $choice" ;;
    esac
    [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ] || die "selection out of range: $choice"
    NAMESPACE="$(printf '%s\n' "$ns_list" | sed -n "${choice}p")"
    log "  selected: $NAMESPACE"
}

# ---------------------------------------------------------------------------
# Confirmation — always echo the context prominently before collecting
# ---------------------------------------------------------------------------

confirm_context() {
    log "==========================================================="
    log " Collecting from context   : $KUBE_CONTEXT"
    log " Target namespace          : $NAMESPACE"
    log " Log window / tail         : $SINCE / $TAIL_LINES lines"
    log " Redaction                 : $($REDACT && echo "ON" || echo "OFF (!)" )"
    log " This tool is READ-ONLY. Nothing in your cluster is modified."
    log "==========================================================="

    if ! $REDACT; then
        warn "--no-redact is set: SENSITIVE VALUES WILL NOT BE SCRUBBED."
        warn "Only use this to debug the tool itself. Do NOT send this bundle."
    fi

    $ASSUME_YES && return 0

    if [ ! -t 0 ]; then
        die "non-interactive session: re-run with --yes to confirm the context above."
    fi

    printf 'Proceed? [y/N]: '
    local answer
    read -r answer
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) die "aborted by user." ;;
    esac
}

# ---------------------------------------------------------------------------
# Working directory (temp) — always cleaned up on exit
# ---------------------------------------------------------------------------

cleanup() {
    [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
}

setup_workdir() {
    # Sanitize context for use in a filename.
    local safe_context
    safe_context="$(printf '%s' "$KUBE_CONTEXT" | tr -c 'A-Za-z0-9._-' '-' )"
    BUNDLE_NAME="${TOOL_NAME}-${safe_context}-${TIMESTAMP_UTC}"

    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${TOOL_NAME}.XXXXXX")" \
        || die "failed to create temp working directory"
    trap cleanup EXIT INT TERM

    BUNDLE_DIR="$WORK_DIR/$BUNDLE_NAME"
    COLLECTOR_STATUS_FILE="$WORK_DIR/collector-status.txt"
    : > "$COLLECTOR_STATUS_FILE"
    mkdir -p "$BUNDLE_DIR"
    ERRLOG="$BUNDLE_DIR/collect-errors.log"
    : > "$ERRLOG"

    local d
    for d in $COLLECTORS; do
        mkdir -p "$BUNDLE_DIR/$d"
    done
}

# ---------------------------------------------------------------------------
# Collector registry
#
# Each collector writes into $BUNDLE_DIR/<name>/ and records its outcome via
# record_collector. A collector failure NEVER aborts the run — a partial
# bundle is still useful.
# ---------------------------------------------------------------------------

record_collector() {
    # $1 = name, $2 = status (ok|failed|skipped|not_implemented), $3 = note
    printf '%s|%s|%s\n' "$1" "$2" "${3:-}" >> "$COLLECTOR_STATUS_FILE"
}

# ===========================================================================
# cluster/ — versions, nodes, storage classes, distro + CNI hints
# All commands: kubectl get / describe / version. Read-only.
# ===========================================================================

collect_cluster() {
    CAPTURE_FAILS=0

    capture cluster/version.txt          kc version
    capture cluster/nodes-wide.txt       kc get nodes -o wide
    capture cluster/nodes-labels.txt     kc get nodes --show-labels
    capture cluster/storageclasses.txt   kc get storageclass -o wide
    # Full DaemonSet list: shows CNI, device plugin, DCGM, log agents — pure infra.
    capture cluster/daemonsets-wide.txt  kc get daemonsets --all-namespaces -o wide

    local node
    for node in $(get_nodes); do
        [ -n "$node" ] || continue
        capture "cluster/nodes/describe-${node}.txt" kc describe node "$node"
    done

    write_distro_hints
    write_cni_hints

    if [ "$CAPTURE_FAILS" -eq 0 ]; then
        record_collector cluster ok ""
    else
        record_collector cluster partial "$CAPTURE_FAILS command(s) failed; see collect-errors.log"
    fi
}

write_distro_hints() {
    # Heuristics only — grep version strings + node labels for known markers.
    local out="$BUNDLE_DIR/cluster/distro-hint.txt"
    local haystack
    haystack="$(cat "$BUNDLE_DIR/cluster/version.txt" "$BUNDLE_DIR/cluster/nodes-labels.txt" 2>/dev/null)"
    {
        echo "# Heuristic Kubernetes distro/flavour hints"
        echo "# (matched against kubectl version output + node labels)"
        local found=false
        case "$haystack" in *k3s*)                          echo "k3s";        found=true ;; esac
        case "$haystack" in *rke2*)                         echo "RKE2";       found=true ;; esac
        case "$haystack" in *-eks-*|*amazonaws.com*)        echo "EKS";        found=true ;; esac
        case "$haystack" in *-gke.*|*cloud.google.com*)     echo "GKE";        found=true ;; esac
        case "$haystack" in *kubernetes.azure.com*)         echo "AKS";        found=true ;; esac
        case "$haystack" in *node.openshift.io*)            echo "OpenShift";  found=true ;; esac
        case "$haystack" in *microk8s*)                     echo "MicroK8s";   found=true ;; esac
        case "$haystack" in *talos.dev*)                    echo "Talos";      found=true ;; esac
        $found || echo "no known distro markers found (likely vanilla Kubernetes)"
    } > "$out"
}

write_cni_hints() {
    local out="$BUNDLE_DIR/cluster/cni-hint.txt"
    local ds_file="$BUNDLE_DIR/cluster/daemonsets-wide.txt"
    {
        echo "# CNI hints: DaemonSets matching known CNI names"
        if [ -f "$ds_file" ]; then
            grep -iE 'calico|cilium|flannel|weave|antrea|kube-ovn|multus|canal|kube-router|aws-node|azure-cni' \
                "$ds_file" 2>/dev/null || echo "no known CNI DaemonSet names matched"
        else
            echo "daemonset list unavailable"
        fi
    } > "$out"
}

# ===========================================================================
# gpu/ — node GPU labels/capacity, device plugin, GPU Operator, nvidia-smi,
# DCGM metrics. nvidia-smi uses a READ-ONLY exec (query tool, changes
# nothing); DCGM uses a read-only GET through the API server's pod proxy.
# Everything beyond node labels is best-effort — never fails the run.
# ===========================================================================

GPU_NOTES=""

gpu_note() { GPU_NOTES="${GPU_NOTES:+$GPU_NOTES; }$1"; }

collect_gpu() {
    CAPTURE_FAILS=0
    GPU_NOTES=""

    # Working file only — the full cluster pod list stays OUT of the bundle
    # (it would leak names of unrelated workloads). Only GPU-stack-filtered
    # lines are included below.
    local all_pods="$WORK_DIR/all-pods-wide.txt"
    kc get pods --all-namespaces -o wide > "$all_pods" 2>>"$ERRLOG" || true

    write_gpu_node_info

    grep -iE 'nvidia|dcgm|gpu-operator|gpu-feature-discovery|node-feature-discovery' \
        "$all_pods" > "$BUNDLE_DIR/gpu/gpu-stack-pods.txt" 2>/dev/null \
        || echo "no NVIDIA / GPU Operator / NFD pods found" > "$BUNDLE_DIR/gpu/gpu-stack-pods.txt"

    collect_device_plugin "$all_pods"
    collect_gpu_operator
    collect_nvidia_smi "$all_pods"
    collect_dcgm_metrics "$all_pods"

    if [ "$CAPTURE_FAILS" -eq 0 ]; then
        record_collector gpu ok "$GPU_NOTES"
    else
        record_collector gpu partial "$CAPTURE_FAILS command(s) failed; $GPU_NOTES"
    fi
}

write_gpu_node_info() {
    local out="$BUNDLE_DIR/gpu/gpu-nodes.txt"
    local node cap alloc labels gpu_nodes=0
    : > "$out"
    for node in $(get_nodes); do
        [ -n "$node" ] || continue
        cap="$(kc get node "$node" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>>"$ERRLOG")"
        alloc="$(kc get node "$node" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>>"$ERRLOG")"
        [ -n "$cap" ] && gpu_nodes=$((gpu_nodes + 1))
        # Labels from GPU Operator / Node Feature Discovery carry the driver,
        # CUDA and MIG story: nvidia.com/gpu.product, nvidia.com/cuda.driver.*
        labels="$(kc get node "$node" -o jsonpath='{.metadata.labels}' 2>>"$ERRLOG" \
            | tr ',{}' '\n\n\n' | grep -iE 'nvidia|gpu|cuda|mig' | sed -e 's/"//g' -e 's/^[[:space:]]*/  /')"
        {
            printf '== node: %s\n' "$node"
            printf 'nvidia.com/gpu capacity   : %s\n' "${cap:-<none>}"
            printf 'nvidia.com/gpu allocatable: %s\n' "${alloc:-<none>}"
            printf 'GPU-related labels:\n'
            if [ -n "$labels" ]; then printf '%s\n' "$labels"; else printf '  <none>\n'; fi
            printf '\n'
        } >> "$out"
    done
    if [ ! -s "$out" ]; then
        echo "node list unavailable" > "$out"
        CAPTURE_FAILS=$((CAPTURE_FAILS + 1))
    fi
    gpu_note "$gpu_nodes node(s) with nvidia.com/gpu capacity"
}

collect_device_plugin() {
    local all_pods="$1"
    local ds_file="$BUNDLE_DIR/cluster/daemonsets-wide.txt"
    local ns name pod

    # DaemonSet spec/status (matched by name; covers standalone + operator installs)
    if [ -f "$ds_file" ]; then
        while read -r ns name; do
            [ -n "$name" ] || continue
            capture "gpu/device-plugin/describe-${ns}-${name}.txt" kc describe daemonset -n "$ns" "$name"
        done <<EOF
$(awk 'tolower($2) ~ /device-plugin/ && tolower($0) ~ /nvidia/ { print $1, $2 }' "$ds_file")
EOF
    fi

    # Bounded logs from up to 3 device plugin pods (one per node otherwise —
    # a large cluster would bloat the bundle for no extra signal).
    while read -r ns pod; do
        [ -n "$pod" ] || continue
        capture "gpu/device-plugin/logs-${ns}-${pod}.txt" kc logs -n "$ns" "$pod" --tail="$TAIL_LINES"
    done <<EOF
$(awk '$2 ~ /nvidia-device-plugin/ && $4 == "Running" { print $1, $2 }' "$all_pods" 2>/dev/null | head -3)
EOF
}

collect_gpu_operator() {
    local out="$BUNDLE_DIR/gpu/clusterpolicy.yaml"
    # ClusterPolicy CRD exists only when the NVIDIA GPU Operator is installed.
    if kc get crd clusterpolicies.nvidia.com >/dev/null 2>&1; then
        capture gpu/clusterpolicy.yaml kc get clusterpolicies.nvidia.com -o yaml
        gpu_note "GPU Operator ClusterPolicy present"
    else
        echo "NVIDIA GPU Operator not detected (no clusterpolicies.nvidia.com CRD)" > "$out"
        gpu_note "no GPU Operator"
    fi
}

collect_nvidia_smi() {
    local all_pods="$1"
    local out="$BUNDLE_DIR/gpu/nvidia-smi.txt"
    local cands="$WORK_DIR/nvidia-smi-candidates.txt"
    local tmp="$WORK_DIR/nvidia-smi.tmp"
    local ns pod tried=0 max_tries=4

    # Candidate pods, best first: GPU pods in the target namespace, then
    # driver DaemonSet pods, then device plugin pods.
    {
        kc get pods -n "$NAMESPACE" \
            -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.containers[*].resources.limits.nvidia\.com/gpu}{"\n"}{end}' \
            2>>"$ERRLOG" | awk '$3 != "" { print $1, $2 }'
        awk '$4 == "Running" && $2 ~ /nvidia-driver-daemonset/ { print $1, $2 }' "$all_pods" 2>/dev/null
        awk '$4 == "Running" && $2 ~ /nvidia-device-plugin/    { print $1, $2 }' "$all_pods" 2>/dev/null
    } > "$cands"

    while read -r ns pod; do
        [ -n "$pod" ] || continue
        tried=$((tried + 1))
        [ "$tried" -gt "$max_tries" ] && break
        # READ-ONLY exec: nvidia-smi is a query tool; this mutates nothing.
        printf '### kc exec -n %s %s -- nvidia-smi (best-effort)\n' "$ns" "$pod" >> "$ERRLOG"
        if kc exec -n "$ns" "$pod" -- nvidia-smi > "$tmp" 2>>"$ERRLOG"; then
            {
                printf '# nvidia-smi via read-only exec in pod %s/%s\n' "$ns" "$pod"
                cat "$tmp"
            } > "$out"
            gpu_note "nvidia-smi ok via $ns/$pod"
            return 0
        fi
    done < "$cands"

    echo "nvidia-smi unavailable: no candidate pod succeeded ($tried tried). Not fatal — GPU node labels above usually carry driver/CUDA versions." > "$out"
    gpu_note "nvidia-smi unavailable ($tried candidate(s) tried)"
}

collect_dcgm_metrics() {
    local all_pods="$1"
    local out="$BUNDLE_DIR/gpu/dcgm-metrics.txt"
    local tmp="$WORK_DIR/dcgm.tmp"
    local line ns pod port max_bytes=262144

    line="$(awk '$4 == "Running" && $2 ~ /dcgm/ { print $1, $2; exit }' "$all_pods" 2>/dev/null)"
    if [ -z "$line" ]; then
        echo "no running dcgm-exporter pod found" > "$out"
        gpu_note "no DCGM exporter"
        return 0
    fi
    ns="${line%% *}"
    pod="${line##* }"
    port="$(kc get pod -n "$ns" "$pod" -o jsonpath='{.spec.containers[0].ports[0].containerPort}' 2>>"$ERRLOG")"
    port="${port:-9400}"

    # Read-only GET through the API server's pod proxy — no exec, no mutation.
    if kc get --raw "/api/v1/namespaces/${ns}/pods/${pod}:${port}/proxy/metrics" > "$tmp" 2>>"$ERRLOG"; then
        {
            printf '# DCGM metrics from %s/%s:%s (read-only GET via pod proxy)\n' "$ns" "$pod" "$port"
            head -c "$max_bytes" "$tmp"
            [ "$(wc -c < "$tmp")" -gt "$max_bytes" ] && printf '\n# [truncated at %s bytes]\n' "$max_bytes"
        } > "$out"
        gpu_note "DCGM metrics ok via $ns/$pod"
    else
        echo "dcgm-exporter found ($ns/$pod) but /metrics not reachable via pod proxy on port $port" > "$out"
        gpu_note "DCGM /metrics unreachable"
    fi
}

# ===========================================================================
# workload/ — the Mistral serving deployment: spec, images (-> model+version),
# serving-engine config (TP size, max-model-len, quant, ...), Helm release
# values/manifest, and the ConfigMaps/Secrets it references.
#
# PRIVACY (enforced HERE, at collection time — not left to the milestone-6
# regex net):
#   - Env var VALUES are WIPED by default. A value survives only if its name is
#     in WORKLOAD_ENV_ALLOWLIST below (audited, non-sensitive serving knobs).
#   - Secret VALUES are never read. Only secret names, types, and key names.
#   - valueFrom refs never expose the resolved value.
# Helm values/manifest and referenced ConfigMaps are config (may carry tokens);
# they are collected here and scrubbed by the regex safety net in milestone 6.
# All commands are read-only: kubectl get / helm get/list.
# ===========================================================================

# Env var NAMES whose VALUES are safe to keep (non-sensitive serving / tuning
# parameters). Every other env value is wiped to "<REDACTED>". Keep this list
# short, explicit and easy for a security reviewer to read top to bottom.
# Covers both the Mistral inference-engine chart's env (SERVED_MODEL, TP_SIZE,
# RECIPES_VERSION, VLLM_*) and generic vLLM/TGI-style tuning knobs.
WORKLOAD_ENV_ALLOWLIST="
SERVED_MODEL SERVED_MODEL_NAME MODEL MODEL_NAME MODEL_CONFIGS_FILENAME
RECIPES_VERSION RECIPE_EXTRA_ARGS
LLM_ENGINE ENGINE
TP_SIZE TENSOR_PARALLEL_SIZE PP_SIZE PIPELINE_PARALLEL_SIZE
MAX_MODEL_LEN MAX_NUM_SEQS MAX_NUM_BATCHED_TOKENS
GPU_MEMORY_UTILIZATION KV_CACHE_DTYPE BLOCK_SIZE SWAP_SPACE
QUANTIZATION DTYPE ENFORCE_EAGER TRUST_REMOTE_CODE
VLLM_EXTRA_ARGS VLLM_LOGGING_LEVEL VLLM_ALLOW_LONG_MAX_MODEL_LEN
VLLM_WORKER_MULTIPROC_METHOD VLLM_USE_V1
NATS_URL TRITON_CACHE_DIR RCLONE_CONFIG_PATH
PORT HOST
"

WL_NOTES=""

collect_workload() {
    CAPTURE_FAILS=0
    WL_NOTES=""
    local wl_list count=0 kind name label

    # Release-level context first (independent of workload auto-detection).
    collect_helm

    wl_list="$(find_gpu_workloads)"

    if [ -z "$wl_list" ]; then
        # No GPU Deployment/StatefulSet found. Record what workloads DO exist
        # (names only — safe) so support still has a starting point.
        {
            echo "# No Deployment/StatefulSet requesting nvidia.com/gpu was found"
            echo "# in namespace '$NAMESPACE'. Workloads present (names only):"
            echo
            kc get deployment,statefulset,daemonset -n "$NAMESPACE" -o name 2>>"$ERRLOG"
        } > "$BUNDLE_DIR/workload/no-gpu-workload.txt"
        WL_NOTES="no GPU workload auto-detected in $NAMESPACE"
        record_collector workload partial "$WL_NOTES"
        return 0
    fi

    # bash 3.2: iterate via while-read over a heredoc (no mapfile).
    while read -r kind name; do
        [ -n "$name" ] || continue
        count=$((count + 1))
        label="$(printf '%s-%s' "$kind" "$name" | tr -c 'A-Za-z0-9._-' '-')"
        write_workload_spec   "$kind" "$name" "$label"
        write_workload_env    "$kind" "$name" "$label"
        collect_workload_refs "$kind" "$name" "$label"
        write_serving_config  "$label"
    done <<EOF
$wl_list
EOF

    WL_NOTES="$count GPU workload(s): $(printf '%s\n' "$wl_list" | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')"
    if [ "$CAPTURE_FAILS" -eq 0 ]; then
        record_collector workload ok "$WL_NOTES"
    else
        record_collector workload partial "$CAPTURE_FAILS capture(s) failed; $WL_NOTES"
    fi
}

find_gpu_workloads() {
    # Emit "<kind> <name>" for Deployments/StatefulSets in $NAMESPACE whose pod
    # template requests OR limits nvidia.com/gpu. Read-only.
    local kind
    for kind in deployment statefulset; do
        kc get "$kind" -n "$NAMESPACE" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[*].resources.limits.nvidia\.com/gpu}{"\t"}{.spec.template.spec.containers[*].resources.requests.nvidia\.com/gpu}{"\n"}{end}' \
            2>>"$ERRLOG" \
        | awk -F'\t' -v k="$kind" '($2 != "" || $3 != "") { print k, $1 }'
    done
}

write_workload_spec() {
    local kind="$1" name="$2" label="$3"
    local d="$BUNDLE_DIR/workload/$label"
    mkdir -p "$d"
    {
        printf '# Workload spec (redacted) — %s/%s in namespace %s\n' "$kind" "$name" "$NAMESPACE"
        printf '# Env values are wiped at collection time; see env-redacted.txt.\n\n'

        printf 'kind             : %s\n' "$kind"
        printf 'name             : %s\n' "$name"
        printf 'namespace        : %s\n' "$NAMESPACE"
        printf 'helm release     : %s\n' "$(kc get "$kind" "$name" -n "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/instance}' 2>>"$ERRLOG")"
        printf 'app name (label) : %s\n' "$(kc get "$kind" "$name" -n "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}' 2>>"$ERRLOG")"
        printf 'helm chart       : %s\n' "$(kc get "$kind" "$name" -n "$NAMESPACE" -o jsonpath='{.metadata.labels.helm\.sh/chart}' 2>>"$ERRLOG")"
        printf 'replicas (spec)  : %s\n' "$(kc get "$kind" "$name" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>>"$ERRLOG")"
        printf 'replicas (ready) : %s\n' "$(kc get "$kind" "$name" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>>"$ERRLOG")"

        printf '\n[images]  (tag/digest -> engine + model version)\n'
        kc get "$kind" "$name" -n "$NAMESPACE" -o jsonpath='{range .spec.template.spec.initContainers[*]}  init/{.name}: {.image}{"\n"}{end}{range .spec.template.spec.containers[*]}  {.name}: {.image}{"\n"}{end}' 2>>"$ERRLOG"

        printf '\n[resources]\n'
        kc get "$kind" "$name" -n "$NAMESPACE" -o jsonpath='{range .spec.template.spec.containers[*]}  {.name}: requests={.resources.requests}  limits={.resources.limits}{"\n"}{end}' 2>>"$ERRLOG"

        printf '\n[ports]\n'
        kc get "$kind" "$name" -n "$NAMESPACE" -o jsonpath='{range .spec.template.spec.containers[*]}  {.name}: {range .ports[*]}{.name}:{.containerPort}/{.protocol} {end}{"\n"}{end}' 2>>"$ERRLOG"

        printf '\n[command]\n'
        kc get "$kind" "$name" -n "$NAMESPACE" -o jsonpath='{range .spec.template.spec.containers[*]}  == {.name}{"\n"}{range .command[*]}    {@}{"\n"}{end}{end}' 2>>"$ERRLOG"

        printf '\n[container args]  (serving-engine CLI flags live here)\n'
        kc get "$kind" "$name" -n "$NAMESPACE" -o jsonpath='{range .spec.template.spec.containers[*]}  == {.name}{"\n"}{range .args[*]}    {@}{"\n"}{end}{end}' 2>>"$ERRLOG"
    } > "$d/spec-summary.txt"
}

write_workload_env() {
    local kind="$1" name="$2" label="$3"
    local d="$BUNDLE_DIR/workload/$label"
    mkdir -p "$d"
    local allow_flat
    allow_flat=" $(printf '%s' "$WORKLOAD_ENV_ALLOWLIST" | tr '\n' ' ') "
    {
        echo "# Environment variables (values WIPED by default)."
        echo "# A value is shown ONLY if its name is in the audited allow-list of"
        echo "# non-sensitive serving/tuning parameters (WORKLOAD_ENV_ALLOWLIST in"
        echo "# the script). valueFrom refs never expose the resolved value."
        echo
        kc get "$kind" "$name" -n "$NAMESPACE" -o jsonpath='{range .spec.template.spec.initContainers[*]}INIT|@|{.name}{"\n"}{range .env[*]}ENV|@|{.name}|@|{.value}|@|{.valueFrom}{"\n"}{end}{end}{range .spec.template.spec.containers[*]}MAIN|@|{.name}{"\n"}{range .env[*]}ENV|@|{.name}|@|{.value}|@|{.valueFrom}{"\n"}{end}{end}' 2>>"$ERRLOG" \
        | awk -F'[|]@[|]' -v allow="$allow_flat" '
            $1=="INIT" { printf "\n[init container: %s]\n", $2; next }
            $1=="MAIN" { printf "\n[container: %s]\n", $2; next }
            $1=="ENV"  {
                n=$2; v=$3; vf=$4;
                if (vf != "") { printf "  %s = <valueFrom (configMap/secret/field ref) — value NOT collected>\n", n; next }
                if (index(allow, " " n " ") > 0) { printf "  %s = %s\n", n, v; next }
                printf "  %s = <REDACTED>\n", n
            }
        '
    } > "$d/env-redacted.txt"
}

collect_workload_refs() {
    # ConfigMaps referenced by the workload -> dumped (config; regex-scrubbed in
    # milestone 6). Secrets -> names, types, KEY NAMES only. Never secret values.
    local kind="$1" name="$2" label="$3"
    local d="$BUNDLE_DIR/workload/$label"
    local refs="$WORK_DIR/refs-$label.txt"
    mkdir -p "$d"

    {
        kc get "$kind" "$name" -n "$NAMESPACE" -o jsonpath='{range .spec.template.spec.volumes[*]}CM|@|{.configMap.name}{"\n"}SEC|@|{.secret.secretName}{"\n"}{end}' 2>>"$ERRLOG"
        kc get "$kind" "$name" -n "$NAMESPACE" -o jsonpath='{range .spec.template.spec.containers[*]}{range .envFrom[*]}CM|@|{.configMapRef.name}{"\n"}SEC|@|{.secretRef.name}{"\n"}{end}{range .env[*]}CM|@|{.valueFrom.configMapKeyRef.name}{"\n"}SEC|@|{.valueFrom.secretKeyRef.name}{"\n"}{end}{end}' 2>>"$ERRLOG"
        kc get "$kind" "$name" -n "$NAMESPACE" -o jsonpath='{range .spec.template.spec.initContainers[*]}{range .envFrom[*]}CM|@|{.configMapRef.name}{"\n"}SEC|@|{.secretRef.name}{"\n"}{end}{range .env[*]}CM|@|{.valueFrom.configMapKeyRef.name}{"\n"}SEC|@|{.valueFrom.secretKeyRef.name}{"\n"}{end}{end}' 2>>"$ERRLOG"
    } > "$refs"

    local cms secs cm s type keys
    cms="$(awk -F'[|]@[|]' '$1=="CM"  && $2!="" {print $2}' "$refs" | sort -u)"
    secs="$(awk -F'[|]@[|]' '$1=="SEC" && $2!="" {print $2}' "$refs" | sort -u)"

    for cm in $cms; do
        [ -n "$cm" ] || continue
        capture "workload/$label/configmaps/$cm.yaml" kc get configmap "$cm" -n "$NAMESPACE" -o yaml
    done

    {
        echo "# Secrets referenced by this workload."
        echo "# Only secret NAMES, TYPES and KEY NAMES are recorded — never values."
        echo
        [ -z "$secs" ] && echo "(none referenced)"
    } > "$d/secrets-referenced.txt"
    for s in $secs; do
        [ -n "$s" ] || continue
        type="$(kc get secret "$s" -n "$NAMESPACE" -o jsonpath='{.type}' 2>>"$ERRLOG")"
        # go-template over .data prints only the KEYS, never the values.
        keys="$(kc get secret "$s" -n "$NAMESPACE" -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}' 2>>"$ERRLOG")"
        {
            printf '== %s (type=%s)\n' "$s" "${type:-unknown}"
            if [ -n "$keys" ]; then
                printf '%s\n' "$keys" | sed 's/^/   key: /'
            else
                echo '   (no data keys, or not readable with current RBAC)'
            fi
            echo
        } >> "$d/secrets-referenced.txt"
    done
}

sc_find() {
    # sc_find "<title>" "<egrep-regex>" <file...>
    local title="$1"; shift
    local re="$1"; shift
    local hits
    hits="$(grep -iEh "$re" "$@" 2>/dev/null | grep -vE '^[[:space:]]*#' | sed 's/^[[:space:]]*//' | sort -u)"
    if [ -n "$hits" ]; then
        printf '%s:\n' "$title"
        printf '%s\n' "$hits" | sed 's/^/    /'
    else
        printf '%s: <not explicitly set; engine defaults apply>\n' "$title"
    fi
    printf '\n'
}

write_serving_config() {
    local label="$1"
    local d="$BUNDLE_DIR/workload/$label"
    local files="$d/spec-summary.txt $d/env-redacted.txt"
    {
        echo "# Serving-engine configuration — convenience extract."
        echo "# Pulled from container args + allow-listed env. spec-summary.txt and"
        echo "# env-redacted.txt remain the source of truth."
        echo
        sc_find "tensor / pipeline parallel" 'tensor[-_]parallel|pipeline[-_]parallel|(^|[^A-Z_])TP_SIZE|(^|[^A-Z_])PP_SIZE' $files
        sc_find "max model length"           'max[-_]model[-_]len' $files
        sc_find "gpu memory utilization"     'gpu[-_]memory[-_]utilization' $files
        sc_find "quantization / dtype"       'quantization|kv[-_]cache[-_]dtype|(^|[^A-Za-z])dtype' $files
        sc_find "batching / kv-cache"        'max[-_]num[-_]seqs|max[-_]num[-_]batched[-_]tokens|block[-_]size|swap[-_]space|chunked[-_]prefill' $files
        sc_find "served model / recipe"      'served[-_]model|recipes?[-_]version|(^|[[:space:]]|=)--model([[:space:]]|=)' $files
        sc_find "engine"                     'LLM_ENGINE|VLLM_EXTRA_ARGS|VLLM_LOGGING_LEVEL' $files
    } > "$d/serving-config.txt"
}

collect_helm() {
    local base="workload/helm"
    mkdir -p "$BUNDLE_DIR/$base"

    if ! $HAVE_HELM; then
        printf 'helm not installed — release values/manifest skipped.\n' \
            > "$BUNDLE_DIR/$base/SKIPPED.txt"
        return 0
    fi

    capture "$base/releases.txt" helm list -n "$NAMESPACE"

    local releases r
    releases="$(helm list -n "$NAMESPACE" -q 2>>"$ERRLOG")"
    if [ -z "$releases" ]; then
        printf 'no helm releases found in namespace %s\n' "$NAMESPACE" \
            > "$BUNDLE_DIR/$base/no-releases.txt"
        return 0
    fi

    for r in $releases; do
        [ -n "$r" ] || continue
        # User-supplied values + rendered manifest. These commonly carry
        # registry creds / HF tokens and are scrubbed by the regex safety net
        # (milestone 6) before the bundle is archived.
        capture "$base/$r.values.yaml"   helm get values   "$r" -n "$NAMESPACE"
        capture "$base/$r.manifest.yaml" helm get manifest "$r" -n "$NAMESPACE"
    done
}

# ===========================================================================
# state/ — namespace events, pod/container status, and the red-flag detector
# (OOMKilled / CrashLoopBackOff / high restart counts / image-pull errors).
# All commands: kubectl get / describe. Read-only.
# ===========================================================================

STATE_RESTART_THRESHOLD=5   # restartCount at/above this is flagged
STATE_NOTE=""

collect_state() {
    CAPTURE_FAILS=0
    STATE_NOTE=""
    mkdir -p "$BUNDLE_DIR/state"

    # Namespace events, oldest-first (bounded by the cluster's event retention).
    capture state/events.txt         kc get events -n "$NAMESPACE" -o wide --sort-by=.lastTimestamp
    capture state/pods-wide.txt       kc get pods -n "$NAMESPACE" -o wide
    capture state/workloads-wide.txt  kc get deployment,statefulset,daemonset,replicaset -n "$NAMESPACE" -o wide

    # describe every pod in the namespace — probe failures, scheduling events,
    # image-pull errors and lastState all surface here.
    local p name
    for p in $(kc get pods -n "$NAMESPACE" -o name 2>>"$ERRLOG"); do
        name="${p##*/}"
        [ -n "$name" ] || continue
        capture "state/describe/${name}.txt" kc describe pod -n "$NAMESPACE" "$name"
    done

    write_state_status
    write_state_anomalies

    if [ "$CAPTURE_FAILS" -eq 0 ]; then
        record_collector state ok "$STATE_NOTE"
    else
        record_collector state partial "$CAPTURE_FAILS capture(s) failed; $STATE_NOTE"
    fi
}

# Per-pod/per-container status as one flat, delimited stream. Shared by the
# human-readable table and the anomaly detector so they never disagree.
state_status_stream() {
    kc get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}POD|@|{.metadata.name}|@|{.status.phase}{"\n"}{range .status.initContainerStatuses[*]}C|@|init|@|{.name}|@|{.restartCount}|@|{.ready}|@|{.lastState.terminated.reason}|@|{.lastState.terminated.exitCode}|@|{.state.waiting.reason}{"\n"}{end}{range .status.containerStatuses[*]}C|@|main|@|{.name}|@|{.restartCount}|@|{.ready}|@|{.lastState.terminated.reason}|@|{.lastState.terminated.exitCode}|@|{.state.waiting.reason}{"\n"}{end}{end}' 2>>"$ERRLOG"
}

write_state_status() {
    local out="$BUNDLE_DIR/state/pod-container-status.txt"
    {
        echo "# Pod / container status (restart counts, readiness, last termination)."
        echo
        state_status_stream | awk -F'[|]@[|]' '
            $1=="POD" { printf "\n%s   (phase=%s)\n", $2, $3; next }
            $1=="C"   {
                printf "  [%-4s] %-32s restarts=%-4s ready=%-5s lastTerm=%-14s exit=%-4s waiting=%s\n", \
                    $2, $3, $4, $5, ($6==""?"-":$6), ($7==""?"-":$7), ($8==""?"-":$8)
            }
        '
    } > "$out"
}

write_state_anomalies() {
    local out="$BUNDLE_DIR/state/anomalies.txt"
    local body="$WORK_DIR/anomalies-body.txt"
    local n

    state_status_stream | awk -F'[|]@[|]' -v thr="$STATE_RESTART_THRESHOLD" '
        $1=="POD" { pod=$2; next }
        $1=="C"   {
            kind=$2; c=$3; rc=$4+0; ready=$5; term=$6; ec=$7; wait=$8;
            if (term=="OOMKilled")                                   printf "OOMKilled        pod=%s container=%s (%s) exitCode=%s\n", pod, c, kind, ec;
            if (wait=="CrashLoopBackOff")                            printf "CrashLoopBackOff pod=%s container=%s (%s) restarts=%s\n", pod, c, kind, rc;
            if (wait=="ImagePullBackOff" || wait=="ErrImagePull")    printf "ImagePullError   pod=%s container=%s (%s) reason=%s\n", pod, c, kind, wait;
            if (rc>=thr)                                             printf "HighRestarts     pod=%s container=%s (%s) restartCount=%s\n", pod, c, kind, rc;
        }
    ' > "$body"

    n="$(wc -l < "$body" 2>/dev/null | tr -d ' ')"; n="${n:-0}"
    {
        echo "# Detected red flags (OOMKilled / CrashLoopBackOff / image-pull / restarts>=$STATE_RESTART_THRESHOLD)."
        echo "# Empty here is good. Full detail is in pod-container-status.txt and describe/."
        echo
        if [ "$n" -eq 0 ]; then
            echo "No OOMKills, CrashLoops, image-pull errors, or high restart counts detected."
        else
            cat "$body"
        fi
    } > "$out"
    STATE_NOTE="$n red flag(s)"
}

# ===========================================================================
# logs/ — bounded container logs (current + previous) for every pod in the
# target namespace. Bounded by --since and --tail; NEVER unbounded. Logs pass
# through the redaction net (milestone 6) before archiving. kubectl logs is
# read-only.
# ===========================================================================

collect_logs() {
    CAPTURE_FAILS=0
    mkdir -p "$BUNDLE_DIR/logs"
    {
        echo "# Bounded container logs."
        echo "# window: --since=$SINCE    per-container cap: --tail=$TAIL_LINES lines"
        echo "# <pod>/<container>.log          = current instance"
        echo "# <pod>/<container>.previous.log = last terminated instance (only if it restarted)"
        echo "# Logs are scrubbed by the redaction pass before archiving."
    } > "$BUNDLE_DIR/logs/README.txt"

    local pods p name pcount=0
    pods="$(kc get pods -n "$NAMESPACE" -o name 2>>"$ERRLOG")"
    if [ -z "$pods" ]; then
        echo "no pods found in namespace $NAMESPACE" > "$BUNDLE_DIR/logs/no-pods.txt"
        record_collector logs partial "no pods in $NAMESPACE"
        return 0
    fi

    for p in $pods; do
        name="${p##*/}"
        [ -n "$name" ] || continue
        collect_pod_logs "$name" && pcount=$((pcount + 1))
    done

    if [ "$CAPTURE_FAILS" -eq 0 ]; then
        record_collector logs ok "$pcount pod(s); since=$SINCE tail=$TAIL_LINES"
    else
        record_collector logs partial "$CAPTURE_FAILS log capture(s) failed; $pcount pod(s)"
    fi
}

collect_pod_logs() {
    local pod="$1"
    local d="$BUNDLE_DIR/logs/$pod"
    local containers kind cname tmp
    containers="$(kc get pod -n "$NAMESPACE" "$pod" \
        -o jsonpath='{range .spec.initContainers[*]}init {.name}{"\n"}{end}{range .spec.containers[*]}main {.name}{"\n"}{end}' \
        2>>"$ERRLOG")"
    [ -n "$containers" ] || return 1
    mkdir -p "$d"

    # while-read over a heredoc (not a pipe) so CAPTURE_FAILS survives the loop.
    while read -r kind cname; do
        [ -n "$cname" ] || continue
        capture "logs/$pod/${cname}.log" \
            kc logs -n "$NAMESPACE" "$pod" -c "$cname" --since="$SINCE" --tail="$TAIL_LINES"
        # Previous instance is absent unless the container restarted — that is
        # expected, so it is best-effort and never counts as a capture failure.
        tmp="$WORK_DIR/prevlog.tmp"
        if kc logs -n "$NAMESPACE" "$pod" -c "$cname" --since="$SINCE" --tail="$TAIL_LINES" -p \
                > "$tmp" 2>>"$ERRLOG" && [ -s "$tmp" ]; then
            mv "$tmp" "$d/${cname}.previous.log"
        else
            rm -f "$tmp"
        fi
    done <<EOF
$containers
EOF
    return 0
}

# ===========================================================================
# metrics/ — resource usage (kubectl top, needs metrics-server) and the
# serving engine's own Prometheus /metrics (vLLM/TGI-style), scraped read-only
# through the API-server pod proxy (same mechanism as gpu/ DCGM — no exec, no
# mutation). EVERYTHING here is BEST-EFFORT: metrics-server and an exposed
# /metrics endpoint are both optional, so their absence is recorded, never
# fatal. No inference content is ever touched — /metrics carries only counters
# and gauges (request rates, latency histograms, KV-cache usage, ...).
# ===========================================================================

METRICS_MAX_BYTES=524288    # cap on a scraped /metrics payload (512 KiB)
METRICS_NOTES=""

metrics_note() { [ -n "$1" ] && METRICS_NOTES="${METRICS_NOTES:+$METRICS_NOTES; }$1"; }

collect_metrics() {
    CAPTURE_FAILS=0
    METRICS_NOTES=""
    mkdir -p "$BUNDLE_DIR/metrics"

    collect_top
    collect_serving_metrics

    # top / serving-metrics unavailability is expected (optional components) and
    # is recorded as a note, not a capture failure — the collector stays "ok".
    if [ "$CAPTURE_FAILS" -eq 0 ]; then
        record_collector metrics ok "$METRICS_NOTES"
    else
        record_collector metrics partial "$CAPTURE_FAILS capture(s) failed; $METRICS_NOTES"
    fi
}

collect_top() {
    local nodes="$BUNDLE_DIR/metrics/top-nodes.txt"
    local pods="$BUNDLE_DIR/metrics/top-pods.txt"
    local tmp="$WORK_DIR/top.tmp"

    # kubectl top needs metrics-server; a missing/not-ready server is common,
    # so treat failure as "unavailable" (a note) rather than a hard error.
    if kc top nodes > "$tmp" 2>>"$ERRLOG" && [ -s "$tmp" ]; then
        { printf '# kubectl top nodes\n'; cat "$tmp"; } > "$nodes"
        metrics_note "top nodes ok"
    else
        echo "kubectl top nodes unavailable (metrics-server not installed or not ready)" > "$nodes"
        metrics_note "top nodes unavailable"
    fi

    if kc top pods -n "$NAMESPACE" --containers > "$tmp" 2>>"$ERRLOG" && [ -s "$tmp" ]; then
        { printf '# kubectl top pods -n %s --containers\n' "$NAMESPACE"; cat "$tmp"; } > "$pods"
        metrics_note "top pods ok"
    else
        echo "kubectl top pods unavailable in $NAMESPACE (metrics-server not installed or not ready)" > "$pods"
        metrics_note "top pods unavailable"
    fi
    rm -f "$tmp"
}

collect_serving_metrics() {
    local out_dir="$BUNDLE_DIR/metrics/serving"
    local cands="$WORK_DIR/serving-metrics-candidates.txt"
    local ns pod scraped=0 tried=0 max_tries=3

    # Candidate serving pods = running GPU pods in the target namespace (the
    # inference engine). Same detection as gpu/ nvidia-smi.
    kc get pods -n "$NAMESPACE" \
        -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.containers[*].resources.limits.nvidia\.com/gpu}{"\n"}{end}' \
        2>>"$ERRLOG" | awk '$3 != "" { print $1, $2 }' > "$cands"

    if [ ! -s "$cands" ]; then
        echo "no running GPU (serving) pod found in namespace $NAMESPACE — serving /metrics skipped" \
            > "$BUNDLE_DIR/metrics/serving-metrics.txt"
        metrics_note "no serving pod for /metrics"
        return 0
    fi

    mkdir -p "$out_dir"
    while read -r ns pod; do
        [ -n "$pod" ] || continue
        tried=$((tried + 1))
        [ "$tried" -gt "$max_tries" ] && break
        if scrape_serving_metrics "$ns" "$pod" "$out_dir/${pod}.metrics.txt"; then
            scraped=$((scraped + 1))
        fi
    done < "$cands"

    if [ "$scraped" -eq 0 ]; then
        echo "GPU pod(s) found but no Prometheus /metrics endpoint responded ($tried tried). Not fatal — the serving engine may not expose /metrics, or it is on an unprobed port." \
            > "$out_dir/UNAVAILABLE.txt"
        metrics_note "serving /metrics unavailable ($tried tried)"
    else
        metrics_note "serving /metrics ok ($scraped pod(s))"
    fi
}

scrape_serving_metrics() {
    # Try a pod's Prometheus /metrics over the read-only API-server pod proxy.
    # Returns 0 and writes $out on the first port that returns Prometheus text.
    local ns="$1" pod="$2" out="$3"
    local tmp="$WORK_DIR/serving-metrics.tmp"
    local portspec ports port

    portspec="$(kc get pod -n "$ns" "$pod" \
        -o jsonpath='{range .spec.containers[*]}{range .ports[*]}{.name}{"="}{.containerPort}{"\n"}{end}{end}' \
        2>>"$ERRLOG")"

    # Candidate ports, best first: ports named *metric*, then http/api-ish
    # ports, then the vLLM/TGI default 8000, then every remaining declared
    # containerPort. De-duplicated, order preserved.
    ports="$(
        {
            printf '%s\n' "$portspec" | awk -F= 'tolower($1) ~ /metric/ {print $2}'
            printf '%s\n' "$portspec" | awk -F= 'tolower($1) ~ /http|api/  {print $2}'
            echo 8000
            printf '%s\n' "$portspec" | awk -F= '{print $2}'
        } | awk 'NF && !seen[$0]++'
    )"

    for port in $ports; do
        [ -n "$port" ] || continue
        printf '### serving /metrics GET %s/%s:%s (read-only pod proxy)\n' "$ns" "$pod" "$port" >> "$ERRLOG"
        # A real Prometheus endpoint emits "# HELP"/"# TYPE" lines; requiring
        # them avoids saving HTML/JSON from an unrelated port.
        if kc get --raw "/api/v1/namespaces/${ns}/pods/${pod}:${port}/proxy/metrics" > "$tmp" 2>>"$ERRLOG" \
                && grep -qE '^# (HELP|TYPE) ' "$tmp"; then
            {
                printf '# serving Prometheus /metrics from %s/%s:%s (read-only GET via pod proxy)\n' "$ns" "$pod" "$port"
                head -c "$METRICS_MAX_BYTES" "$tmp"
                [ "$(wc -c < "$tmp")" -gt "$METRICS_MAX_BYTES" ] && printf '\n# [truncated at %s bytes]\n' "$METRICS_MAX_BYTES"
            } > "$out"
            rm -f "$tmp"
            return 0
        fi
    done
    rm -f "$tmp"
    return 1
}

run_collectors() {
    local total name i=1
    total="$(printf '%s\n' $COLLECTORS | wc -l | tr -d ' ')"
    for name in $COLLECTORS; do
        log "[$i/$total] collecting: $name/"
        # Collector errors are recorded, never fatal.
        "collect_$name" || record_collector "$name" failed "collector exited non-zero"
        i=$((i + 1))
    done
    log ""
}

# ===========================================================================
# Redaction engine — ONE pass over every file in $BUNDLE_DIR before archiving.
#
# Defense in depth (the regex net is the LAST line, not the first):
#   1. Never collected      : prompt/completion content, Secret VALUES.
#   2. Wiped at collection   : env var values (write_workload_env), unless the
#                              name is in the audited WORKLOAD_ENV_ALLOWLIST.
#   3. Regex safety net (HERE): scrub anything that still looks like a secret in
#                              config/logs/helm-values — see build_redaction_sed
#                              below, which is the single, human-readable list of
#                              exactly what gets scrubbed.
#   4. Optional (HERE)       : --anonymize-names (hash node/pod/ns names),
#                              --redact-ips (IPv4 addresses).
#
# Every redaction inserts a "<REDACTED...>" marker; counting new markers per
# file gives the redaction summary (redaction-summary.txt + manifest.json).
# ===========================================================================

REDACTION_COUNT=0
ANONYMIZED_NAMES_COUNT=0
NAME_MAP_FILE=""             # local-only reverse map (token -> real name); never archived

# The single, auditable list of what the regex safety net scrubs. A security
# reviewer can read every rule here. Written to $WORK_DIR/redact.sed and applied
# with `sed -E`. Order matters (multi-line key blocks first).
build_redaction_sed() {
    local sedf="$WORK_DIR/redact.sed"
    # Case-insensitive alternation of "sensitive-looking" key-name fragments.
    cat > "$sedf" <<'SED'
# --- Multi-line private key blocks -> single marker (PEM: RSA/EC/OPENSSH/...) ---
/-----BEGIN[A-Z ]*PRIVATE KEY-----/,/-----END[A-Z ]*PRIVATE KEY-----/c\
<REDACTED-PRIVATE-KEY-BLOCK>
# --- Provider / API tokens (matched by shape, anywhere) ---
s/hf_[A-Za-z0-9]{20,}/<REDACTED-HF-TOKEN>/g
s/gh[pousr]_[A-Za-z0-9]{20,}/<REDACTED-GITHUB-TOKEN>/g
s/xox[baprs]-[A-Za-z0-9-]{10,}/<REDACTED-SLACK-TOKEN>/g
s/sk-[A-Za-z0-9]{20,}/<REDACTED-API-TOKEN>/g
s/(AKIA|ASIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA)[0-9A-Z]{16}/<REDACTED-AWS-KEY-ID>/g
s/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}/<REDACTED-JWT>/g
s/([Bb]earer[[:space:]]+)[A-Za-z0-9._~+/-]{8,}=*/\1<REDACTED>/g
# --- key = value / key: value where the KEY NAME looks sensitive ---
# Keeps the key + separator (+ surrounding quotes); wipes only the value.
s/([A-Za-z0-9_.-]*([Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll][Ss]?|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Aa][Cc][Cc][Ee][Ss][Ss][_-]?[Kk][Ee][Yy]|[Kk][Ee][Yy])[[:space:]]*[=:][[:space:]]*)("?)[^"[:space:],}]*("?)/\1\3<REDACTED>\4/g
# --- base64-encoded blobs WITH padding (certs, key material, encoded secrets) ---
# Requires trailing "=" padding so image digests / hex / identifiers are kept.
s/[A-Za-z0-9+/]{24,}={1,2}/<REDACTED-BASE64>/g
# --- email addresses ---
s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z][A-Za-z]+/<REDACTED-EMAIL>/g
SED
    if $REDACT_IPS; then
        cat >> "$sedf" <<'SED'
# --- IPv4 addresses (only with --redact-ips) ---
s/([0-9]{1,3}\.){3}[0-9]{1,3}/<REDACTED-IP>/g
SED
    fi
}

# Consistent, one-way hash of a name -> short token. Deterministic across files
# so "pod-a1b2c3d4" always refers to the same pod. Falls back through the hash
# tools every platform is likely to have.
hash_token() {
    printf '%s' "$1" \
        | { sha256sum 2>/dev/null || shasum -a 256 2>/dev/null || cksum; } \
        | awk '{ print substr($1, 1, 8) }'
}

# Build a fixed-string sed map that replaces node/pod/namespace names with
# stable hashed tokens. Longest names first so substrings never corrupt a
# longer match (e.g. namespace "mistral" inside pod "mistral-0").
build_name_map() {
    local mapf="$WORK_DIR/name-map.sed"
    # The reverse map lives in WORK_DIR, NOT the bundle: shipping token->realname
    # inside the archive would defeat --anonymize-names. It is copied next to the
    # finished archive (see place_name_map) for the operator to keep locally.
    local human="$WORK_DIR/anonymized-names.txt"
    NAME_MAP_FILE="$human"
    : > "$mapf"
    ANONYMIZED_NAMES_COUNT=0

    {
        [ -n "$NAMESPACE" ] && printf '%s ns\n' "$NAMESPACE"
        local n
        for n in $(get_nodes); do [ -n "$n" ] && printf '%s node\n' "$n"; done
        kc get pods -n "$NAMESPACE" -o name 2>>"$ERRLOG" \
            | sed 's|.*/||' | awk 'NF { print $0, "pod" }'
    } \
    | awk 'NF && !seen[$1]++ { print length($1), $0 }' \
    | sort -rn \
    | while read -r _len name kind; do
        [ -n "$name" ] || continue
        local tok esc
        tok="${kind}-$(hash_token "$name")"
        # Escape regex-significant chars that appear in DNS names ('.').
        esc="$(printf '%s' "$name" | sed 's/[.[\*^$/]/\\&/g')"
        printf 's/%s/%s/g\n' "$esc" "$tok" >> "$mapf"
    done

    {
        echo "# --anonymize-names is ON. node/pod/namespace names in this bundle"
        echo "# were replaced with stable hashed tokens (kind-<8 hex>)."
        echo "#"
        echo "# This file is the token -> real-name mapping. It is written NEXT TO"
        echo "# the archive, NOT inside it, so the bundle you send stays anonymous."
        echo "# Keep it PRIVATE. Use it to translate support's replies back to your"
        echo "# real node/pod/namespace names."
        echo
        printf '%-16s   %s\n' "TOKEN" "REAL NAME"
        awk -F'/' '{ printf "%-16s   %s\n", $3, $2 }' "$mapf" 2>/dev/null
    } > "$human"

    # A breadcrumb DOES go inside the bundle so support knows names were hashed.
    {
        echo "Node/pod/namespace names in this bundle were anonymized with"
        echo "--anonymize-names. They appear as stable tokens like pod-a1b2c3d4."
        echo "The token -> real-name mapping is NOT included here (that would"
        echo "defeat anonymization); it was saved locally next to the archive"
        echo "on the machine that generated this bundle."
    } > "$BUNDLE_DIR/anonymized-names.README.txt"

    ANONYMIZED_NAMES_COUNT="$(grep -c . "$mapf" 2>/dev/null | tr -d ' ')"
    ANONYMIZED_NAMES_COUNT="${ANONYMIZED_NAMES_COUNT:-0}"
}

count_markers() { grep -o '<REDACTED' "$1" 2>/dev/null | wc -l | tr -d ' '; }

# With --anonymize-names, real node/pod/namespace names also appear in FILE and
# DIRECTORY names (e.g. cluster/nodes/describe-gpu-node-01.txt). Rewrite every
# path component through the same fixed-string map so nothing leaks via paths.
# -depth => children are renamed before their parents. Never renames the bundle
# root, and never clobbers an existing target.
anonymize_paths() {
    local map="$WORK_DIR/name-map.sed"
    [ -s "$map" ] || return 0
    local p d b nb
    find "$BUNDLE_DIR" -depth 2>/dev/null | while IFS= read -r p; do
        [ "$p" = "$BUNDLE_DIR" ] && continue
        d="$(dirname "$p")"; b="$(basename "$p")"
        nb="$(printf '%s' "$b" | sed -f "$map")"
        [ "$nb" = "$b" ] && continue
        [ -e "$d/$nb" ] && continue
        mv "$p" "$d/$nb" 2>/dev/null || true
    done
}

# Redact one file in place. Echoes the number of NEW <REDACTED...> markers.
redact_file() {
    local f="$1"
    local tmp="$WORK_DIR/redact.tmp"
    local before after added

    # Skip binary and empty files (-I => binary counts as no match).
    LC_ALL=C grep -qI . "$f" 2>/dev/null || { echo 0; return 0; }

    before="$(count_markers "$f")"

    # Name anonymization first (plain sed, fixed strings), then the regex net.
    if $ANONYMIZE_NAMES && [ -s "$WORK_DIR/name-map.sed" ]; then
        sed -f "$WORK_DIR/name-map.sed" "$f" > "$tmp" && mv "$tmp" "$f"
    fi
    sed -E -f "$WORK_DIR/redact.sed" "$f" > "$tmp" && mv "$tmp" "$f"

    after="$(count_markers "$f")"
    added=$((after - before))
    [ "$added" -lt 0 ] && added=0
    echo "$added"
}

redact_bundle() {
    REDACTION_COUNT=0
    if ! $REDACT; then
        warn "redaction pass SKIPPED (--no-redact) — this bundle may contain secrets."
        return 0
    fi

    log "Redaction pass: scanning bundle files..."
    build_redaction_sed
    $ANONYMIZE_NAMES && build_name_map

    local body="$WORK_DIR/redaction-body.txt"
    : > "$body"

    # Snapshot the file list BEFORE writing the summary (so it isn't self-scanned).
    local files f rel c scanned=0
    files="$(find "$BUNDLE_DIR" -type f 2>/dev/null)"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        scanned=$((scanned + 1))
        c="$(redact_file "$f")"
        if [ "${c:-0}" -gt 0 ]; then
            rel="${f#"$BUNDLE_DIR"/}"
            printf '%6d  %s\n' "$c" "$rel" >> "$body"
            REDACTION_COUNT=$((REDACTION_COUNT + c))
        fi
    done <<EOF
$files
EOF

    # Anonymize path components too, and rewrite the summary's own path column
    # through the same map so real names don't survive in redaction-summary.txt.
    if $ANONYMIZE_NAMES && [ -s "$WORK_DIR/name-map.sed" ]; then
        anonymize_paths
        if [ -s "$body" ]; then
            sed -f "$WORK_DIR/name-map.sed" "$body" > "$body.anon" \
                && mv "$body.anon" "$body"
        fi
    fi

    {
        echo "# Redaction summary (regex safety net + optional name/IP redaction)."
        echo "# Counts are new <REDACTED...> markers inserted per file."
        echo "# Also enforced earlier: env values wiped at collection, Secret"
        echo "# values never collected, no inference content ever touched."
        echo
        printf 'total values redacted : %s\n' "$REDACTION_COUNT"
        printf 'files scanned         : %s\n' "$scanned"
        printf 'anonymize-names       : %s' "$ANONYMIZE_NAMES"
        $ANONYMIZE_NAMES && printf ' (%s name(s) mapped)' "$ANONYMIZED_NAMES_COUNT"
        printf '\n'
        printf 'redact-ips            : %s\n' "$REDACT_IPS"
        echo
        if [ "$REDACTION_COUNT" -gt 0 ]; then
            echo "per-file (count  path):"
            sort -rn "$body"
        else
            echo "No regex-matched secrets found in collected files (good — the"
            echo "collection-time controls above already keep secrets out)."
        fi
    } > "$BUNDLE_DIR/redaction-summary.txt"

    log "Redaction pass: $REDACTION_COUNT value(s) redacted across $scanned file(s)."
    $ANONYMIZE_NAMES && log "  anonymized $ANONYMIZED_NAMES_COUNT name(s) (mapping kept local, next to the archive)."
}

# ---------------------------------------------------------------------------
# manifest.json
# ---------------------------------------------------------------------------

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n'
}

write_manifest() {
    local manifest="$BUNDLE_DIR/manifest.json"
    {
        printf '{\n'
        printf '  "tool": "%s",\n'                    "$TOOL_NAME"
        printf '  "tool_version": "%s",\n'            "$TOOL_VERSION"
        printf '  "generated_at_utc": "%s",\n'        "$TIMESTAMP_UTC"
        printf '  "kubectl_client_version": "%s",\n'  "$(json_escape "${KUBECTL_CLIENT_VERSION:-unknown}")"
        printf '  "kubernetes_server_version": "%s",\n' "$(json_escape "${KUBE_SERVER_VERSION:-unknown}")"
        printf '  "context": "%s",\n'                 "$(json_escape "$KUBE_CONTEXT")"
        printf '  "namespace": "%s",\n'               "$(json_escape "$NAMESPACE")"
        printf '  "flags": {\n'
        printf '    "since": "%s",\n'                 "$(json_escape "$SINCE")"
        printf '    "tail": %s,\n'                    "$TAIL_LINES"
        printf '    "anonymize_names": %s,\n'         "$ANONYMIZE_NAMES"
        printf '    "redact_ips": %s,\n'              "$REDACT_IPS"
        printf '    "redact": %s\n'                   "$REDACT"
        printf '  },\n'
        printf '  "optional_tools": {\n'
        printf '    "helm": %s,\n'                    "$HAVE_HELM"
        printf '    "jq": %s,\n'                      "$HAVE_JQ"
        printf '    "zip": %s\n'                      "$HAVE_ZIP"
        printf '  },\n'
        printf '  "collectors": [\n'
        local first=true name status note
        while IFS='|' read -r name status note; do
            $first || printf ',\n'
            first=false
            printf '    { "name": "%s", "status": "%s", "note": "%s" }' \
                "$(json_escape "$name")" "$(json_escape "$status")" "$(json_escape "$note")"
        done < "$COLLECTOR_STATUS_FILE"
        printf '\n  ],\n'
        printf '  "redaction": {\n'
        printf '    "applied": %s,\n'                 "$REDACT"
        printf '    "total_redactions": %s\n'         "$REDACTION_COUNT"
        printf '  }\n'
        printf '}\n'
    } > "$manifest"

    # manifest.json is written AFTER the redaction pass (so its own flags aren't
    # scrubbed), but collector "note" fields can embed real pod/node names. When
    # anonymizing, run just the fixed-string name map over it — no secret regex.
    if $ANONYMIZE_NAMES && [ -s "$WORK_DIR/name-map.sed" ]; then
        sed -f "$WORK_DIR/name-map.sed" "$manifest" > "$manifest.anon" \
            && mv "$manifest.anon" "$manifest"
    fi

    if $HAVE_JQ; then
        jq . "$manifest" >/dev/null 2>&1 || warn "manifest.json failed jq validation (tool bug — please report)"
    fi
}

# ---------------------------------------------------------------------------
# README-INSIDE.txt — privacy statement shipped inside the bundle
# ---------------------------------------------------------------------------
# Static, human-readable note so anyone opening the archive knows what is (and
# is not) in it and how to inspect it before sending. No cluster data here.

write_readme_inside() {
    {
        echo "$TOOL_NAME v$TOOL_VERSION — what is in this bundle"
        echo "===================================================="
        echo
        echo "This archive was produced by $TOOL_NAME, a READ-ONLY diagnostic"
        echo "collector for Mistral LLM deployments on Kubernetes. It is meant to be"
        echo "attached to a support ticket. Everything in it is plain text or JSON —"
        echo "open it and inspect it before you send it."
        echo
        echo "WHAT WAS COLLECTED"
        echo "  cluster/   kubectl + Kubernetes versions, nodes, storage classes,"
        echo "             distro / CNI hints"
        echo "  gpu/       GPU node labels, device-plugin / GPU Operator status,"
        echo "             nvidia-smi (best-effort read-only exec), DCGM metrics"
        echo "  workload/  serving Deployment/StatefulSet spec, images, resources,"
        echo "             serving-engine args, referenced ConfigMaps, Helm values"
        echo "  state/     namespace events, pod/container status, OOMKill/CrashLoop"
        echo "  logs/      bounded recent logs (current + previous containers)"
        echo "  metrics/   kubectl top nodes/pods, serving /metrics (best-effort)"
        echo "  manifest.json, SUMMARY.txt, redaction-summary.txt"
        echo
        echo "WHAT WAS **NOT** COLLECTED, EVER"
        echo "  - No prompt / completion / request / response content. This tool"
        echo "    never touches inference payloads."
        echo "  - No Secret values. At most, Secret names and key names are recorded."
        echo "  - No environment-variable values, except a short, audited allow-list"
        echo "    of non-sensitive serving parameters (e.g. TENSOR_PARALLEL_SIZE,"
        echo "    MAX_MODEL_LEN)."
        echo
        echo "REDACTION"
        echo "  A single redaction pass ran over every file before archiving: env"
        echo "  values are wiped, and a regex safety net scrubs tokens, keys, JWTs,"
        echo "  private-key blocks, padded base64 blobs and email addresses."
        echo "  Values redacted: $REDACTION_COUNT (per-file counts in redaction-summary.txt)."
        if $ANONYMIZE_NAMES; then
            echo "  Node/pod/namespace names were anonymized (--anonymize-names). The"
            echo "  reverse map is kept OUTSIDE this archive, next to it on the machine"
            echo "  that ran the tool."
        else
            echo "  Node/pod/namespace names were NOT anonymized (the default). Re-run"
            echo "  with --anonymize-names if you need them hashed."
        fi
        $REDACT || {
            echo
            echo "  WARNING: redaction was DISABLED for this run (--no-redact)."
            echo "  Treat this bundle as sensitive."
        }
        echo
        echo "HOW TO INSPECT BEFORE SENDING"
        echo "  unzip -l <archive>.zip     # or: tar tzf <archive>.tar.gz"
        echo "  less SUMMARY.txt           # at-a-glance findings"
        echo "  less redaction-summary.txt # what was scrubbed, per file"
        echo
        echo "No network calls, no upload, and no telemetry were made by this tool."
    } > "$BUNDLE_DIR/README-INSIDE.txt"
}

# ---------------------------------------------------------------------------
# SUMMARY.txt — the at-a-glance page a support engineer reads first
# ---------------------------------------------------------------------------
# Derived from files already in the (redacted) bundle plus safe globals. Runs
# AFTER the redaction pass, so it inherits redacted/anonymized content; under
# --anonymize-names any names it prints are run through the same name map last.

write_summary() {
    local out="$BUNDLE_DIR/SUMMARY.txt"
    local node_count=0 gpu_count=0 distro="unknown" wl_spec hits

    if [ -f "$BUNDLE_DIR/cluster/nodes-wide.txt" ]; then
        node_count="$(grep -cvE '^NAME|^[[:space:]]*$' "$BUNDLE_DIR/cluster/nodes-wide.txt" 2>/dev/null)"
        node_count="${node_count:-0}"
    fi

    if [ -f "$BUNDLE_DIR/gpu/gpu-nodes.txt" ]; then
        gpu_count="$(grep -cE '^nvidia\.com/gpu capacity[[:space:]]*:[[:space:]]*[0-9]' "$BUNDLE_DIR/gpu/gpu-nodes.txt" 2>/dev/null)"
        gpu_count="${gpu_count:-0}"
    fi

    if [ -f "$BUNDLE_DIR/cluster/distro-hint.txt" ]; then
        distro="$(grep -vE '^#|^[[:space:]]*$' "$BUNDLE_DIR/cluster/distro-hint.txt" 2>/dev/null | head -1)"
        distro="${distro:-unknown}"
    fi

    wl_spec="$(ls "$BUNDLE_DIR"/workload/*/spec-summary.txt 2>/dev/null | head -1)"

    {
        echo "$TOOL_NAME v$TOOL_VERSION — support bundle summary"
        echo "===================================================="
        echo
        echo "Generated : $TIMESTAMP_HUMAN  ($TIMESTAMP_UTC)"
        echo "Context   : $KUBE_CONTEXT"
        echo "Namespace : ${NAMESPACE:-<none>}"
        echo
        echo "-- Cluster -----------------------------------------------------------"
        echo "  kubectl (client) : ${KUBECTL_CLIENT_VERSION:-unknown}"
        echo "  kubernetes (srv) : ${KUBE_SERVER_VERSION:-unknown}"
        echo "  distro hint      : $distro"
        echo "  nodes            : $node_count"
        echo "  GPU nodes        : $gpu_count (advertising nvidia.com/gpu)"
        echo
        echo "-- Workload / serving config -----------------------------------------"
        if [ -n "$wl_spec" ] && [ -f "$wl_spec" ]; then
            grep -E '^(kind|name|helm chart|replicas)' "$wl_spec" 2>/dev/null | sed 's/^/  /'
            echo "  images:"
            awk '/^\[images\]/{f=1;next} /^\[/{f=0} f && NF && $0 !~ /init\//{print "   "$0}' "$wl_spec" 2>/dev/null | head -4
            echo "  serving flags (detected):"
            hits="$(grep -iE 'tensor.parallel|max.model.len|quantization|dtype|gpu.memory.util|kv.cache|max.num.(seqs|batched)' "$wl_spec" 2>/dev/null | sed 's/^[[:space:]]*/   /' | head -12)"
            if [ -n "$hits" ]; then printf '%s\n' "$hits"; else echo "   (none matched — see workload/*/spec-summary.txt)"; fi
        else
            echo "  no GPU workload spec captured (see workload/)."
        fi
        echo
        echo "-- Metrics -----------------------------------------------------------"
        if [ -f "$BUNDLE_DIR/metrics/top-nodes.txt" ] && grep -q '^# kubectl top nodes' "$BUNDLE_DIR/metrics/top-nodes.txt" 2>/dev/null; then
            echo "  top nodes (CPU/mem):"
            grep -vE '^#|^[[:space:]]*$' "$BUNDLE_DIR/metrics/top-nodes.txt" 2>/dev/null | sed 's/^/    /' | head -6
        else
            echo "  top nodes       : unavailable (metrics-server not installed or not ready)"
        fi
        if [ -f "$BUNDLE_DIR/metrics/top-pods.txt" ] && grep -q '^# kubectl top pods' "$BUNDLE_DIR/metrics/top-pods.txt" 2>/dev/null; then
            echo "  top pods (first rows):"
            grep -vE '^#|^[[:space:]]*$' "$BUNDLE_DIR/metrics/top-pods.txt" 2>/dev/null | sed 's/^/    /' | head -6
        else
            echo "  top pods        : unavailable in ${NAMESPACE:-<none>} (metrics-server not installed or not ready)"
        fi
        if ls "$BUNDLE_DIR"/metrics/serving/*.metrics.txt >/dev/null 2>&1; then
            local sm_count
            sm_count="$(ls "$BUNDLE_DIR"/metrics/serving/*.metrics.txt 2>/dev/null | wc -l | tr -d ' ')"
            echo "  serving /metrics: captured for $sm_count pod(s) (see metrics/serving/)"
        elif [ -f "$BUNDLE_DIR/metrics/serving/UNAVAILABLE.txt" ]; then
            echo "  serving /metrics: unavailable (no Prometheus endpoint responded)"
        elif [ -f "$BUNDLE_DIR/metrics/serving-metrics.txt" ]; then
            echo "  serving /metrics: skipped (no running GPU/serving pod)"
        else
            echo "  serving /metrics: not collected"
        fi
        echo
        echo "-- Red flags ---------------------------------------------------------"
        if [ -f "$BUNDLE_DIR/state/anomalies.txt" ]; then
            if grep -q 'No OOMKills' "$BUNDLE_DIR/state/anomalies.txt" 2>/dev/null; then
                echo "  none detected (no OOMKills, CrashLoops, image-pull errors, high restarts)"
            else
                grep -vE '^#|^[[:space:]]*$' "$BUNDLE_DIR/state/anomalies.txt" 2>/dev/null | sed 's/^/  /' | head -20
            fi
        else
            echo "  state/ not collected."
        fi
        echo
        echo "-- Collectors --------------------------------------------------------"
        if [ -f "$COLLECTOR_STATUS_FILE" ]; then
            awk -F'|' '{ printf "  %-9s %s%s\n", $1, $2, ($3==""?"":"  ("$3")") }' "$COLLECTOR_STATUS_FILE"
        else
            echo "  (collector status unavailable)"
        fi
        echo
        echo "-- Privacy -----------------------------------------------------------"
        echo "  redaction      : $($REDACT && echo ON || echo 'OFF (--no-redact)')"
        echo "  values scrubbed: $REDACTION_COUNT (see redaction-summary.txt)"
        if $ANONYMIZE_NAMES; then
            echo "  anonymize-names: true ($ANONYMIZED_NAMES_COUNT name(s); map kept OUTSIDE the archive)"
        else
            echo "  anonymize-names: false"
        fi
        echo "  redact-ips     : $REDACT_IPS"
        echo
        echo "At-a-glance only. Full detail is in the directories above; manifest.json"
        echo "has the machine-readable record. Inspect this archive before sending."
    } > "$out"

    # Consistency with the rest of the bundle: if names were anonymized, run the
    # same fixed-string map over the summary so no real name survives here.
    if $ANONYMIZE_NAMES && [ -s "$WORK_DIR/name-map.sed" ]; then
        sed -f "$WORK_DIR/name-map.sed" "$out" > "$out.anon" && mv "$out.anon" "$out"
    fi
}

# ---------------------------------------------------------------------------
# Archive
# ---------------------------------------------------------------------------

resolve_archive_path() {
    # -o may be a directory or an explicit .zip/.tar.gz file path.
    case "$OUTPUT_PATH" in
        *.zip)
            $HAVE_ZIP || { warn "zip not available; writing ${OUTPUT_PATH%.zip}.tar.gz instead."; OUTPUT_PATH="${OUTPUT_PATH%.zip}.tar.gz"; }
            ARCHIVE_PATH="$OUTPUT_PATH" ;;
        *.tar.gz)
            ARCHIVE_PATH="$OUTPUT_PATH" ;;
        *)
            mkdir -p "$OUTPUT_PATH" || die "cannot create output directory: $OUTPUT_PATH"
            if $HAVE_ZIP; then
                ARCHIVE_PATH="$OUTPUT_PATH/$BUNDLE_NAME.zip"
            else
                ARCHIVE_PATH="$OUTPUT_PATH/$BUNDLE_NAME.tar.gz"
            fi ;;
    esac
}

# Copy the local-only anonymized-names map next to the finished archive, so the
# operator keeps the token -> real-name key without it ever entering the bundle.
place_name_map() {
    $ANONYMIZE_NAMES || return 0
    [ -s "$NAME_MAP_FILE" ] || return 0
    local dest="${ARCHIVE_PATH%.zip}"; dest="${dest%.tar.gz}-anonymized-names.txt"
    if cp "$NAME_MAP_FILE" "$dest" 2>/dev/null; then
        NAME_MAP_FILE="$dest"
    fi
}

archive_bundle() {
    resolve_archive_path

    case "$ARCHIVE_PATH" in
        *.zip)
            # -q quiet, -r recursive; empty dirs are preserved.
            ( cd "$WORK_DIR" && zip -q -r "$ARCHIVE_PATH" "$BUNDLE_NAME" ) \
                || die "failed to create zip archive at $ARCHIVE_PATH" ;;
        *.tar.gz)
            $HAVE_ZIP || warn "zip not found — falling back to tar.gz."
            tar -czf "$ARCHIVE_PATH" -C "$WORK_DIR" "$BUNDLE_NAME" \
                || die "failed to create tar.gz archive at $ARCHIVE_PATH" ;;
    esac
}

# ---------------------------------------------------------------------------
# Dry run — list the plan, contact nothing
# ---------------------------------------------------------------------------

dry_run_plan() {
    cat <<EOF
DRY RUN — nothing will be collected, the cluster will not be contacted.

  context    : $KUBE_CONTEXT (from local kubeconfig)
  namespace  : ${NAMESPACE:-<auto-detect GPU namespaces at runtime>}
  output     : $OUTPUT_PATH
  log window : --since $SINCE, --tail $TAIL_LINES
  redaction  : $($REDACT && echo "ON (regex safety net + env-value wipe)" || echo "OFF (--no-redact)")
  anonymize  : $ANONYMIZE_NAMES (node/pod/namespace names)
  redact-ips : $REDACT_IPS

Planned bundle tree (all commands read-only):

  cluster/    kubectl version; get/describe nodes; storage classes
  gpu/        GPU node labels; nvidia-device-plugin + GPU Operator status/logs;
              best-effort read-only exec of nvidia-smi; DCGM /metrics
  workload/   serving Deployment/StatefulSet spec (env values wiped);
              serving-engine config (TP size, max-model-len, quant, ...);
              helm list/values/manifest (redacted)$($HAVE_HELM || echo " [SKIPPED: helm missing]")
  state/      namespace events; pod status; OOMKilled/CrashLoop detection
  logs/       bounded logs, current + previous containers
  metrics/    kubectl top nodes/pods; serving /metrics (best-effort)
  manifest.json, SUMMARY.txt, README-INSIDE.txt

Never collected: prompt/completion content, Secret values, env var values
(except a short allowlist of known-safe serving parameters).
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"

    log "$TOOL_NAME v$TOOL_VERSION"
    log ""

    preflight

    if $DRY_RUN; then
        dry_run_plan
        exit 0
    fi

    [ -n "$NAMESPACE" ] || detect_namespace
    confirm_context
    setup_workdir
    run_collectors
    redact_bundle
    write_manifest
    write_readme_inside
    write_summary
    archive_bundle
    place_name_map

    log ""
    log "Bundle written: $ARCHIVE_PATH"
    log "Redactions: $REDACTION_COUNT value(s) scrubbed (see redaction-summary.txt)"
    $ANONYMIZE_NAMES && log "Name map (KEEP PRIVATE): $NAME_MAP_FILE"
    log "The archive is plain text — inspect it before sending to support."
}

# Source guard: allow the test harness to source this file for its functions
# (globals + collectors + redaction) WITHOUT running a collection. Set
# MFB_LIB_ONLY=1, or source it (BASH_SOURCE != $0), to load-only.
if [ "${MFB_LIB_ONLY:-0}" != "1" ] && [ "${BASH_SOURCE:-$0}" = "$0" ]; then
    main "$@"
fi
