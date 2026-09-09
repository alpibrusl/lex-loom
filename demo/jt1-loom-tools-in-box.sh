#!/usr/bin/env bash
# jt1-loom-tools-in-box.sh -- joint loom + lex-os test, step 2 (lex-loom#415),
# run ON a KVM host as root: the tools the consortium's research role actually
# uses, executed INSIDE a real Firecracker microVM under loom's own research
# grant, against the real model endpoint.
#
# Six legs, each one `lex-os exec` over a loom rootfs:
#   MODEL       the grant's model endpoint answers /v1/models from inside the box
#   COMPLETION  a real chat completion comes back from inside the box
#   SEARCH      bin/web_search.py returns results with URLs from inside the box
#   CHECK       bin/check_research_report.py verifies a report + ledger in the box
#   DROP        a host the grant does not list is unreachable from the same box
#   REFUSE      the pre-#417 grant shape (exec: None) is refused before spawn
# A wall that only proves denials proves nothing (lex-os#79): MODEL/COMPLETION/
# SEARCH carry real data from the allowlisted hosts.
#
# Inputs (env): LEX_OS_ROOT (default ~/Workspace/alpibrusl/lex-os), JT_DIR (the
# dir holding research-manifest.json, old-shape-manifest.json and bin/, default
# /tmp/jt1), MODEL_HOST (host:port of LiteLLM, default 192.168.1.165:4000),
# MODEL_NAME (default qwen3.8:27b-mlx), FRESH_ROOTFS=1 to rebuild the loom rootfs.
#
# The guest has no resolver: /etc/hosts in the loom rootfs carries the
# host-resolved addresses of exactly the grant's hosts (the wall pins the same
# resolution). Python comes from python-build-standalone (glibc >= 2.17, so it
# runs on the bionic guest); CA certs are copied from this host.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo): the loop mount and the jailer need it" >&2; exit 2; }
LEX_OS_ROOT="${LEX_OS_ROOT:-/home/${SUDO_USER:-$USER}/Workspace/alpibrusl/lex-os}"
JT_DIR="${JT_DIR:-/tmp/jt1}"
MODEL_HOST="${MODEL_HOST:-192.168.1.165:4000}"
MODEL_NAME="${MODEL_NAME:-qwen3.8:27b-mlx}"
PY_URL="${PY_URL:-https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.12.14+20260901-x86_64-unknown-linux-gnu-install_only.tar.gz}"
ASSETS="$LEX_OS_ROOT/demo/assets"
LEXOS="$LEX_OS_ROOT/target/debug/lex-os"
JAIL_UID="${JAIL_UID:-${SUDO_UID:-$(id -u)}}"
JAIL_GID="${JAIL_GID:-$(getent group kvm | cut -d: -f3)}"
pass=0; fail=0
ok()  { printf '  [PASS] %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; fail=$((fail+1)); }

echo "== 0. preconditions"
[ -x "$LEXOS" ] || { echo "no $LEXOS -- build lex-os first (cargo build -p lex-os)" >&2; exit 2; }
[ -f "$ASSETS/rootfs.ext4" ] && [ -f "$ASSETS/vmlinux" ] || { echo "no assets in $ASSETS -- run demo/setup-assets.sh (as user, then as root)" >&2; exit 2; }
[ -n "$JAIL_GID" ] || { echo "no kvm group" >&2; exit 2; }
for f in research-manifest.json old-shape-manifest.json bin/web_search.py bin/check_research_report.py; do [ -f "$JT_DIR/$f" ] || { echo "missing $JT_DIR/$f (the Mac-side driver ships these)" >&2; exit 2; }; done
ls -la /dev/kvm >/dev/null

echo "== 1. the research grant, with the model endpoint pointed at the real LiteLLM host"
python3 - "$JT_DIR/research-manifest.json" "$MODEL_HOST" "$JT_DIR/research-manifest.effective.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); host = sys.argv[2]
m["egress"] = [host if e.endswith(":4000") else e for e in m["egress"]]
assert m["grant"]["exec"] == "Sandboxed" and any("yahoo" in e for e in m["egress"]), m
json.dump(m, open(sys.argv[3], "w"), indent=2); print(json.dumps(m["egress"]))
PY
MANIFEST="$JT_DIR/research-manifest.effective.json"

echo "== 2. loom rootfs (python + loom's scripts + resolved names + CA certs)"
ROOTFS="$ASSETS/loom-rootfs.ext4"
if [ "${FRESH_ROOTFS:-0}" = "1" ] || [ ! -f "$ROOTFS" ]; then
  cp "$ASSETS/rootfs.ext4" "$ROOTFS"
  [ -f /tmp/jt1-python.tgz ] || curl -fsSL -o /tmp/jt1-python.tgz "$PY_URL"
  mnt="$(mktemp -d)"; mount -o loop "$ROOTFS" "$mnt"
  mkdir -p "$mnt/opt" && tar -xzf /tmp/jt1-python.tgz -C "$mnt/opt"   # -> /opt/python
  mkdir -p "$mnt/opt/loom/bin" "$mnt/opt/loom/fixture" "$mnt/etc/ssl/certs"
  install -m 0755 "$JT_DIR"/bin/*.py "$mnt/opt/loom/bin/"
  cp /etc/ssl/certs/ca-certificates.crt "$mnt/etc/ssl/certs/ca-certificates.crt"
  {
    echo "127.0.0.1 localhost"
    for h in html.duckduckgo.com search.yahoo.com search.brave.com www.bing.com example.org; do
      ip=$(getent ahostsv4 "$h" | awk '{print $1; exit}'); [ -n "$ip" ] && echo "$ip $h"
    done
  } > "$mnt/etc/hosts"
  cat > "$mnt/opt/loom/fixture/report.md" <<'MD'
# Opportunity: CSV schema validation API

## Problem
Solo developers accepting CSV uploads re-implement validation on every project.

## Target user
Solo developers building SaaS back-offices who accept spreadsheet uploads.

## Alternatives
| Alternative | What it does | Price / gap |
|---|---|---|
| Cloudmersive Validate CSV | validates CSV syntax via API | free tier; no schema rules |
| Flatfile | full import UI | from $599/month; too heavy |
| csvlint.io | web validator | free; no API |

## Implementation estimate
40 hours: a FastAPI service with a schema-rules dialect and a test suite.

## Dependencies
- FastAPI

## Sources
- https://cloudmersive.com/convert/validate-csv-api
- https://flatfile.com/pricing

## Confidence
70

## Recommendation
Build it.
MD
  printf 'https://cloudmersive.com/convert/validate-csv-api\nhttps://flatfile.com/pricing\n' > "$mnt/opt/loom/fixture/ledger.txt"
  cat "$mnt/etc/hosts"
  umount "$mnt"; rmdir "$mnt"
  echo "  rootfs prepared: $ROOTFS"
else
  echo "  reusing $ROOTFS (FRESH_ROOTFS=1 to rebuild)"
fi

# run_leg <name> <manifest> <audit> -- cmd...   -> writes $JT_DIR/<name>.json, sets $ENVELOPE
run_leg() {
  local name="$1" manifest="$2"; shift 2; [ "$1" = "--" ] && shift
  ( cd "$LEX_OS_ROOT" && timeout 300 "$LEXOS" --output json exec --manifest "$manifest" --rootfs "$ROOTFS" \
      --jail-uid "$JAIL_UID" --jail-gid "$JAIL_GID" --audit-out "$JT_DIR/$name.audit.json" -- "$@" ) > "$JT_DIR/$name.json" 2>"$JT_DIR/$name.err" || true
  ENVELOPE=$(python3 - "$JT_DIR/$name.json" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
i = raw.rfind('{\n  "ok"')
print(json.dumps(json.loads(raw[i:])) if i >= 0 else json.dumps({"ok": None, "error": "no envelope", "raw_tail": raw[-400:]}))
PY
)
}
field() { python3 -c 'import sys,json; e=json.loads(sys.argv[1]); d=e.get("data") or {}; print(d.get(sys.argv[2], "") if isinstance(d, dict) else "")' "$ENVELOPE" "$1"; }
is_ok() { python3 -c 'import sys,json; sys.exit(0 if json.loads(sys.argv[1]).get("ok") is True else 1)' "$ENVELOPE"; }

echo "== 3. MODEL: the grant's model endpoint answers from inside the box"
run_leg model "$MANIFEST" -- curl -sS --max-time 20 "http://$MODEL_HOST/v1/models"
if is_ok && field stdout | command grep -q '"id"'; then ok "MODEL: $(field stdout | python3 -c 'import sys,json; print([m["id"] for m in json.load(sys.stdin)["data"]][:3])' 2>/dev/null) from inside the microVM"; else bad "MODEL: $ENVELOPE"; fi

echo "== 4. COMPLETION: a real chat completion from inside the box"
run_leg completion "$MANIFEST" -- curl -sS --max-time 240 -H 'Content-Type: application/json' -d "{\"model\":\"$MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word: ready\"}],\"max_tokens\":16}" "http://$MODEL_HOST/v1/chat/completions"
if is_ok && field stdout | command grep -q '"choices"'; then ok "COMPLETION: $(field stdout | python3 -c 'import sys,json; print(repr(json.load(sys.stdin)["choices"][0]["message"]["content"][:60]))' 2>/dev/null)"; else bad "COMPLETION: $ENVELOPE"; fi

echo "== 5. SEARCH: loom's web_search.py runs inside the box and reaches an allowlisted engine"
run_leg search "$MANIFEST" -- /opt/python/bin/python3 /opt/loom/bin/web_search.py "phone number validation API pricing"
if is_ok && field stdout | command grep -q ' -- http' && ! field stdout | command grep -q '^ERROR\|NO_RESULTS'; then ok "SEARCH: $(field stdout | head -1 | cut -c1-110)"; else bad "SEARCH: $(field stdout | head -2 | tr '\n' ' ' | cut -c1-200) $(field stderr | tail -2 | tr '\n' ' ' | cut -c1-200)"; fi

echo "== 6. CHECK: the report gate verifies a report against its ledger inside the box (ReadWrite fs, sandboxed exec)"
run_leg check "$MANIFEST" -- /bin/sh -c 'cd /opt/loom/fixture && LOOM_SEARCH_LEDGER=/opt/loom/fixture/ledger.txt /opt/python/bin/python3 /opt/loom/bin/check_research_report.py .'
if is_ok && field stdout | command grep -q 'RESEARCH_REPORT_OK'; then ok "CHECK: RESEARCH_REPORT_OK with $(field stdout | command grep -o 'checkable:[a-z-]*' | wc -l | tr -d ' ') attrs"; else bad "CHECK: $ENVELOPE"; fi

echo "== 7. DROP: a host the grant does not list is unreachable from the same box"
run_leg drop "$MANIFEST" -- curl -sS --max-time 15 -o /dev/null -w 'HTTP_STATUS=%{http_code}' https://example.org/
if is_ok && field stdout | command grep -q 'HTTP_STATUS=[1-9]'; then bad "DROP: the wall let example.org through: $(field stdout)"; else ok "DROP: example.org unreachable (exit $(field exit_code), $(field stderr | tail -1 | cut -c1-80))"; fi

echo "== 8. REFUSE: the pre-#417 research grant shape (exec: None) never spawns"
run_leg refuse "$JT_DIR/old-shape-manifest.json" -- curl -sS --max-time 10 "http://$MODEL_HOST/v1/models"
if is_ok; then bad "REFUSE: the old grant shape ran the command"; else ok "REFUSE: $(python3 -c 'import sys,json; print(json.dumps(json.loads(sys.argv[1]).get("error",{}))[:140])' "$ENVELOPE")"; fi

echo "== 9. audit logs"
for n in model completion search check drop refuse; do f="$JT_DIR/$n.audit.json"; if [ -s "$f" ]; then printf '  %-10s %s bytes\n' "$n" "$(wc -c < "$f" | tr -d ' ')"; else bad "audit log missing for $n"; fi; done

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
