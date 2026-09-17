#!/usr/bin/env bash
# Start the product, run bin/check_abuse_controls.lex against it, reap it.
#
# The process lifecycle lives here because process GROUPS are what a shell is
# for: the product may fork, and the gate must kill the whole group whatever
# the outcome, including when the checker itself dies. setsid/`set -m` gives
# the group; the trap guarantees the reap.
#
# The preflight refusals are here too, because they must happen before anything
# is started: ports 8000 and 8080 are permanently held on the dev host, and a
# port someone else holds must never be killed by a gate that did not start it.
set -uo pipefail
ROOT="${1:-.}"
HERE="$(cd "$(dirname "$0")" && pwd)"
drop_rc() { sed -e '$ { /^[0-9][0-9]*$/d; }'; }
jsonarg() { printf '"%s"' "$(printf '%s' "${1-}" | sed 's/^"*//; s/"*$//')"; }
refuse() { echo "ABUSE_CONTROLS_VERIFIED"; echo "check_abuse_controls: $1"; exit 1; }

# The FULL effect row, not the one `preflight` alone needs: a Lex program's
# effect row is the union of everything it imports, so running any function in
# this file requires proc even though this one only reads a file
# (reference_lex_effects_per_program).
#
# `start` and `port` come from the Lex program's own preflight, not from a JSON
# parser written again here: a second parser is a second set of defaults, and
# they drift.
pre=$(lex run --allow-effects fs_read,fs_write,fs_walk,io,proc "$HERE/check_abuse_controls.lex" preflight "$(jsonarg "$ROOT")" 2>&1)
if printf '%s' "$pre" | grep -q '^REFUSE'; then
  echo "ABUSE_CONTROLS_VERIFIED"
  echo "check_abuse_controls: $(printf '%s' "$pre" | sed -n 's/^REFUSE.//p')"
  exit 1
fi
START=$(printf '%s' "$pre" | sed -n 's/^START.//p')
PORT=$(printf '%s' "$pre" | sed -n 's/^PORT.//p')
[ -n "$START" ] || refuse "abuse-probe.json is not usable; need at least start and endpoint"
PORT="${PORT:-8093}"
case "$PORT" in
  8000|8080) refuse "ports 8000 and 8080 are permanently held on this host; pick another in abuse-probe.json" ;;
esac
HOLDER="$(lsof -ti "tcp:$PORT" 2>/dev/null | head -1 || true)"
[ -z "$HOLDER" ] || refuse "port $PORT is already held by pid $HOLDER; the gate will not kill something it did not start"

# perl's setpgrp, not setsid and not `set -m`. macOS ships no setsid, and
# `set -m` cannot be enabled inside a command substitution -- which is how the
# first version of this silently never launched the product at all, and the
# gate then reported "your product did not answer /healthz" for a product it
# had never started. perl is already the idiom here (bin/check_imports.lex uses
# its alarm for the same portability reason).
#
# The group matters: a form backend that forks a worker would otherwise keep
# the port and fail the NEXT run's "port is already held" preflight.
PGID=
cleanup() {
  [ -n "$PGID" ] || return 0
  kill -TERM "-$PGID" 2>/dev/null || kill -TERM "$PGID" 2>/dev/null
  sleep 1
  kill -KILL "-$PGID" 2>/dev/null || kill -KILL "$PGID" 2>/dev/null
  return 0
}
trap cleanup EXIT INT TERM

( cd "$ROOT" && PORT="$PORT" exec perl -e 'setpgrp(0,0); exec @ARGV' sh -c "$START" ) >/dev/null 2>&1 &
PGID=$!

out=$(lex run --allow-effects fs_read,fs_write,fs_walk,io,proc "$HERE/check_abuse_controls.lex" main "$(jsonarg "$ROOT")" 2>&1)
printf '%s\n' "$out" | drop_rc
grep -q '^ABUSE_CONTROLS_OK' <<<"$out"
