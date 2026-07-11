#!/usr/bin/env bash
#
# mistral-support-bundle.sh
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
#     file before archiving (see lib/redact-patterns.txt in later milestones).
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

TOOL_NAME="mistral-support-bundle"
TOOL_VERSION="0.1.0"

# ---------------------------------------------------------------------------
# Defaults / globals
# ---------------------------------------------------------------------------

NAMESPACE=""                 # -n/--namespace; auto-detected if empty
OUTPUT_PATH="$PWD"           # -o/--output; dir or explicit .zip/.tar.gz path
SINCE="1h"                   # --since; log window
TAIL_LINES=500               # --tail; max log lines per container
ANONYMIZE_NAMES=false        # --anonymize-names
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

# --- Milestones 3-5: stubs. ------------------------------------------------

collect_workload() { record_collector workload not_implemented "milestone 3: serving workload spec, helm, serving-engine config"; }
collect_state()    { record_collector state    not_implemented "milestone 4: events, pod status, OOMKill/CrashLoop detection"; }
collect_logs()     { record_collector logs     not_implemented "milestone 4: bounded logs, current + previous containers"; }
collect_metrics()  { record_collector metrics  not_implemented "milestone 5: kubectl top, serving /metrics (best-effort)"; }

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

# ---------------------------------------------------------------------------
# Redaction (milestone 6 — stub for now)
#
# Final design: one pass over every file in $BUNDLE_DIR before archiving —
# env-value wipe + Secret skip happen at collection time; the regex safety
# net (lib/redact-patterns.txt) runs here. Counts land in manifest.json.
# ---------------------------------------------------------------------------

REDACTION_COUNT=0

redact_bundle() {
    if ! $REDACT; then
        warn "redaction pass SKIPPED (--no-redact)."
        return 0
    fi
    log "Redaction pass: engine not yet implemented (milestone 6) — 0 files scanned."
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

    if $HAVE_JQ; then
        jq . "$manifest" >/dev/null 2>&1 || warn "manifest.json failed jq validation (tool bug — please report)"
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
  redaction  : $($REDACT && echo ON || echo "OFF (--no-redact)")
  anonymize  : $ANONYMIZE_NAMES

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
    archive_bundle

    log ""
    log "Bundle written: $ARCHIVE_PATH"
    log "Redactions: $REDACTION_COUNT (engine lands in milestone 6)"
    log "The archive is plain text — inspect it before sending to support."
}

main "$@"
