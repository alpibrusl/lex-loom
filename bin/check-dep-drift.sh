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
# Reads the SHA actually installed into the package cache (not the remote HEAD),
# so it reports what this build really used.
#
# Usage:
#   bin/check-dep-drift.sh            # verify against deps.lock
#   bin/check-dep-drift.sh --update   # accept current SHAs into deps.lock
set -euo pipefail
cd "$(dirname "$0")/.."

LOCK="deps.lock"
CACHE="${LEX_PACKAGES_DIR:-$HOME/.lex/packages}"
MODE="${1:-check}"

# Resolve the installed SHA for every git dependency named in lex.toml.
current() {
  awk -F'=' '/^[a-z0-9-]+ *= *\{ *git *=/ { gsub(/ /,"",$1); print $1 }' lex.toml | sort | while read -r dep; do
    d="$CACHE/$dep"
    if [ -d "$d/.git" ]; then
      printf '%s %s\n' "$dep" "$(git -C "$d" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
    else
      printf '%s %s\n' "$dep" "NOT_INSTALLED"
    fi
  done
}

if [ "$MODE" = "--update" ]; then
  current > "$LOCK"
  echo "[dep-drift] wrote $(wc -l < "$LOCK" | tr -d ' ') dependency SHAs to $LOCK"
  exit 0
fi

if [ ! -f "$LOCK" ]; then
  echo "[dep-drift] no $LOCK yet — create it with: bin/check-dep-drift.sh --update" >&2
  exit 1
fi

now="$(mktemp)"; current > "$now"
if diff -q "$LOCK" "$now" >/dev/null 2>&1; then
  echo "[dep-drift] all $(wc -l < "$LOCK" | tr -d ' ') git dependencies match $LOCK"
  rm -f "$now"; exit 0
fi

echo "[dep-drift] a git dependency moved since $LOCK was recorded:" >&2
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
  in .github/workflows/*.yml stops every `lex check` in the repo. Reproduced:
  0.10.11 + lex-schema f7911c94 fails 61 CI steps.

  Review the diff above. If the change is expected, accept it with:" >&2
echo "  bin/check-dep-drift.sh --update && git add deps.lock" >&2
rm -f "$now"
exit 1
