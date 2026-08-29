# test_verify_shell_gate.lex — regression coverage for #21: a `spec sh` gate
# on a non-build role (devops, security, docs, ...) must ground itself in the
# node's OWN output, not a stale/unrelated build work dir.
#
# Found live: an e2e sprint where devops's `spec sh "docker build ..."` gate
# was denied every attempt, because verify_shell(cmd, kind) resolved
# work_dir_for("devops") to the Lex build dir devops never wrote to. The fix
# (runner.verify_shell_on_output) re-materializes the node's fenced output via
# extract_fenced.py into a scratch dir and runs the gate there instead.
#
# Also covers a second bug found while fixing the first: extract_fenced.py
# mapped a ```Dockerfile fence to the generic "file1.txt" (no "." in the tag,
# not in LANG_EXT), so even a correctly-scoped gate would miss a file docker
# build looks for by exact name. Fixed via NO_EXT_FILENAME.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "../src/agent/runner" as runner

fn dockerfile_output() -> Str {
  str.join(["Here is the Dockerfile:\n\n```Dockerfile\n", "FROM python:3.11-slim\n", "WORKDIR /app\n", "COPY . .\n", "RUN pip install flask\n", "CMD [\"python3\", \"app.py\"]\n", "```\n"], "")
}

fn test_shell_gate_passes_on_fenced_dockerfile() -> [io, proc] Result[Unit, Str] {
  match runner.verify_shell_on_output("cat Dockerfile", dockerfile_output(), "t-shellgate-1") {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("expected the gate to see the extracted Dockerfile, got: ", e)),
  }
}

fn test_shell_gate_fails_with_no_fenced_content() -> [io, proc] Result[Unit, Str] {
  match runner.verify_shell_on_output("cat Dockerfile", "Just prose, no fenced code at all.", "t-shellgate-2") {
    Ok(_) => Err("expected an error when the node produced no fenced files"),
    Err(e) => if str.contains(e, "no fenced files") {
      Ok(())
    } else {
      Err(str.concat("expected the 'no fenced files' message, got: ", e))
    },
  }
}

fn test_shell_gate_propagates_command_failure() -> [io, proc] Result[Unit, Str] {
  match runner.verify_shell_on_output("exit 1", dockerfile_output(), "t-shellgate-3") {
    Ok(_) => Err("expected exit 1 to fail the gate"),
    Err(_) => Ok(()),
  }
}

# Found live (first company-reliability run): verify_verdict_suite's Lex branch
# ended its command with `exit $rc`. verify_shell appends
# `; rc=$?; echo "##GATE_EXIT:$rc"` AFTER that string, so the exit terminated
# the shell before the marker was ever printed and verify_shell could only read
# it as failure. Every Lex QA PASS was denied "verdict not grounded", which
# bounced the sprint its full 4 rounds and took a 10-minute company run past 45.
# A gate command must therefore never exit on its own.
fn test_verdict_suite_allows_when_there_is_no_test_file() -> [io, proc] Result[Unit, Str] {
  let sid := "verdict-suite-empty"
  let dir := str.concat("/tmp/loom-lex-work-", sid)
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf ", dir, " && mkdir -p ", dir], "")])
  match runner.verify_verdict_suite("qa", sid) {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("a work dir with no test file has nothing to prove and must ground a PASS, got: ", e)),
  }
}

# The tolerance must not swallow a real failure.
fn test_verdict_suite_denies_when_a_test_fails() -> [io, proc] Result[Unit, Str] {
  let sid := "verdict-suite-failing"
  let dir := str.concat("/tmp/loom-lex-work-", sid)
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf ", dir, " && mkdir -p ", dir, " && printf 'fn run_all() -> Int {\\n  1 / 0\\n}\\n' > ", dir, "/a_test.lex"], "")])
  match runner.verify_verdict_suite("qa", sid) {
    Ok(_) => Err("a test file that fails to run must deny the verdict"),
    Err(_) => Ok(()),
  }
}

# Found live (tzconvert, the first sprint it ever sealed): py_qa reported
# "11/11 tests pass" while the work dir held exactly one file, main.py. It had
# written tests inline into run_code, run them in a scratch buffer, and
# reported them as the project's -- and the sprint sealed success=true with a
# deliverable containing zero tests, against a mission that explicitly required
# them. Source without a test file must not ground a claimed PASS.
fn test_verdict_suite_denies_source_with_no_test_file() -> [io, proc] Result[Unit, Str] {
  let sid := "verdict-suite-no-tests"
  let dir := str.concat("/tmp/loom-lex-work-", sid)
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf ", dir, " && mkdir -p ", dir, " && printf 'fn main() -> Int {\\n  1\\n}\\n' > ", dir, "/main.lex"], "")])
  match runner.verify_verdict_suite("qa", sid) {
    Ok(_) => Err("a build that produced source but no test file must not ground a PASS — that is how a zero-test deliverable sealed"),
    Err(_) => Ok(()),
  }
}

# An EMPTY work dir is different: nothing was built, so there is genuinely
# nothing to test, and other gates cover compilation.
fn test_verdict_suite_allows_an_empty_work_dir() -> [io, proc] Result[Unit, Str] {
  let sid := "verdict-suite-empty-dir"
  let dir := str.concat("/tmp/loom-lex-work-", sid)
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf ", dir, " && mkdir -p ", dir], "")])
  match runner.verify_verdict_suite("qa", sid) {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("an empty work dir has nothing to prove and must not deny, got: ", e)),
  }
}

# Derivation, made checkable rather than requested. The tzconvert run that
# failed 0/2 asserted "1705340400" — a Unix epoch an hour off — against a
# CORRECT implementation. Every gate then worked perfectly and refused to seal,
# and the loop spent three iterations changing working code to satisfy it.
# Asking a model to derive its expected values is a request; a computed value
# leaves a computation in the source, and a pasted one leaves a literal, so the
# difference is mechanically visible.
fn test_pasted_expected_value_is_rejected() -> [io, proc] Result[Unit, Str] {
  let out := "Tests.\n\n```test_convert.py\ndef test_epoch():\n    assert convert(\"x\") == \"1705340400\"\n```\n"
  match runner.verify_shell_on_output("python3 $LOOM_ROOT/bin/check_derived_values.py .", out, "dv-pasted") {
    Ok(_) => Err("a hand-written epoch is an unverifiable oracle and must be rejected"),
    Err(_) => Ok(()),
  }
}

fn test_derived_expected_value_is_allowed() -> [io, proc] Result[Unit, Str] {
  let out := "Tests.\n\n```test_convert.py\nfrom datetime import datetime\nfrom zoneinfo import ZoneInfo\n\ndef test_epoch():\n    expected = int(datetime(2024,1,15,12,0,0, tzinfo=ZoneInfo(\"America/New_York\")).timestamp())\n    assert convert(\"x\") == str(expected)\n```\n"
  match runner.verify_shell_on_output("python3 $LOOM_ROOT/bin/check_derived_values.py .", out, "dv-derived") {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("a test that computes its expected value must pass: ", e)),
  }
}

# The check must not fire on inputs or on ordinary constants. A gate that cried
# wolf on `== 400` would be switched off within a day, and then the real case
# goes unchecked too.
fn test_inputs_and_plain_constants_are_not_flagged() -> [io, proc] Result[Unit, Str] {
  let out := "Tests.\n\n```test_api.py\ndef test_rejects_bad_tz():\n    r = post(\"/convert\", {\"timestamp\": \"2024-01-15T12:00:00\", \"from_tz\": \"Nowhere\"})\n    assert r.status_code == 400\n```\n"
  match runner.verify_shell_on_output("python3 $LOOM_ROOT/bin/check_derived_values.py .", out, "dv-inputs") {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("a timestamp used as INPUT and a status code are not pasted oracles: ", e)),
  }
}

fn suite() -> [io, proc] List[Result[Unit, Str]] {
  [test_shell_gate_passes_on_fenced_dockerfile(), test_shell_gate_fails_with_no_fenced_content(), test_shell_gate_propagates_command_failure(), test_verdict_suite_allows_when_there_is_no_test_file(), test_verdict_suite_denies_when_a_test_fails(), test_verdict_suite_denies_source_with_no_test_file(), test_verdict_suite_allows_an_empty_work_dir(), test_pasted_expected_value_is_rejected(), test_derived_expected_value_is_allowed(), test_inputs_and_plain_constants_are_not_flagged()]
}

fn run_all() -> [io, proc] Unit {
  let results := suite()
  let __dbg := list.map(results, fn (r :: Result[Unit, Str]) -> [io] Unit {
    match r {
      Ok(_) => (),
      Err(e) => io.print(str.concat("FAIL: ", e)),
    }
  })
  let failures := list.fold(results, 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
  if failures == 0 {
    ()
  } else {
    let __force_fail := 1 / 0
    ()
  }
}

