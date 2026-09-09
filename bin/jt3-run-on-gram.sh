#!/usr/bin/env bash
# jt3-run-on-gram.sh -- drive lex-loom#415 step 3 on the KVM host (`gram`):
# a whole ResearchCo company inside one lex-os box.
#   1. (optional) check out and build a lex-os ref there (LEXOS_REF; the
#      machine-config knob landed in lex-os#107)
#   2. ship a snapshot of THIS lex-loom checkout, the warm lex package cache,
#      loom's research manifest and the contract goal
#   3. build the company rootfs once (FRESH_ROOTFS=1 to rebuild)
#   4. run the company in the box and bring back what it wrote (evals/jt3/)
#   HOST=gram MODEL_HOST=<mac>:4000 LEXOS_REF=main bin/jt3-run-on-gram.sh
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${HOST:-gram}"
MODEL_HOST="${MODEL_HOST:-$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1):4000}"
MODEL_NAME="${MODEL_NAME:-qwen3.8:27b-mlx}"
GOAL_TOML="${GOAL_TOML:-$HOME/loom-companies/run2-awaiting-answer-archive/researchco.company.toml}"
W="$(mktemp -d "${TMPDIR:-/tmp}/loom-jt3.XXXXXX")"; trap 'rm -rf "$W"' EXIT
unquote() { python3 -c 'import sys,json; print(json.loads(sys.stdin.read()))'; }
lex run src/manifests.lex manifest_json_for_kind '"opportunity_research"' '"jt3/iter-1"' | unquote > "$W/research-manifest.json"
python3 -c 'import tomllib,sys; print(tomllib.load(open(sys.argv[1],"rb"))["identity"]["mission"])' "$GOAL_TOML" > "$W/goal.txt"
git archive --format=tar.gz -o "$W/loom.tgz" HEAD
tar -czf "$W/packages.tgz" -C "$HOME/.lex" packages
mkdir -p "$W/bin"; cp bin/check_research_report.py "$W/bin/"
cp demo/jt3-build-company-rootfs.sh demo/jt3-company-in-box.sh "$W/"
echo "[jt3] host=$HOST model=$MODEL_HOST ($MODEL_NAME); goal: $(head -c 90 "$W/goal.txt")..."
curl -s --max-time 5 "http://$MODEL_HOST/v1/models" >/dev/null || { echo "[jt3] LiteLLM not answering at $MODEL_HOST" >&2; exit 1; }
if [ -n "${LEXOS_REF:-}" ]; then
  ssh "$HOST" "set -e; cd ~/Workspace/alpibrusl/lex-os && git fetch -q origin && git checkout -q '$LEXOS_REF' && (git pull -q --ff-only || true) && git log --oneline -1 && cargo build -q -p lex-os && cargo build -q --release --target x86_64-unknown-linux-musl -p lex-os-guest --features vsock && echo '[jt3] lex-os built'"
fi
ssh "$HOST" 'mkdir -p /tmp/jt3'
scp -q -r "$W"/. "$HOST:/tmp/jt3/"
ssh "$HOST" "sudo env JT_DIR=/tmp/jt3 FRESH_ROOTFS='${FRESH_ROOTFS:-0}' bash /tmp/jt3/jt3-build-company-rootfs.sh"
ssh "$HOST" "sudo env JT_DIR=/tmp/jt3 MODEL_HOST='$MODEL_HOST' MODEL_NAME='$MODEL_NAME' VM_MEM_MIB='${VM_MEM_MIB:-3072}' VM_VCPUS='${VM_VCPUS:-2}' MAX_ITERATIONS='${MAX_ITERATIONS:-2}' bash /tmp/jt3/jt3-company-in-box.sh"
mkdir -p evals/jt3; scp -q -r "$HOST:/tmp/jt3/out/." evals/jt3/ 2>/dev/null || true; scp -q "$HOST:/tmp/jt3/company.audit.json" "$HOST:/tmp/jt3/company.stdout.txt" evals/jt3/ 2>/dev/null || true
echo "[jt3] box artifacts in evals/jt3/"
