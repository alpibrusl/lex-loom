#!/usr/bin/env bash
# eval-suite.sh — node-level accept rates against a stored baseline.
#
# Every quality claim in this project was made from whole-company runs, and
# nearly all were wrong: tzc6 → tzc7 → tzc8 read 18/2 → 13/4 → 10/4 while real
# defects were being fixed, each comparison carrying its own confound. A single
# run of a stochastic pipeline cannot separate a regression from variance.
#
# This measures one node at a time, N times, and compares against a recorded
# baseline — so "did that fix help?" is answered by a number rather than by
# memory of the last number.
#
#   bin/eval-suite.sh            measure and compare
#   bin/eval-suite.sh --update   accept current numbers as the baseline
#
# Env: MODEL, LOOM_PROVIDER / LITELLM_BASE_URL as usual; TOLERANCE (default 1)
# is how many samples a role may drop below baseline before it counts.
set -euo pipefail
cd "$(dirname "$0")/.."

UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

MODEL="${MODEL:-qwen3.8:27b-mlx}"
TOLERANCE="${TOLERANCE:-1}"
SUITE=evals/suite.tsv
BASELINE=evals/baseline.tsv
mkdir -p evals/results

# A measurement taken while something else is using the GPU is not a
# measurement. This is not hypothetical: a provider comparison in this repo
# reported 1/4 versus 4/4 because curl experiments and container restarts were
# running alongside the probe. Re-run clean, it was 5/5 versus 5/5.
busy=$(ps -Ao command | grep -c '[l]ex run --max-steps 0' || true)
if [ "$busy" -gt 0 ]; then
  echo "a company run is in progress — its GPU load would confound every sample here." >&2
  echo "wait for it to finish, or stop it, then re-run." >&2
  exit 1
fi

PROVIDER="${LOOM_PROVIDER:-${LITELLM_BASE_URL:+litellm}}"
PROVIDER="${PROVIDER:-default}"
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="evals/results/$STAMP.tsv"

{ echo "# model	$MODEL"
  echo "# provider	$PROVIDER"
  echo "# commit	$COMMIT"
  echo "# date	$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT"

# launch has nothing to launch unless a build is staged. Without this the role
# measures the fixture's absence rather than the role: an earlier launch probe
# scored 2/4 in an empty work dir, and the two "accepts" were a stale server
# from a previous attempt answering on the port.
stage_fixture() {
  case "$1" in
    py_qa|qa)
      # QA verifies the build's files on disk (#323) against the probe's
      # TASK, so the fixture has to actually satisfy that task. The first
      # version was a bare convert() with one test, and QA correctly refused
      # it: "no POST /convert endpoint, no rfc2822 or unix_epoch, no HTTP 400"
      # — every word true. A fixture that fails the spec measures the
      # fixture. Stdlib only, so it needs nothing installed.
      for i in $(seq 1 "$2"); do
        d="/tmp/loom-py-work-probe-$1-$i"
        mkdir -p "$d"
        cat > "$d/app.py" <<'PY'
"""POST /convert: convert a timestamp between IANA timezones and render it as
iso8601, rfc2822 or unix_epoch. Unknown timezone or format -> HTTP 400."""
import json
import os
from datetime import datetime
from email.utils import format_datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

FORMATS = ("iso8601", "rfc2822", "unix_epoch")


def convert(timestamp: str, from_tz: str, to_tz: str, output_format: str) -> str:
    if output_format not in FORMATS:
        raise ValueError(f"unknown output_format: {output_format}")
    try:
        src = ZoneInfo(from_tz)
        dst = ZoneInfo(to_tz)
    except (ZoneInfoNotFoundError, ValueError, KeyError):
        raise ValueError("unknown timezone")
    dt = datetime.fromisoformat(timestamp).replace(tzinfo=src).astimezone(dst)
    if output_format == "iso8601":
        return dt.isoformat()
    if output_format == "rfc2822":
        return format_datetime(dt)
    return str(int(dt.timestamp()))


def handle(body: dict) -> tuple[int, dict]:
    """The endpoint's logic, callable without a socket."""
    try:
        result = convert(
            body["timestamp"], body["from_tz"], body["to_tz"],
            body.get("output_format", "iso8601"),
        )
    except (KeyError, ValueError) as e:
        return 400, {"error": str(e) or "bad request"}
    return 200, {
        "result": result,
        "from_tz": body["from_tz"],
        "to_tz": body["to_tz"],
        "output_format": body.get("output_format", "iso8601"),
    }


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/convert":
            return self._send(404, {"error": "not found"})
        try:
            n = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, json.JSONDecodeError):
            return self._send(400, {"error": "invalid json"})
        status, payload = handle(body)
        self._send(status, payload)

    def _send(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


def serve(port: int) -> HTTPServer:
    return HTTPServer(("", port), Handler)


if __name__ == "__main__":
    serve(int(os.environ.get("PORT", "8081"))).serve_forever()
PY
        cat > "$d/test_app.py" <<'PY'
import json
import threading
import urllib.error
import urllib.request
from datetime import datetime
from email.utils import format_datetime
from zoneinfo import ZoneInfo

import pytest

from app import handle, serve

# One instant, expressed in UTC, converted to New York. Expected values are
# DERIVED from the same instant, never pasted.
INSTANT = datetime(2025, 7, 11, 8, 0, 0, tzinfo=ZoneInfo("UTC"))
BODY = {"timestamp": "2025-07-11T08:00:00", "from_tz": "UTC", "to_tz": "America/New_York"}
NY = INSTANT.astimezone(ZoneInfo("America/New_York"))


def test_iso8601():
    status, out = handle(dict(BODY, output_format="iso8601"))
    assert status == 200
    assert out["result"] == NY.isoformat()


def test_rfc2822():
    status, out = handle(dict(BODY, output_format="rfc2822"))
    assert status == 200
    assert out["result"] == format_datetime(NY)


def test_unix_epoch():
    status, out = handle(dict(BODY, output_format="unix_epoch"))
    assert status == 200
    assert out["result"] == str(int(INSTANT.timestamp()))


def test_unknown_timezone_is_400():
    status, out = handle(dict(BODY, to_tz="Mars/Olympus_Mons"))
    assert status == 400
    assert "error" in out


def test_unknown_format_is_400():
    status, out = handle(dict(BODY, output_format="roman_numerals"))
    assert status == 400
    assert "error" in out


@pytest.fixture(scope="module")
def server():
    srv = serve(0)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    yield srv.server_address[1]
    srv.shutdown()


def _post(port, body):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/convert",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def test_http_post_convert(server):
    status, out = _post(server, dict(BODY, output_format="iso8601"))
    assert status == 200
    assert out["result"] == NY.isoformat()


def test_http_bad_timezone_is_400(server):
    status, _ = _post(server, dict(BODY, from_tz="Nowhere/Land"))
    assert status == 400
PY
      done ;;
    launch|deploy)
      for i in $(seq 1 "$2"); do
        d="/tmp/loom-py-work-probe-$1-$i"
        mkdir -p "$d"
        cat > "$d/tzconvert.py" <<'PY'
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true,"service":"tzconvert"}')
    def log_message(self, *a): pass

HTTPServer(("", int(os.environ.get("PORT", "8081"))), H).serve_forever()
PY
      done ;;
  esac
}

clean_fixture() {
  case "$1" in
    py_qa|qa)
      rm -rf /tmp/loom-py-work-probe-"$1"-* ;;
    launch|deploy)
      rm -rf /tmp/loom-py-work-probe-"$1"-* 
      pkill -9 -f 'tzconvert.py' 2>/dev/null || true
      rm -f /tmp/loom-servers.pids ;;
  esac
}

# launch runs on the convention ports. A leftover listener there is not
# loom's to kill (#316) and turns every attempt into a refusal — the first
# baseline read 2/4 because a server leaked from the previous day's testing
# still held 8081. Refuse to measure rather than measure the leak.
# Only the port the staged fixture binds (8081, the Python convention), and
# only when launch is in this run: 8080 is permanently held by a Docker
# port-forward on the machine this was written on, and checking it blocked
# the entire suite over a port nothing here uses.
if [ -z "${ROLES:-}" ] || printf ',%s,' "$ROLES" | grep -qE ',(launch|deploy),'; then
  holder=$(lsof -ti "tcp:8081" 2>/dev/null | head -1 || true)
  if [ -n "$holder" ]; then
    echo "port 8081 is held by pid $holder ($(ps -o comm= -p "$holder" 2>/dev/null | tr -d ' '))." >&2
    echo "launch would be refused on every attempt (loom does not kill what it did not start, #316)." >&2
    echo "Free the port — or confirm it is yours and kill it — then re-run." >&2
    exit 1
  fi
fi

echo "== eval suite: model=$MODEL provider=$PROVIDER commit=$COMMIT"
while IFS=$'\t' read -r role samples _; do
  case "$role" in ''|\#*) continue ;; esac
  # ROLES=py_qa,launch re-measures a subset; the baseline keeps the rest.
  if [ -n "${ROLES:-}" ] && ! printf ',%s,' "$ROLES" | grep -q ",$role,"; then continue; fi
  stage_fixture "$role" "$samples"
  line=$(N="$samples" ROLE="$role" bash bin/probe-node.sh "$samples" "$role" "$MODEL" 2>&1 | grep 'accept rate' || true)
  clean_fixture "$role"
  got=$(printf '%s' "$line" | sed -n 's/.*accept rate: \([0-9]*\)\/\([0-9]*\).*/\1/p')
  got="${got:-0}"
  printf '%s\t%s\t%s\n' "$role" "$got" "$samples" >> "$OUT"
  printf '  %-16s %s/%s\n' "$role" "$got" "$samples"
done < "$SUITE"

if [ "$UPDATE" = "1" ]; then
  if [ -n "${ROLES:-}" ] && [ -f "$BASELINE" ]; then
    # keep every baseline row for a role this run did not measure
    { grep -v '^#' "$BASELINE" | while IFS=$'\t' read -r r g n; do
        printf ',%s,' "$ROLES" | grep -q ",$r," || printf '%s\t%s\t%s\n' "$r" "$g" "$n"
      done
      grep -v '^#' "$OUT"
    } > "$BASELINE.merged" && mv "$BASELINE.merged" "$BASELINE"
  else
    grep -v '^#' "$OUT" > "$BASELINE"
  fi
  { echo "# baseline recorded $(date -u +%Y-%m-%dT%H:%M:%SZ) — model $MODEL, provider $PROVIDER, commit $COMMIT"
    cat "$BASELINE"
  } > "$BASELINE.tmp" && mv "$BASELINE.tmp" "$BASELINE"
  echo "== baseline updated: $BASELINE"
  exit 0
fi

if [ ! -f "$BASELINE" ]; then
  echo "== no baseline yet. Record one with: bin/eval-suite.sh --update"
  exit 0
fi

echo "== against $BASELINE (tolerance: $TOLERANCE sample)"
regressed=0
while IFS=$'\t' read -r role got samples; do
  case "$role" in ''|\#*) continue ;; esac
  base=$(awk -F'\t' -v r="$role" '$1==r{print $2}' "$BASELINE" | head -1)
  if [ -z "$base" ]; then
    printf '  %-16s %s/%s  (no baseline for this role)\n' "$role" "$got" "$samples"
    continue
  fi
  delta=$((got - base))
  if [ "$delta" -lt "-$TOLERANCE" ]; then
    printf '  %-16s %s/%s  REGRESSED from %s (%s)\n' "$role" "$got" "$samples" "$base" "$delta"
    regressed=$((regressed + 1))
  elif [ "$delta" -gt 0 ]; then
    printf '  %-16s %s/%s  improved from %s (+%s)\n' "$role" "$got" "$samples" "$base" "$delta"
  else
    printf '  %-16s %s/%s  (baseline %s)\n' "$role" "$got" "$samples" "$base"
  fi
done < <(grep -v '^#' "$OUT")

echo "== results: $OUT"
if [ "$regressed" -gt 0 ]; then
  echo "== $regressed role(s) regressed by more than $TOLERANCE sample" >&2
  exit 1
fi
echo "== no regressions"
