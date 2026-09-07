#!/usr/bin/env bash
# dv1-derived-values-roundtrip.sh -- the two Python gate checkers, checked.
#
# check_derived_values flagged `assert data["timestamp_in"] == "2025-07-11T12:00:00"`
# as a pasted oracle ten times across tzc11's three iterations -- the largest
# single denial source in the run. The literal was the test's own INPUT,
# posted a few lines earlier and echoed back. A value you sent in and expect
# back is a round-trip test, not an unverifiable oracle.
#
# check_imports told the build to "fix the import" of a scratch file it could
# not remove; the message now names the way out.
set -euo pipefail
cd "$(dirname "$0")/.."
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
W="$(mktemp -d "${TMPDIR:-/tmp}/loom-dv1.XXXXXX")"; trap 'rm -rf "$W"' EXIT

echo "== 1. an echoed input is not a pasted oracle"
mkdir -p "$W/echo"; printf 'def test_echo():\n    body = {"timestamp": "2025-07-11T12:00:00"}\n    assert body["timestamp"] == "2025-07-11T12:00:00"\n' > "$W/echo/test_echo.py"
if (cd "$W/echo" && python3 "$OLDPWD/bin/check_derived_values.py" . >/dev/null 2>&1); then ok "a literal that appears as input and expected value is accepted"; else bad "the round-trip assertion tzc11 denied ten times is still flagged"; fi

echo "== 2. ...but a lone hand-written oracle still is"
mkdir -p "$W/oracle"; printf 'def test_oracle():\n    assert convert(1720598400) == "2025-07-11T12:00:00"\n' > "$W/oracle/test_oracle.py"
if (cd "$W/oracle" && python3 "$OLDPWD/bin/check_derived_values.py" . >/dev/null 2>&1); then bad "a literal with no input to pin it was accepted -- the check no longer checks anything"; else ok "a lone oracle is still flagged"; fi

echo "== 3. check_imports names the way out of a scratch file"
mkdir -p "$W/imp"; printf 'import definitely_not_a_module\n' > "$W/imp/probe.py"
out=$(cd "$W/imp" && python3 "$OLDPWD/bin/check_imports.py" . 2>&1 || true)
case "$out" in *"delete:true"*) ok "the denial tells the build it may delete the file" ;; *) bad "the denial only says fix the import, which a scratch file cannot" ;; esac

echo "== 4. a suite that cannot be collected is denied at the author, not discovered by QA"
mkdir -p "$W/coll"; printf 'from datetime import datetime\nEXPECTED = datetime(2025,7,10,12,0).isoformat()\nassert EXPECTED == "2025-07-10T12:00:00+05:00"\ndef test_x():\n    assert EXPECTED\n' > "$W/coll/test_pin.py"
# The collection check is pytest's; on a host without pytest (the CI runner)
# it is skipped by design, and asserting a denial there would be asserting
# that the preflight's finding is this check's. Say so instead of failing.
if python3 -c 'import pytest' >/dev/null 2>&1; then
  if (cd "$W/coll" && python3 "$OLDPWD/bin/check_derived_values.py" . >/dev/null 2>&1); then bad "a wrong module-level pin that kills collection was accepted -- tzc13's 7 tests never ran"; else ok "an uncollectable suite is denied where it was written"; fi
else
  ok "collection check skipped: no pytest on this host (the preflight reports that; this gate does not)"
fi

echo "== 5. a Lex suite is not pytest's to collect"
# The Lex test_author eval baseline read 0/5: every attempt was denied "no
# tests collected" by pytest run over a directory holding only .lex files.
mkdir -p "$W/lexsuite"; printf 'fn test_shift() -> Result[Unit, Str] {\n  match shift(1700000000, "Asia/Kolkata") {\n    Ok(v) => if v == 1700000000 + 330 * 60 { Ok(()) } else { Err("shift") },\n    Err(e) => Err(e),\n  }\n}\n' > "$W/lexsuite/tzoffset_test.lex"
if (cd "$W/lexsuite" && python3 "$OLDPWD/bin/check_derived_values.py" . >/dev/null 2>&1); then ok "a derived Lex suite passes without pytest ever running"; else bad "a Lex-only suite was denied -- the 0/5 Lex test_author baseline"; fi

echo "== 6. a package whose __init__ cannot import is denied at the build, not found by QA"
mkdir -p "$W/pkgbad/tzconvert" "$W/pkgok/tzconvert"
printf 'from .app import app, VALID_FORMATS\n' > "$W/pkgbad/tzconvert/__init__.py"; printf 'app = 1\n' > "$W/pkgbad/tzconvert/app.py"
printf 'from .app import app\n' > "$W/pkgok/tzconvert/__init__.py"; printf 'app = 1\n' > "$W/pkgok/tzconvert/app.py"
if (cd "$W/pkgbad" && python3 "$OLDPWD/bin/check_imports.py" . >/dev/null 2>&1); then bad "a package importing a name its module never defines was accepted -- tzc15 iter 1 sealed exactly this"; else ok "a package that cannot be imported is denied where it was written"; fi
if (cd "$W/pkgok" && python3 "$OLDPWD/bin/check_imports.py" . >/dev/null 2>&1); then ok "a healthy package imports cleanly"; else bad "a healthy package was denied"; fi

printf '\n== RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
