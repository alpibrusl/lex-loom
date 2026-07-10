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

fn suite() -> [io, proc] List[Result[Unit, Str]] {
  [test_shell_gate_passes_on_fenced_dockerfile(), test_shell_gate_fails_with_no_fenced_content(), test_shell_gate_propagates_command_failure()]
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

