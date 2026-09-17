#!/usr/bin/env bash
# Refuse an interpreter that cannot run the file it is handed.
#
# This exists because the same mistake landed three times in one day while
# porting bin/*.py to Lex (lex-loom#512). Renaming `bin/x.py` to `bin/x.lex`
# across call sites changes the ARGUMENT and leaves the interpreter:
#
#     proc.run("python3", ["bin/check_launch_delivery.lex", db, ws])
#     python3 "$OLDPWD/bin/check_imports.lex" .
#
# Every one of those still typechecked, and `lex test` stayed green, because
# nothing in the unit suite runs the gate harness end to end. The demos caught
# them -- cs3 went 29 passed/2 failed to 20/11, dv1 17/0 to 15/2 -- and only
# because their results were compared against a recorded baseline rather than
# eyeballed. A grep is cheaper than that loop and runs on every push.
#
# Text substitution across call sites is not a refactor. This is the check that
# says so.
set -uo pipefail
cd "$(dirname "$0")/.."
bad=0
while IFS= read -r hit; do
  # The `python() { python3 "$@"; }` shim in the gate script is deliberate: it
  # exists so a COMPANY whose product is Python can write `python -m pytest` in
  # a gate. It names no file, so it never matches the patterns below.
  echo "  $hit"
  bad=1
done < <(grep -rnE '(python3?|node|ruby|perl)[[:space:]]+"?[^[:space:]"]*\.(lex|sh)\b' \
           --include='*.sh' --include='*.lex' --include='*.yml' \
           src tests demo bin .github 2>/dev/null | grep -v 'check-interpreters.sh')
if [ "$bad" -eq 1 ]; then
  echo
  echo "An interpreter above is handed a file it cannot run." >&2
  echo "A .lex checker runs through its bin/<name>.sh shim (bash), not python3." >&2
  exit 1
fi

# A second shape of the same mistake: a demo script resolving $HERE to its own
# directory and then calling a tool that lives in bin/. Found live in
# demo/org5 -- "demo/sql-scalar.sh: No such file or directory", printed AFTER
# the last OK line, so the demo still exited 0 and looked green.
while IFS= read -r f; do
  grep -q '\$HERE/\(json-\|sql-\|toml-\)' "$f" 2>/dev/null || continue
  grep -q 'HERE="\$(cd "\$(dirname "\$0")" && pwd)"' "$f" 2>/dev/null || continue
  case "$f" in bin/*) continue ;; esac
  echo "  $f: \$HERE is its own directory, but it calls a tool that lives in bin/" >&2
  bad=1
done < <(find src tests demo bin -name '*.sh' 2>/dev/null)
[ "${bad:-0}" -eq 0 ] || exit 1

echo "interpreters: every tool is invoked by something that can run it, from a path that resolves"
