#!/usr/bin/env bash
#
# Redaction test harness for mistral-furball.sh
#
# Sources the main script in library-only mode (MFB_LIB_ONLY=1), plants files
# containing fake secrets into a throwaway BUNDLE_DIR, runs the real redaction
# functions, and asserts that:
#   - a <REDACTED...> marker was inserted for each secret shape, and
#   - the raw secret is gone from the file.
#
# TAP-ish output; exits non-zero if any assertion fails. No cluster contact.
#
# Usage:  bash test/redaction-test.sh
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN="$SCRIPT_DIR/../mistral-furball.sh"

# --- source the library ----------------------------------------------------
export MFB_LIB_ONLY=1
# shellcheck disable=SC1090
. "$MAIN"

# --- tiny test framework ---------------------------------------------------
TESTS=0
FAILS=0
ok()   { TESTS=$((TESTS+1)); printf 'ok %d - %s\n' "$TESTS" "$1"; }
nok()  { TESTS=$((TESTS+1)); FAILS=$((FAILS+1)); printf 'not ok %d - %s\n' "$TESTS" "$1"; }

# assert file CONTAINS a fixed string
has() { # has <file> <needle> <desc>
    if grep -qF -- "$2" "$1"; then ok "$3"; else nok "$3 (missing: $2)"; fi
}
# assert file DOES NOT contain a fixed string
hasnt() { # hasnt <file> <needle> <desc>
    if grep -qF -- "$2" "$1"; then nok "$3 (leaked: $2)"; else ok "$3"; fi
}

# --- sandbox ---------------------------------------------------------------
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/msb-redaction-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
WORK_DIR="$SANDBOX/work"
BUNDLE_DIR="$WORK_DIR/bundle"
ERRLOG="$BUNDLE_DIR/collect-errors.log"
mkdir -p "$BUNDLE_DIR/workload" "$BUNDLE_DIR/logs"
: > "$ERRLOG"

# ===========================================================================
# Test 1: regex safety net (default flags: no IP redaction, no anonymize)
# ===========================================================================
REDACT_IPS=false
ANONYMIZE_NAMES=false

SECRETS="$BUNDLE_DIR/workload/config.yaml"
cat > "$SECRETS" <<'EOF'
# innocuous key names below so the token SHAPE rules (not the key-name rule)
# are what fire; the key-name rule is exercised by password/api_key lines.
note: downloading model with hf_abcdefghijklmnopqrstuvwxyz012345 now
github: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
comment: openai handle sk-abcdefghijklmnopqrstuvwxyz0123456789 used
password: hunter2supersecret
api_key = "AKIWONTMATCH_but_key_name_does"
aws_access_key_id: AKIAIOSFODNN7EXAMPLE
jwt: eyJhbGciOiJIUzI1NiI.eyJzdWIiOiIxMjM0NTY3ODkw.SflKxwRJSMeKKF2QT4fw
authorization: Bearer abc123def456ghi789jkl012mno345
contact_email: alice.ops@example.com
tls_cert_b64: TWlzdHJhbEFJU3VwZXJTZWNyZXRDZXJ0aWZpY2F0ZURhdGE9PQ==
image_digest: sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
serving_version: 1.29.1
node_ip: 10.42.13.7
EOF

cat > "$BUNDLE_DIR/workload/key.pem" <<'EOF'
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEArandombase64keymaterialthatshouldnevereverleakout123
abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/aaaa
-----END RSA PRIVATE KEY-----
EOF

build_redaction_sed
n1="$(redact_file "$SECRETS")"
_="$(redact_file "$BUNDLE_DIR/workload/key.pem")"

has   "$SECRETS" "<REDACTED-HF-TOKEN>"     "hf_ token redacted"
hasnt "$SECRETS" "hf_abcdefghijklmnop"     "hf_ token value gone"
has   "$SECRETS" "<REDACTED-GITHUB-TOKEN>" "github token redacted"
has   "$SECRETS" "<REDACTED-API-TOKEN>"    "sk- token redacted"
has   "$SECRETS" "<REDACTED-AWS-KEY-ID>"   "AWS access key id redacted"
hasnt "$SECRETS" "AKIAIOSFODNN7EXAMPLE"    "AWS key value gone"
has   "$SECRETS" "<REDACTED-JWT>"          "JWT redacted"
has   "$SECRETS" "<REDACTED>"              "key:value (password/bearer) redacted"
hasnt "$SECRETS" "hunter2supersecret"      "password value gone"
has   "$SECRETS" "<REDACTED-EMAIL>"        "email redacted"
hasnt "$SECRETS" "alice.ops@example.com"   "email value gone"
has   "$SECRETS" "<REDACTED-BASE64>"       "padded base64 blob redacted"

# Things that must SURVIVE (no over-redaction):
has   "$SECRETS" "sha256:0123456789abcdef" "image digest (hex, no padding) preserved"
has   "$SECRETS" "1.29.1"                  "version string preserved"
# IPs kept when --redact-ips is off:
has   "$SECRETS" "10.42.13.7"              "IP preserved when redact-ips off"

has   "$BUNDLE_DIR/workload/key.pem" "<REDACTED-PRIVATE-KEY-BLOCK>" "PEM block collapsed to marker"
hasnt "$BUNDLE_DIR/workload/key.pem" "MIIEowIBAAKCAQEA"              "PEM key material gone"

# marker count sanity: redact_file must report > 0 for the secrets file
if [ "${n1:-0}" -gt 0 ]; then ok "redact_file reported $n1 markers"; else nok "redact_file returned 0 for secrets file"; fi

# ===========================================================================
# Test 2: --redact-ips ON
# ===========================================================================
REDACT_IPS=true
IPFILE="$BUNDLE_DIR/logs/net.log"
cat > "$IPFILE" <<'EOF'
endpoint 10.42.13.7:8080 reached; peer 192.168.0.254 ok; version 1.29.1
EOF
build_redaction_sed          # rebuild: now appends the IPv4 rule
_="$(redact_file "$IPFILE")"
has   "$IPFILE" "<REDACTED-IP>" "IPv4 redacted with --redact-ips"
hasnt "$IPFILE" "10.42.13.7"    "IPv4 value gone"
hasnt "$IPFILE" "192.168.0.254" "second IPv4 value gone"
has   "$IPFILE" "1.29.1"        "version string still preserved with redact-ips"

# ===========================================================================
# Test 3: --anonymize-names (stub cluster-facing functions after sourcing)
# ===========================================================================
REDACT_IPS=false
ANONYMIZE_NAMES=true
NAMESPACE="mistral"
NODES_CACHE=""                       # reset the get_nodes cache
get_nodes() { printf '%s\n' "gpu-node-01" "gpu-node-02"; }
kc() {
    # only need: kc get pods -n <ns> -o name
    case "$*" in
        *"get pods"*) printf '%s\n' "pod/mistral-serving-0" "pod/mistral-serving-1" ;;
        *) return 0 ;;
    esac
}

build_name_map

NFILE="$BUNDLE_DIR/logs/app.log"
cat > "$NFILE" <<'EOF'
namespace mistral: pod mistral-serving-0 on node gpu-node-01 started
pod mistral-serving-1 on node gpu-node-02 crashlooping
EOF
build_redaction_sed
_="$(redact_file "$NFILE")"

hasnt "$NFILE" "mistral-serving-0" "pod name anonymized"
hasnt "$NFILE" "gpu-node-01"       "node name anonymized"
has   "$NFILE" "pod-"              "pod token present"
has   "$NFILE" "node-"             "node token present"
has   "$NAME_MAP_FILE" "mistral-serving-0" "name map records original pod name"
hasnt "$BUNDLE_DIR/anonymized-names.README.txt" "mistral-serving-0" "bundle breadcrumb does NOT leak real names"
# the reverse map must live OUTSIDE the bundle (not archived)
case "$NAME_MAP_FILE" in
    "$BUNDLE_DIR"/*) nok "name map is inside the bundle (would defeat anonymization)" ;;
    *) ok "name map lives outside the bundle" ;;
esac

# determinism: same input -> same token across two files
NFILE2="$BUNDLE_DIR/logs/app2.log"
echo "pod mistral-serving-0 again" > "$NFILE2"
_="$(redact_file "$NFILE2")"
tok1="$(grep -o 'pod-[0-9a-f]\{8\}' "$NFILE"  | head -1)"
tok2="$(grep -o 'pod-[0-9a-f]\{8\}' "$NFILE2" | head -1)"
if [ -n "$tok1" ] && [ "$tok1" = "$tok2" ]; then
    ok "anonymized token is deterministic across files ($tok1)"
else
    nok "anonymized token not deterministic ('$tok1' vs '$tok2')"
fi

# ===========================================================================
# Test 4: binary / empty files are skipped (no crash, returns 0)
# ===========================================================================
printf '\x00\x01\x02binary\x00stuff' > "$BUNDLE_DIR/logs/blob.bin"
: > "$BUNDLE_DIR/logs/empty.log"
bn="$(redact_file "$BUNDLE_DIR/logs/blob.bin")"
en="$(redact_file "$BUNDLE_DIR/logs/empty.log")"
if [ "${bn:-x}" = "0" ]; then ok "binary file skipped (0 markers)"; else nok "binary file not skipped ($bn)"; fi
if [ "${en:-x}" = "0" ]; then ok "empty file skipped (0 markers)";  else nok "empty file not skipped ($en)"; fi

# ---------------------------------------------------------------------------
printf '\n1..%d\n' "$TESTS"
if [ "$FAILS" -eq 0 ]; then
    printf 'PASS: all %d assertions passed.\n' "$TESTS"
    exit 0
else
    printf 'FAIL: %d of %d assertions failed.\n' "$FAILS" "$TESTS"
    exit 1
fi
