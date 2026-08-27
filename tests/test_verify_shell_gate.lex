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

fn suite() -> [io, proc] List[Result[Unit, Str]] {
  [test_shell_gate_passes_on_fenced_dockerfile(), test_shell_gate_fails_with_no_fenced_content(), test_shell_gate_propagates_command_failure(), test_verdict_suite_allows_when_there_is_no_test_file(), test_verdict_suite_denies_when_a_test_fails()]
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

