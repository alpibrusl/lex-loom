#!/usr/bin/env bash
# ev1-eval-suite-roundtrip.sh — the eval suite's own logic, without a model.
#
# bin/eval-suite.sh takes ~40 minutes of GPU time to run for real, so its
# comparison arithmetic, its confound guard and its fixture staging are checked
# here against a stub probe instead. The thing being tested is whether the
# suite can REPORT A REGRESSION — a baseline checker that cannot fail is worse
# than none, since it produces a number people trust.
set -euo pipefail
cd "$(dirname "$0")/.."
W="$(mktemp -d "${TMPDIR:-/tmp}/loom-ev1.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# A stub standing in for bin/probe-node.sh: prints the accept rate the test
# wants, in the format the suite parses.
mkbin() {
  mkdir -p "$W/bin"
  cat > "$W/bin/probe-node.sh" <<STUB
#!/usr/bin/env bash
echo "[probe] accept rate: \${STUB_RATE:-5}/\$1 (100%)"
STUB
  chmod +x "$W/bin/probe-node.sh"
}

setup() {
  rm -rf "$W/repo"; mkdir -p "$W/repo/bin" "$W/repo/evals"
  cp bin/eval-suite.sh "$W/repo/bin/"
  mkbin; cp "$W/bin/probe-node.sh" "$W/repo/bin/"
  printf 'py_test_author\t5\tnote\n' > "$W/repo/evals/suite.tsv"
  (cd "$W/repo" && git init -q 2>/dev/null && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m x 2>/dev/null) || true
}

echo "== 1. with no baseline, it records rather than judges"
setup
out=$( (cd "$W/repo" && STUB_RATE=4 bash bin/eval-suite.sh 2>&1) || true )
case "$out" in
  *"no baseline yet"*) ok "a first run says how to record a baseline" ;;
  *) bad "a missing baseline was not reported: $out" ;;
esac

echo "== 2. --update records what was measured"
out=$( (cd "$W/repo" && STUB_RATE=4 bash bin/eval-suite.sh --update 2>&1) || true )
if grep -q '^py_test_author	4' "$W/repo/evals/baseline.tsv" 2>/dev/null; then
  ok "the baseline holds the measured rate"
else
  bad "the baseline was not written: $(cat "$W/repo/evals/baseline.tsv" 2>/dev/null)"
fi

echo "== 3. a drop beyond tolerance FAILS"
if (cd "$W/repo" && STUB_RATE=2 TOLERANCE=1 bash bin/eval-suite.sh >/dev/null 2>&1); then
  bad "4/5 -> 2/5 was accepted; the suite cannot report a regression at all"
else
  ok "a two-sample drop is reported as a regression"
fi

echo "== 4. ...but noise within tolerance does not"
if (cd "$W/repo" && STUB_RATE=3 TOLERANCE=1 bash bin/eval-suite.sh >/dev/null 2>&1); then
  ok "a one-sample wobble is not called a regression"
else
  bad "a single sample of noise failed the suite, which is how a check gets ignored"
fi

echo "== 5. an improvement is reported, not just tolerated"
out=$( (cd "$W/repo" && STUB_RATE=5 bash bin/eval-suite.sh 2>&1) || true )
case "$out" in
  *improved*) ok "an improvement is named" ;;
  *) bad "an improvement was silent, so a fix that helps looks like a fix that did nothing" ;;
esac

echo "== 6. every result records what it was measured on"
last=$(ls -t "$W/repo/evals/results/"*.tsv 2>/dev/null | head -1)
missing=""
for field in model provider commit; do
  grep -q "^# $field" "$last" 2>/dev/null || missing="$missing $field"
done
if [ -z "$missing" ]; then
  ok "model, provider and commit are recorded alongside the rates"
else
  bad "results omit:$missing — a rate without them is comparable to nothing"
fi

echo "== 7. a rate, not a raw count: changing the sample size must not invert the verdict"
# The defect this suite existed to prevent, in its own instrument. launch was
# raised from 4 samples to 20; 5/20 (25%) against a baseline of 4/4 (100%) was
# reported as "improved from 4 (+1)" and the run exited 0 saying no
# regressions, because the comparison read accepted COUNTS and never the
# denominators.
printf 'launch\t20\tthe role whose n changed\n' > "$W/repo/evals/suite.tsv"
printf '# baseline recorded 2000-01-01T00:00:00Z — model stub, provider stub, commit 0000000\nlaunch\t4\t4\n' > "$W/repo/evals/baseline.tsv"
out=$( (cd "$W/repo" && STUB_RATE=5 TOLERANCE=1 ALLOW_DRIFT=1 bash bin/eval-suite.sh 2>&1) || true )
case "$out" in
  *REGRESSED*) ok "5/20 against 4/4 is a regression, not an improvement" ;;
  *improved*)  bad "raising the sample size inverted the verdict — the exact bug this checks for" ;;
  *)           bad "no verdict at all for a changed sample size: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-90)" ;;
esac

echo "== 8. it refuses to compare across preconditions it did not share"
# Deliberately a comparison that would otherwise SUCCEED (5/5 against 4/5 is an
# improvement, exit 0), so the only thing that can fail this run is the refusal
# itself -- an earlier version of this case inherited the 20-sample suite above
# and passed on the regression exit instead, which is a test that cannot fail
# for the reason it claims.
printf 'launch\t5\tthe role under test\n' > "$W/repo/evals/suite.tsv"
printf '# baseline recorded 2000-01-01T00:00:00Z — model stub, provider stub, commit 0000000\n# env\tOLLAMA_THINK=unset MAX_STEPS_BUILD=unset MAX_STEPS_NODE=unset MAX_STEPS_LAUNCH=unset LLM_TIMEOUT_MS=unset\nlaunch\t4\t5\n' > "$W/repo/evals/baseline.tsv"
if (cd "$W/repo" && STUB_RATE=5 OLLAMA_THINK=false bash bin/eval-suite.sh >/dev/null 2>&1); then
  bad "it compared against a baseline recorded under different knobs and said nothing"
else
  ok "a changed environment refuses the comparison instead of reporting a number"
fi

printf '\n== RESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
