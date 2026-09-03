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

import "../src/lex_skill" as lexskill

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

# A test author writes its file through py_check, not into its answer. Found
# live (tzgor1): py-test-author was denied "no fenced files to check" for doing
# exactly what its tool told it to. The gate must see the tool's dir too.
fn test_shell_gate_sees_tool_written_files() -> [io, proc] Result[Unit, Str] {
  let sid := "shellgate-toolwritten"
  let dir := str.concat("/tmp/loom-py-work-", sid)
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf ", dir, " && mkdir -p ", dir], "")])
  let __w := io.write(str.concat(dir, "/test_convert.py"), "def test_ok():\n    assert 1 == 1\n")
  match runner.verify_shell_on_output_from("test -f test_convert.py", "I wrote the tests with py_check.", "sg-tool-yes", dir) {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("a file written through the node's own tool must reach the gate: ", e)),
  }
}

# The negative control: the same prose-only answer with no seed dir must still
# be refused, or the test above would pass for the wrong reason.
fn test_shell_gate_without_seed_still_refuses_prose() -> [io, proc] Result[Unit, Str] {
  match runner.verify_shell_on_output_from("test -f test_convert.py", "I wrote the tests with py_check.", "sg-tool-no", "") {
    Ok(_) => Err("prose with no files and no tool dir must still be refused"),
    Err(_) => Ok(()),
  }
}

# Overlay order: what the node restated in its answer is what the gate judges.
fn test_fenced_answer_overrides_the_seeded_copy() -> [io, proc] Result[Unit, Str] {
  let sid := "shellgate-overlay"
  let dir := str.concat("/tmp/loom-py-work-", sid)
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf ", dir, " && mkdir -p ", dir], "")])
  let __w := io.write(str.concat(dir, "/test_convert.py"), "STALE\n")
  let out := "Final:\n\n```test_convert.py\nFRESH\n```\n"
  match runner.verify_shell_on_output_from("grep -q FRESH test_convert.py", out, "sg-overlay", dir) {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("the fenced answer must overwrite the seeded copy: ", e)),
  }
}

# A literal pinned to a derivation is checkable, so it is allowed. tzshdr1's
# test author pasted "2025-07-11T08:00:00-04:00", was refused four times, and
# the pasted value was RIGHT — it caught a real four-hour bug. Banning literals
# outright cost us a correct oracle; what the check actually needs is that a
# WRONG paste fails at the oracle rather than blaming the implementation.
fn pinned_test_output() -> Str {
  str.join(["Tests.\n\n```test_convert.py\n", "from datetime import datetime\n", "from zoneinfo import ZoneInfo\n\n", "def test_oracle_is_pinned():\n", "    assert \"2025-07-11T08:00:00-04:00\" == datetime(2025, 7, 11, 12, tzinfo=ZoneInfo(\"UTC\")).astimezone(ZoneInfo(\"America/New_York\")).isoformat()\n\n", "def test_iso():\n", "    assert body[\"result\"] == \"2025-07-11T08:00:00-04:00\"\n", "```\n"], "")
}

fn test_pinned_literal_is_allowed() -> [io, proc] Result[Unit, Str] {
  match runner.verify_shell_on_output("python3 $LOOM_ROOT/bin/check_derived_values.py .", pinned_test_output(), "dv-pinned") {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("a literal pinned to a derivation is checkable and must pass: ", e)),
  }
}

# The pin must be a real pin: the same literal with the derivation removed is
# still a bare paste, or the rule above would accept anything.
fn test_unpinned_literal_is_still_rejected() -> [io, proc] Result[Unit, Str] {
  let out := "Tests.\n\n```test_convert.py\ndef test_iso():\n    assert body[\"result\"] == \"2025-07-11T08:00:00-04:00\"\n```\n"
  match runner.verify_shell_on_output("python3 $LOOM_ROOT/bin/check_derived_values.py .", out, "dv-unpinned") {
    Ok(_) => Err("a bare pasted timestamp is still an unverifiable oracle"),
    Err(_) => Ok(()),
  }
}

# Pinning one value must not launder a DIFFERENT unpinned one.
fn test_pinning_one_value_does_not_excuse_another() -> [io, proc] Result[Unit, Str] {
  let out := str.join([pinned_test_output(), "\n```test_epoch.py\ndef test_epoch():\n    assert body[\"result\"] == 1752249600\n```\n"], "")
  match runner.verify_shell_on_output("python3 $LOOM_ROOT/bin/check_derived_values.py .", out, "dv-partial") {
    Ok(_) => Err("an unpinned epoch in another file must still be caught"),
    Err(_) => Ok(()),
  }
}

# A test author that wrote nothing used to PASS its gate ("no test files found
# — nothing to check", exit 0), seal, and hand off; py-qa then died three
# retries later with "NO TEST FILE", wearing the blame. Watched happen in tzpin.
fn test_no_test_file_is_a_failure() -> [io, proc] Result[Unit, Str] {
  let out := "I would write tests covering the three output formats and both error paths.\n\n```notes.md\nplan\n```\n"
  match runner.verify_shell_on_output("python3 $LOOM_ROOT/bin/check_derived_values.py .", out, "dv-notests") {
    Ok(_) => Err("a test author that produced no test file must not pass its gate"),
    Err(_) => Ok(()),
  }
}

# py_compile PARSES; it never resolves an import. A build naming a package
# nobody installed compiles clean and then fails at launch, several nodes away.
fn test_import_gate_catches_a_missing_package() -> [io, proc] Result[Unit, Str] {
  let out := "Built.\n\n```main.py\nimport nonexistent_pkg_xyz\n\ndef convert(x):\n    return x\n```\n"
  match runner.verify_shell_on_output("python3 $LOOM_ROOT/bin/check_imports.py .", out, "imp-missing") {
    Ok(_) => Err("a module that cannot import must fail the gate"),
    Err(e) => if str.contains(e, "ModuleNotFoundError") {
      Ok(())
    } else {
      Err(str.concat("failed, but without naming the import error: ", e))
    },
  }
}

# The same file passes py_compile, which is exactly the gap.
fn test_compiles_gate_accepts_what_the_import_gate_rejects() -> [io, proc] Result[Unit, Str] {
  let sprint := "t-import-gap"
  let dir := lexskill.py_work_dir(sprint)
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf ", dir, "; mkdir -p ", dir], "")])
  let __w := io.write(str.join([dir, "/main.py"], ""), "import nonexistent_pkg_xyz\n\ndef convert(x):\n    return x\n")
  match runner.verify_build_compiles("py_build", sprint) {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("py_compile should still accept this — the gap is the point: ", e)),
  }
}

fn test_import_gate_passes_a_real_module() -> [io, proc] Result[Unit, Str] {
  let out := "Built.\n\n```main.py\nimport json\n\ndef convert(x):\n    return json.dumps(x)\n```\n"
  match runner.verify_shell_on_output("python3 $LOOM_ROOT/bin/check_imports.py .", out, "imp-good") {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("a module that imports cleanly must pass: ", e)),
  }
}

# The build-path gate runs INSIDE the work dir, so it needs LOOM_ROOT exported
# just as the output path does. It was not, so the same gate string worked on a
# non-build node and silently ran `python3 /bin/...` on a build one.
fn test_build_path_gate_can_reach_repo_tools() -> [io, proc] Result[Unit, Str] {
  let sprint := "t-loomroot-build"
  let dir := lexskill.py_work_dir(sprint)
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf ", dir, "; mkdir -p ", dir], "")])
  let __w := io.write(str.join([dir, "/main.py"], ""), "import json\n")
  match runner.verify_shell("test -f $LOOM_ROOT/bin/check_imports.py", "py_build", sprint) {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("a build-node gate must be able to reach the repo's own tools: ", e)),
  }
}

# `ls a b` is not a presence test. `ls test_*.py *_test.py` exits NON-ZERO when
# either pattern matches nothing, even while printing what the other found, so
# a work dir holding test_convert.py and no *_test.py reported "NO TEST FILE"
# with the test file listed on stdout. That is the ordinary pytest layout, so
# this denied QA in every run it was live for -- 12 denials in tzauthor alone,
# sinking sprints whose suites passed 7/7 when run by hand.
#
# Asserted WITHOUT depending on pytest being installed: CI never installs it,
# and a first version of these tests passed locally and failed there. What is
# under test is the PRESENCE check, so the assertion is that the gate does not
# claim the file is absent -- true whether or not the suite can then run.
fn seed_suite_dir(sid :: Str, test_name :: Str) -> [io, proc] Str {
  let dir := str.concat("/tmp/loom-py-work-", sid)
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf ", dir, " && mkdir -p ", dir], "")])
  let __s := io.write(str.concat(dir, "/app.py"), "def convert(x):\n    return x\n")
  let __t := if str.is_empty(test_name) {
    Ok(())
  } else {
    io.write(str.join([dir, "/", test_name], ""), "from app import convert\n\ndef test_ok():\n    assert convert(1) == 1\n")
  }
  dir
}

fn denies_as_missing(sid :: Str) -> [io, proc] Bool {
  match runner.verify_verdict_suite("py_qa", sid) {
    Ok(_) => false,
    Err(e) => str.contains(e, "NO TEST FILE"),
  }
}

fn test_qa_sees_a_test_file_matching_only_one_pattern() -> [io, proc] Result[Unit, Str] {
  let __d := seed_suite_dir("verdict-suite-one-pattern", "test_convert.py")
  if denies_as_missing("verdict-suite-one-pattern") {
    Err("test_convert.py is right there; the gate must not claim there is no test file")
  } else {
    Ok(())
  }
}

# The mirror convention, so the fix is not simply "never report missing".
fn test_qa_sees_the_underscore_suffix_convention() -> [io, proc] Result[Unit, Str] {
  let __d := seed_suite_dir("verdict-suite-suffix-pattern", "convert_test.py")
  if denies_as_missing("verdict-suite-suffix-pattern") {
    Err("*_test.py alone must also be found")
  } else {
    Ok(())
  }
}

# The negative control that makes the two above mean something: source with no
# test file at all MUST still be reported missing.
fn test_qa_still_reports_a_genuinely_missing_test_file() -> [io, proc] Result[Unit, Str] {
  let __d := seed_suite_dir("verdict-suite-truly-missing", "")
  if denies_as_missing("verdict-suite-truly-missing") {
    Ok(())
  } else {
    Err("source with no test file must still be denied — otherwise the fix is just always passing")
  }
}

# The pin idiom AS ACTUALLY WRITTEN: derive into a name, then pin the literal
# against that name on a later line. Found live -- a probe produced exactly
# this, comment and all, and the gate called it a pasted constant:
#
#     expected_dt  = datetime(2025,7,11,12, tzinfo=ZoneInfo("UTC")).astimezone(...)
#     expected_iso = expected_dt.isoformat()
#     # Pin: verify our derivation
#     assert expected_iso == "2025-07-11T08:00:00-04:00"
#
# Two reasons it was missed: the derivation sat on a different line from the
# literal, and it is TRANSITIVE (expected_iso is computed from expected_dt, not
# directly from datetime). The gate was rejecting correct tests, including one
# whose values were right and had caught a genuine four-hour bug.
fn crossline_pin_output() -> Str {
  str.join(["Tests.\n\n```test_convert.py\n", "from datetime import datetime\n", "from zoneinfo import ZoneInfo\n\n", "def test_iso():\n", "    expected_dt = datetime(2025, 7, 11, 12, tzinfo=ZoneInfo(\"UTC\")).astimezone(ZoneInfo(\"America/New_York\"))\n", "    expected_iso = expected_dt.isoformat()\n", "    assert expected_iso == \"2025-07-11T08:00:00-04:00\"\n", "```\n"], "")
}

fn test_pin_on_a_later_line_is_allowed() -> [io, proc] Result[Unit, Str] {
  match runner.verify_shell_on_output("python3 $LOOM_ROOT/bin/check_derived_values.py .", crossline_pin_output(), "dv-crossline") {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("a literal pinned to a name derived earlier is checkable and must pass: ", e)),
  }
}

# The control that stops this becoming "any comparison to a variable passes":
# the name must actually be bound to a derivation.
fn test_a_literal_compared_to_an_undervied_name_is_still_rejected() -> [io, proc] Result[Unit, Str] {
  let out := "Tests.\n\n```test_convert.py\nlabel = \"run-7\"\n\ndef test_iso():\n    assert label == \"2025-07-11T08:00:00-04:00\"\n```\n"
  match runner.verify_shell_on_output("python3 $LOOM_ROOT/bin/check_derived_values.py .", out, "dv-undervied") {
    Ok(_) => Err("comparing a literal to an unrelated variable derives nothing and must still be rejected"),
    Err(_) => Ok(()),
  }
}

# When a gate denies, the one thing needed to act on it is what the gate was
# actually looking at. It counted the files and threw the names away, so three
# separate diagnoses this week had to be recovered from /tmp/loom-gate-*-work
# directories that happened not to have been cleaned yet: the fence-labelling
# failure (extract_fenced had named them file1.py and file2.py, invisible from
# the denial), the NO TEST FILE denials, and the pin false-positive.
fn test_a_failed_gate_names_the_files_it_saw() -> [io, proc] Result[Unit, Str] {
  let out := "Here it is.\n\n```notes.md\nplan\n```\n"
  match runner.verify_shell_on_output("test -f server.py", out, "saw-listing") {
    Ok(_) => Err("the gate should fail — server.py was never produced"),
    Err(e) => if str.contains(e, "the gate saw these files: notes.md") {
      Ok(())
    } else {
      Err(str.concat("a denial must name what the gate was looking at, got: ", e))
    },
  }
}

# The control: an empty scratch dir must still say so plainly rather than
# claiming to have seen a file.
fn test_an_empty_gate_dir_still_reports_no_files() -> [io, proc] Result[Unit, Str] {
  match runner.verify_shell_on_output("test -f server.py", "prose only, nothing fenced", "saw-empty") {
    Ok(_) => Err("nothing was produced; the gate must fail"),
    Err(e) => if str.contains(e, "no fenced files") {
      Ok(())
    } else {
      Err(str.concat("an empty dir must be reported as such: ", e))
    },
  }
}

# conftest.py looks like test scaffolding and is not: pytest imports it
# unconditionally before collecting anything, so a broken one kills the whole
# suite and every test is reported as failing. Found live (tzfixed iter-2): an
# agent wrote pytest INI config into it —
#
#     [pytest]
#     asyncio_mode = auto
#
# which py_compile ACCEPTS, because `[pytest]` is a valid list literal.
# Importing it raises NameError, pytest dies at collection, and QA blames the
# implementation for tests that never ran. check_imports skipped it by name.
fn test_a_broken_conftest_is_caught() -> [io, proc] Result[Unit, Str] {
  let out := "Built.\n\n```main.py\ndef convert(x):\n    return x\n```\n\n```conftest.py\n[pytest]\nasyncio_mode = auto\n```\n"
  match runner.verify_shell_on_output("python3 $LOOM_ROOT/bin/check_imports.py .", out, "cft-bad") {
    Ok(_) => Err("a conftest.py that cannot be imported kills every test in the directory and must be caught"),
    Err(e) => if str.contains(e, "conftest") {
      Ok(())
    } else {
      Err(str.concat("caught, but without naming conftest: ", e))
    },
  }
}

# Imports only the stdlib on purpose. The first version of this fixture used
# `import pytest`, which made the test depend on pytest being installed on the
# runner — CI does not install it, and the assertion "an importable conftest
# must pass" then failed for a reason that had nothing to do with the check.
# Fourth local-vs-CI divergence of this shape in this repo.
fn test_a_real_conftest_is_accepted() -> [io, proc] Result[Unit, Str] {
  let out := "Built.\n\n```main.py\ndef convert(x):\n    return x\n```\n\n```conftest.py\nimport os\n\nMARKER = os.sep\n```\n"
  match runner.verify_shell_on_output("python3 $LOOM_ROOT/bin/check_imports.py .", out, "cft-good") {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("an importable conftest must pass: ", e)),
  }
}

# The control that keeps the exclusion honest: a test author writes its tests
# BEFORE the implementation exists, deliberately, so a test file importing
# something absent must NOT be treated as a broken module.
fn test_a_test_file_importing_a_missing_impl_is_still_allowed() -> [io, proc] Result[Unit, Str] {
  let out := "Tests.\n\n```test_a.py\nfrom nonexistent_impl import convert\n\ndef test_x():\n    assert convert(1) == 1\n```\n"
  match runner.verify_shell_on_output("python3 $LOOM_ROOT/bin/check_imports.py .", out, "cft-testonly") {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("a test written before its implementation is the point of an independent test author: ", e)),
  }
}

fn suite() -> [io, proc] List[Result[Unit, Str]] {
  [test_shell_gate_passes_on_fenced_dockerfile(), test_shell_gate_fails_with_no_fenced_content(), test_shell_gate_propagates_command_failure(), test_verdict_suite_allows_when_there_is_no_test_file(), test_verdict_suite_denies_when_a_test_fails(), test_verdict_suite_denies_source_with_no_test_file(), test_verdict_suite_allows_an_empty_work_dir(), test_pasted_expected_value_is_rejected(), test_derived_expected_value_is_allowed(), test_inputs_and_plain_constants_are_not_flagged(), test_shell_gate_sees_tool_written_files(), test_shell_gate_without_seed_still_refuses_prose(), test_fenced_answer_overrides_the_seeded_copy(), test_pinned_literal_is_allowed(), test_unpinned_literal_is_still_rejected(), test_pinning_one_value_does_not_excuse_another(), test_no_test_file_is_a_failure(), test_import_gate_catches_a_missing_package(), test_compiles_gate_accepts_what_the_import_gate_rejects(), test_import_gate_passes_a_real_module(), test_build_path_gate_can_reach_repo_tools(), test_qa_sees_a_test_file_matching_only_one_pattern(), test_qa_sees_the_underscore_suffix_convention(), test_qa_still_reports_a_genuinely_missing_test_file(), test_pin_on_a_later_line_is_allowed(), test_a_literal_compared_to_an_undervied_name_is_still_rejected(), test_a_failed_gate_names_the_files_it_saw(), test_an_empty_gate_dir_still_reports_no_files(), test_a_broken_conftest_is_caught(), test_a_real_conftest_is_accepted(), test_a_test_file_importing_a_missing_impl_is_still_allowed()]
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

