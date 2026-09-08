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

echo "== 7. a pin is executed at the author, not discovered by QA"
# tzc16 iteration 1, verbatim shape: derived name pinned to a literal typed
# from memory, 12h10m wrong. Three QA bounces blamed a correct app.
mkdir -p "$W/pinbad" "$W/pinok"
printf 'from datetime import datetime, timezone\nEXPECTED_EPOCH = int(datetime(2025, 7, 10, 9, 0, tzinfo=timezone.utc).timestamp())\n\ndef test_pin_unix_epoch_literal():\n    assert EXPECTED_EPOCH == 1752181800\n' > "$W/pinbad/test_pin.py"
printf 'from datetime import datetime, timezone\nEXPECTED_EPOCH = int(datetime(2025, 7, 10, 9, 0, tzinfo=timezone.utc).timestamp())\n\ndef test_pin_unix_epoch_literal():\n    assert EXPECTED_EPOCH == 1752138000\n' > "$W/pinok/test_pin.py"
rc=0; out=$(cd "$W/pinbad" && python3 "$OLDPWD/bin/check_derived_values.py" . 2>&1) || rc=$?
case "$rc:$out" in 1:*"1752138000"*) ok "a wrong pin is denied where it was written, with the value the derivation gives" ;; 0:*) bad "a wrong pin (1752181800 for 09:00 UTC) was accepted -- tzc16's three bounces" ;; *) bad "the wrong pin was denied without naming the true value" ;; esac
if (cd "$W/pinok" && python3 "$OLDPWD/bin/check_derived_values.py" . >/dev/null 2>&1); then ok "a correct pin passes"; else bad "a correct pin was denied"; fi

echo "== 8. an author who tolerates the build not existing yet is not denied for it"
# tzc18 iter 1: the metaspec puts the author in parallel with the build, the
# author skipped its module when the app was absent (pytest exit 5, "no tests
# collected"), and the check denied it four times.
mkdir -p "$W/noapp" "$W/noapp2" "$W/badassert"
printf 'import pytest\ntry:\n    from main import app\nexcept ImportError:\n    pytest.skip("app module not importable", allow_module_level=True)\n\ndef test_x():\n    assert app\n' > "$W/noapp/test_convert.py"
printf 'from main import app\n\ndef test_x():\n    assert app\n' > "$W/noapp2/test_convert.py"
printf 'from datetime import datetime\nEXPECTED = datetime(2025,7,10,12,0).isoformat()\nassert EXPECTED == "2025-07-10T12:00:00+05:00"\ndef test_x():\n    assert EXPECTED\n' > "$W/badassert/test_pin.py"
if python3 -c 'import pytest' >/dev/null 2>&1; then
  if (cd "$W/noapp" && python3 "$OLDPWD/bin/check_derived_values.py" . >/dev/null 2>&1); then ok "a module-level skip for an absent app is accepted (pytest exit 5)"; else bad "an author who skipped because the build does not exist yet was denied -- tzc18 iter 1"; fi
  if (cd "$W/noapp2" && python3 "$OLDPWD/bin/check_derived_values.py" . >/dev/null 2>&1); then ok "importing a module the build has not written yet is accepted"; else bad "an import of the not-yet-built module was held against the author"; fi
  if (cd "$W/badassert" && python3 "$OLDPWD/bin/check_derived_values.py" . >/dev/null 2>&1); then bad "a wrong module-level assertion (real collection error) was accepted"; else ok "a wrong module-level assertion is still denied at the author"; fi
else
  ok "collection cases skipped: no pytest on this host"
fi

echo "== 9. a pin may call a helper defined in the file; the helper is executed"
# tzc19 iter 1: `assert expected_iso() == "..."` denied eight times as a paste.
mkdir -p "$W/helperok" "$W/helperbad"
printf 'from datetime import datetime\nfrom zoneinfo import ZoneInfo\n\ndef expected_iso():\n    return datetime(2025, 7, 15, 14, 30, tzinfo=ZoneInfo("UTC")).astimezone(ZoneInfo("Europe/London")).isoformat()\n\ndef test_pin():\n    assert expected_iso() == "2025-07-15T15:30:00+01:00"\n' > "$W/helperok/test_pin.py"
printf 'from datetime import datetime\nfrom zoneinfo import ZoneInfo\n\ndef expected_iso():\n    return datetime(2025, 7, 15, 14, 30, tzinfo=ZoneInfo("UTC")).astimezone(ZoneInfo("Europe/London")).isoformat()\n\ndef test_pin():\n    assert expected_iso() == "2025-07-15T16:30:00+01:00"\n' > "$W/helperbad/test_pin.py"
if (cd "$W/helperok" && python3 "$OLDPWD/bin/check_derived_values.py" . >/dev/null 2>&1); then ok "a correct pin through a local helper is accepted"; else bad "a pin through a local helper was denied as a paste -- tzc19's eight denials"; fi
rc=0; out=$(cd "$W/helperbad" && python3 "$OLDPWD/bin/check_derived_values.py" . 2>&1) || rc=$?
case "$rc:$out" in 1:*"15:30:00+01:00"*) ok "a wrong pin through a local helper is denied, naming the value the helper gives" ;; 0:*) bad "a wrong pin through a local helper was accepted -- the helper was never run" ;; *) bad "the wrong helper pin was denied without naming the true value" ;; esac

echo "== 10. two test files with one basename are named, with the fix"
mkdir -p "$W/dup/tests"
printf 'def test_a():\n    assert 1\n' > "$W/dup/test_convert.py"; printf 'def test_b():\n    assert 1\n' > "$W/dup/tests/test_convert.py"
if python3 -c 'import pytest' >/dev/null 2>&1; then
  rc=0; out=$(cd "$W/dup" && python3 "$OLDPWD/bin/check_derived_values.py" . 2>&1) || rc=$?
  case "$rc:$out" in 1:*"share one"*"test_convert.py: "*) ok "duplicate test basenames are named with the two fixes" ;; 1:*) bad "the duplicate was denied under the generic collection hint -- tzc21 iter 2's repeated denials" ;; *) bad "two test files sharing a basename were accepted (pytest cannot collect them)" ;; esac
else
  ok "duplicate-basename case skipped: no pytest on this host"
fi

printf '\n== RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
