#!/usr/bin/env bash
# check-dep-drift.sh — fail when an unpinned git dependency moved under us.
#
# Every dependency in lex.toml is an unpinned git dep, and `lex pkg` uses a
# flat package layout, so pinning one is a hard error unless every package in
# the closure that needs it pins the SAME rev (measured: pinning lex-llm alone
# fails with "version conflict ... flat layout can only hold one copy", because
# lex-agent-llm, lex-ag-ui and lex-soft all require it unpinned). Pinning is
# therefore an ecosystem-wide decision, not a per-repo one.
#
# This is the cheaper half of that trade: keep automatic pickup, but make a
# move VISIBLE. Upstream commits used to arrive silently and surface days later
# as unrelated red builds somewhere else -- a lex-llm change once reddened nine
# services at once, and a 120s timeout in the same package cost a full day of
# debugging because nothing recorded that the dependency had changed at all.
#
# The default check reads the SHA installed into the package cache, so it
# reports what this build really used. In CI the cache is freshly installed, so
# that IS upstream. Locally it may not be: a stale cache and a stale lock agree,
# and the check goes green in exactly the state it exists to catch (#536). So
# `--update` -- whose whole job is to record the truth -- resolves the UPSTREAM
# SHA with `git ls-remote`, never the cache, and `--remote` checks against it.
#
# Usage:
#   bin/check-dep-drift.sh            # verify deps.lock against the cache
#   bin/check-dep-drift.sh --remote   # verify deps.lock against upstream
#   bin/check-dep-drift.sh --update   # record upstream SHAs into deps.lock
set -euo pipefail
cd "$(dirname "$0")/.."

LOCK="deps.lock"
CACHE="${LEX_PACKAGES_DIR:-$HOME/.lex/packages}"
MODE="${1:-check}"

# Every git dependency named in lex.toml, as "name url".
deps() {
  sed -n 's/^\([a-z0-9-]*\) *= *{ *git *= *"\([^"]*\)".*/\1 \2/p' lex.toml | sort
}

# Resolve the installed SHA for every git dependency.
current() {
  deps | while read -r dep _; do
    d="$CACHE/$dep"
    if [ -d "$d/.git" ]; then
      printf '%s %s\n' "$dep" "$(git -C "$d" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
    else
      printf '%s %s\n' "$dep" "NOT_INSTALLED"
    fi
  done
}

# Resolve the upstream HEAD SHA for every git dependency (one round trip each).
upstream() {
  deps | while read -r dep url; do
    sha="$(git ls-remote "$url" HEAD 2>/dev/null | awk '{print $1; exit}' || true)"
    printf '%s %s\n' "$dep" "${sha:-UNRESOLVED}"
  done
}

if [ "$MODE" = "--update" ]; then
  new="$(mktemp)"; upstream > "$new"
  if grep -q ' UNRESOLVED$' "$new"; then
    echo "[dep-drift] could not resolve upstream for:" >&2
    grep ' UNRESOLVED$' "$new" | sed 's/^/  /' >&2
    echo "[dep-drift] $LOCK left unchanged" >&2
    rm -f "$new"; exit 1
  fi
  mv "$new" "$LOCK"
  echo "[dep-drift] wrote $(wc -l < "$LOCK" | tr -d ' ') upstream dependency SHAs to $LOCK"
  # The lock now names upstream; say where this machine's build is behind it,
  # because a local green run on that cache did not test what was just locked.
  cached="$(mktemp)"; current > "$cached"
  stale="$(join "$LOCK" "$cached" | awk '$2 != $3 {print "  " $1 "  cache " substr($3,1,12) "  upstream " substr($2,1,12)}')"
  rm -f "$cached"
  if [ -n "$stale" ]; then
    echo "[dep-drift] your package cache is behind the lock for:" >&2
    echo "$stale" >&2
    echo "[dep-drift] refresh it (lex pkg install --update) before trusting a local run" >&2
  fi
  exit 0
fi

SOURCE="package cache ($CACHE)"
[ "$MODE" = "--remote" ] && SOURCE="upstream (git ls-remote)"

if [ ! -f "$LOCK" ]; then
  echo "[dep-drift] no $LOCK yet — create it with: bin/check-dep-drift.sh --update" >&2
  exit 1
fi

now="$(mktemp)"
if [ "$MODE" = "--remote" ]; then upstream > "$now"; else current > "$now"; fi
if diff -q "$LOCK" "$now" >/dev/null 2>&1; then
  echo "[dep-drift] all $(wc -l < "$LOCK" | tr -d ' ') git dependencies match $LOCK (compared against the $SOURCE)"
  [ "$MODE" = "--remote" ] || echo "[dep-drift] a stale cache agrees with a stale lock; --remote checks upstream"
  rm -f "$now"; exit 0
fi

echo "[dep-drift] a git dependency in the $SOURCE differs from $LOCK:" >&2
echo >&2
# Report each dep whose SHA differs, old -> new, so the change is named.
while read -r dep sha; do
  was="$(awk -v d="$dep" '$1==d {print $2}' "$LOCK")"
  if [ -z "$was" ]; then
    echo "  + $dep  NEW  $sha" >&2
  elif [ "$was" != "$sha" ]; then
    echo "  ! $dep" >&2
    echo "      was $was" >&2
    echo "      now $sha" >&2
    echo "      diff: https://github.com/alpibrusl/$dep/compare/${was:0:12}...${sha:0:12}" >&2
  fi
done < "$now"
while read -r dep _; do
  grep -q "^$dep " "$now" || echo "  - $dep  REMOVED" >&2
done < "$LOCK"
echo >&2
echo "lex-schema and the lex toolchain move TOGETHER: lex-schema now
  pins itself to a toolchain version and uses builtins from it (str.find_any
  arrived in 0.10.14), so accepting a lex-schema drift without bumping the pin
  in .github/workflows/*.yml stops every \`lex check\` in the repo. Reproduced:
  0.10.11 + lex-schema f7911c94 fails 61 CI steps.

  Review the diff above. If the change is expected, accept it with:" >&2
echo "  bin/check-dep-drift.sh --update && git add deps.lock" >&2
rm -f "$now"
exit 1
