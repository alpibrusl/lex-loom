#!/usr/bin/env bash
# jt1-run-on-kvm-host.sh -- drive demo/jt1-loom-tools-in-box.sh on the KVM host
# (HOST = the ssh alias of your KVM host) from this Mac: generate loom's research and
# old-shape manifests with lex here, ship them with loom's scripts, run the
# test as root there, and bring back the audit logs.
#
#   HOST=<kvm-host> bin/jt1-run-on-kvm-host.sh        # MODEL_HOST defaults to <this Mac>:4000
#   HOST=<kvm-host> FRESH_ROOTFS=1 bin/jt1-run-on-kvm-host.sh
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${HOST:?HOST is required: the ssh alias of your KVM host}"
MODEL_HOST="${MODEL_HOST:-$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1):4000}"
MODEL_NAME="${MODEL_NAME:-qwen3.8:27b-mlx}"
W="$(mktemp -d "${TMPDIR:-/tmp}/loom-jt1.XXXXXX")"; trap 'rm -rf "$W"' EXIT
unquote() { python3 -c 'import sys,json; print(json.loads(sys.stdin.read()))'; }
lex run src/manifests.lex manifest_json_for_kind '"opportunity_research"' '"jt1/iter-1"' | unquote > "$W/research-manifest.json"
lex run src/manifests.lex manifest_json_for_kind '"demo"' '"jt1/iter-1"' | unquote > "$W/old-shape-manifest.json"
mkdir -p "$W/bin"; cp bin/web_search.py bin/check_research_report.py bin/extract_fenced.py "$W/bin/"
cp demo/jt1-loom-tools-in-box.sh "$W/"
echo "[jt1] model endpoint for the box: $MODEL_HOST ($MODEL_NAME); host: $HOST"
curl -s --max-time 5 "http://$MODEL_HOST/v1/models" >/dev/null || { echo "[jt1] LiteLLM not answering at $MODEL_HOST from this Mac; start it (bin/litellm-up.sh) first" >&2; exit 1; }
ssh "$HOST" 'rm -rf /tmp/jt1 && mkdir -p /tmp/jt1'
scp -q -r "$W"/. "$HOST:/tmp/jt1/"
ssh -t "$HOST" "sudo env JT_DIR=/tmp/jt1 MODEL_HOST='$MODEL_HOST' MODEL_NAME='$MODEL_NAME' FRESH_ROOTFS='${FRESH_ROOTFS:-0}' bash /tmp/jt1/jt1-loom-tools-in-box.sh"
mkdir -p evals/jt1; scp -q "$HOST:/tmp/jt1/*.audit.json" evals/jt1/ 2>/dev/null || true
echo "[jt1] audit logs in evals/jt1/"
