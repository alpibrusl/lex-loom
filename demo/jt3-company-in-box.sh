#!/usr/bin/env bash
# jt3-company-in-box.sh -- lex-loom#415 step 3, ON the KVM host as root: a
# whole loom company (ResearchCo, the consortium's document sprint) runs
# INSIDE one Firecracker box under loom's research grant, with the model on
# the allowlisted LiteLLM host, and delivers its report. The host then
# re-derives the report's verdict from what the box wrote (company.db,
# report.md, the search ledger), the way the consortium buyer does.
#
# Inputs in JT_DIR (/tmp/jt3): research-manifest.json (loom's), goal.txt.
# Env: LEX_OS_ROOT, MODEL_HOST (host:port of LiteLLM), MODEL_NAME,
# VM_MEM_MIB (default 3072), VM_VCPUS (default 2), MAX_ITERATIONS (default 2).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 2; }
LEX_OS_ROOT="${LEX_OS_ROOT:-/home/${SUDO_USER:-$USER}/Workspace/alpibrusl/lex-os}"
JT_DIR="${JT_DIR:-/tmp/jt3}"
MODEL_HOST="${MODEL_HOST:-192.168.1.165:4000}"
MODEL_NAME="${MODEL_NAME:-qwen3.8:27b-mlx}"
ASSETS="$LEX_OS_ROOT/demo/assets"; ROOTFS="$ASSETS/loom-company-rootfs.ext4"; LEXOS="$LEX_OS_ROOT/target/debug/lex-os"
JAIL_UID="${JAIL_UID:-${SUDO_UID:-$(id -u)}}"; JAIL_GID="${JAIL_GID:-$(getent group kvm | cut -d: -f3)}"
CID="researchco-box"
pass=0; fail=0; ok() { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }; bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }
[ -f "$ROOTFS" ] || { echo "no $ROOTFS -- run demo/jt3-build-company-rootfs.sh first" >&2; exit 2; }
for f in research-manifest.json goal.txt; do [ -f "$JT_DIR/$f" ] || { echo "missing $JT_DIR/$f" >&2; exit 2; }; done

echo "== 1. grant: loom's research manifest, model egress -> $MODEL_HOST"
python3 - "$JT_DIR/research-manifest.json" "$MODEL_HOST" "$JT_DIR/research-manifest.effective.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["egress"] = [sys.argv[2] if e.endswith(":4000") else e for e in m["egress"]]
json.dump(m, open(sys.argv[3], "w"), indent=2); print(json.dumps(m["egress"]))
PY
MANIFEST="$JT_DIR/research-manifest.effective.json"

echo "== 2. drop the goal into the image; clear a previous run"
mnt="$(mktemp -d)"; mount -o loop "$ROOTFS" "$mnt"
install -m 0644 "$JT_DIR/goal.txt" "$mnt/opt/loom/jt3-goal.txt"
rm -rf "$mnt/opt/loom/company-box.db" "$mnt/opt/loom-ws" "$mnt/tmp/loom-search-ledger-$CID.txt"; mkdir -p "$mnt/opt/loom-ws/$CID"; cp "$mnt/opt/loom/paths/research-report/README.md" "$mnt/opt/loom-ws/$CID/" 2>/dev/null || true
umount "$mnt"; rmdir "$mnt"

echo "== 3. the company runs inside the box (vm: ${VM_VCPUS:-2} vcpu, ${VM_MEM_MIB:-3072} MiB; up to ${MAX_ITERATIONS:-2} iterations)"
SCRIPT='export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LEX_PACKAGES_DIR=/root/.lex/packages
export LITELLM_BASE_URL=http://'"$MODEL_HOST"' MODEL='"$MODEL_NAME"' COMPANY_ID='"$CID"' DB_PATH=/opt/loom/company-box.db EXEC_MODE=queue WORKER_COUNT=1 POLL_MS=500 RECLAIM_LEASE_SECONDS=300
export ROLE_PACKS=core,research COMPANY_PATH=research-report STOP_WHEN=verdict-passed MAX_ITERATIONS='"${MAX_ITERATIONS:-2}"' MAX_API_CALLS=200 LOOM_WORKSPACE=/opt/loom-ws BUDGET_ENVELOPES=total:100
export GOAL="$(cat /opt/loom/jt3-goal.txt)"
cd /opt/loom && echo "[box] lex $(lex --version 2>&1 | head -1); python $(python3 --version)" && lex run --max-steps 0 --allow-effects env,io,time,crypto,random,sql,fs_read,fs_write,net,concurrent,llm,proc,vcs,approval,stream src/main.lex run_company_cmd 2>&1 | grep -v "^null$" | grep "\[company\]\|\[bootstrap\]\|\[loom\]\|FATAL\|error" | tail -40
echo "== BOX_REPORT =="; cat /opt/loom-ws/'"$CID"'/report.md 2>/dev/null || echo "(no report synced)"
echo "== BOX_ITERATIONS =="; sqlite3 /opt/loom/company-box.db "select idx, sprint_id, status from company_iterations" 2>/dev/null || true'
started=$(date +%s)
( cd "$LEX_OS_ROOT" && LEX_OS_VM_VCPUS="${VM_VCPUS:-2}" LEX_OS_VM_MEM_MIB="${VM_MEM_MIB:-3072}" timeout 3000 "$LEXOS" --output json exec --manifest "$MANIFEST" --rootfs "$ROOTFS" \
    --jail-uid "$JAIL_UID" --jail-gid "$JAIL_GID" --audit-out "$JT_DIR/company.audit.json" -- /bin/sh -c "$SCRIPT" ) > "$JT_DIR/company.json" 2> "$JT_DIR/company.err" || true
echo "  box finished in $(( $(date +%s) - started ))s"
python3 - "$JT_DIR/company.json" "$JT_DIR/company.stdout.txt" <<'PY'
import json, sys
raw = open(sys.argv[1]).read(); i = raw.rfind('{\n  "ok"')
env = json.loads(raw[i:]) if i >= 0 else {"ok": None, "error": "no envelope", "tail": raw[-600:]}
d = env.get("data") or {}
open(sys.argv[2], "w").write(d.get("stdout", "") if isinstance(d, dict) else "")
print("  envelope ok=%s exit=%s" % (env.get("ok"), d.get("exit_code") if isinstance(d, dict) else None))
if env.get("ok") is not True: print("  error:", json.dumps(env.get("error", env))[:400])
if isinstance(d, dict) and d.get("stderr"): print("  stderr tail:", d["stderr"][-300:].replace("\n", " | "))
PY
sed -n '1,60p' "$JT_DIR/company.stdout.txt" | cut -c1-180

echo "== 4. what the box wrote, pulled out of the image"
OUTD="$JT_DIR/out"; rm -rf "$OUTD"; mkdir -p "$OUTD"
mnt="$(mktemp -d)"; mount -o loop "$ROOTFS" "$mnt"
cp "$mnt/opt/loom/company-box.db" "$OUTD/company.db" 2>/dev/null || true
cp "$mnt/opt/loom-ws/$CID/report.md" "$OUTD/report.md" 2>/dev/null || true
cp "$mnt/tmp/loom-search-ledger-$CID.txt" "$OUTD/ledger.txt" 2>/dev/null || true
umount "$mnt"; rmdir "$mnt"; ls -la "$OUTD" | tail -n +2 | awk '{print "  " $5 "  " $9}'

echo "== 5. assertions"
if command grep -q '\[company\] done .*last_verdict=passed' "$JT_DIR/company.stdout.txt"; then ok "the company finished inside the box with verdict passed"; else bad "no passed verdict from the box: $(command grep '\[company\] done\|FATAL' "$JT_DIR/company.stdout.txt" | tail -1 | cut -c1-160)"; fi
if [ -s "$OUTD/report.md" ]; then ok "report.md synced by the company and recovered from the image ($(wc -c < "$OUTD/report.md" | tr -d ' ') bytes)"; else bad "no report.md in the image"; fi
if [ -s "$OUTD/ledger.txt" ]; then ok "search ledger written inside the box ($(wc -l < "$OUTD/ledger.txt" | tr -d ' ') URLs)"; else bad "no search ledger: web_search never ran in the box"; fi
if [ -s "$OUTD/report.md" ] && (cd "$OUTD" && LOOM_SEARCH_LEDGER="$OUTD/ledger.txt" python3 "$JT_DIR/bin/check_research_report.py" . > "$OUTD/host-check.txt" 2>&1); then ok "host-side re-check: $(command grep -o 'RESEARCH_REPORT_OK.*' "$OUTD/host-check.txt" | cut -c1-60)..."; else bad "host-side re-check refused the box's report: $(tail -3 "$OUTD/host-check.txt" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"; fi
if [ -s "$OUTD/company.db" ]; then n=$(sqlite3 "$OUTD/company.db" "select count(*) from traces where event_kind in ('acceptance_passed','qa_skipped_document_sprint')" 2>/dev/null || echo 0); [ "${n:-0}" -ge 2 ] && ok "trail: document QA skip + acceptance re-check recorded inside the box" || bad "trail lacks the document-sprint acceptance events (found $n)"; else bad "no company.db in the image"; fi
[ -s "$JT_DIR/company.audit.json" ] && ok "lex-os audit log written ($(wc -c < "$JT_DIR/company.audit.json" | tr -d ' ') bytes)" || bad "no audit log"
echo; echo "RESULT: $pass passed, $fail failed"; [ "$fail" = 0 ]
