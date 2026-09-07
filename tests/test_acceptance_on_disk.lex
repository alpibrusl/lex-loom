# test_acceptance_on_disk.lex — acceptance re-executes the work dir, not the
# artifact's prose (#336).
#
# Company tzc13, iterations 2 and 3: QA passed with real evidence, launch
# answered 200, every node was sealed -- and the verdict failed at the last
# step with "gate: node produced no fenced files to check". Acceptance was
# extracting fenced blocks from the sealed artifact's text into a clean dir and
# running pytest there. Since #329/#332 the build writes to disk and no longer
# fences its whole tree, so that text has no fenced files. The gate that made
# the build honest had left the last gate assuming prose.

import "std.str" as str

import "std.list" as list

import "std.proc" as proc

import "std.crypto" as crypto

import "../src/agent/runner" as runner

import "../src/lex_skill" as lexskill

import "../src/orchestrator" as orch

import "../src/graph" as graph

# The REAL command, from the graph -- a copy of the string in this test would
# have hidden the `ls a b` presence check (#291) that the real one still had.
fn py_graph() -> graph.SprintGraph {
  { id: "g", phase: graph.QA, nodes: [{ id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "q", role: "py_qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }], edges: [{ from: "b", to: "q", handoff: "build" }] }
}

fn py_acceptance() -> Str {
  orch.acceptance_command(py_graph())
}

fn test_acceptance_reexecutes_the_build_roles_work_dir() -> Result[Unit, Str] {
  if orch.acceptance_build_role(py_graph()) == "py_build" {
    Ok(())
  } else {
    Err(str.concat("a python sprint's acceptance would re-execute the wrong work dir: ", orch.acceptance_build_role(py_graph())))
  }
}

fn seed(sprint :: Str, app :: Str, test :: Str) -> [proc] Unit {
  let d := lexskill.py_work_dir(sprint)
  let __ := proc.run("bash", ["-c", str.join(["rm -rf '", d, "' && mkdir -p '", d, "' && printf '%b' '", app, "' > '", d, "/app.py' && printf '%b' '", test, "' > '", d, "/test_app.py'"], "")])
  ()
}

fn cleanup(sprint :: Str) -> [proc] Unit {
  let __ := proc.run("bash", ["-c", str.join(["rm -rf '", lexskill.py_work_dir(sprint), "'"], "")])
  ()
}

# The tzc13 shape exactly: files on disk, NO fenced prose, tests that pass.
# The real command runs pytest, so this case is only meaningful where pytest
# exists; the CI runner has none (#335 defers that to the preflight). Skip
# honestly there rather than fail on a missing tool -- the two other cases
# and the sabotages hold without it.
fn host_has_pytest() -> [proc] Bool {
  match proc.run("python3", ["-c", "import pytest"]) {
    Ok(r) => r.exit_code == 0,
    Err(_) => false,
  }
}

fn test_a_passing_build_on_disk_passes_acceptance_with_no_prose() -> [io, proc, random] Result[Unit, Str] {
  if not host_has_pytest() {
    io.print("skip acceptance-on-disk pass case: no pytest on this host (the preflight reports that)\n")
    Ok(())
  } else {
    passing_build_passes_acceptance()
  }
}

fn passing_build_passes_acceptance() -> [io, proc, random] Result[Unit, Str] {
  let sprint := str.concat("t-acc-pass/", crypto.random_str_hex(4))
  let __s := seed(sprint, "def add(a, b):\n    return a + b\n", "from app import add\ndef test_add():\n    assert add(2, 2) == 4\n")
  let r := runner.verify_shell_for_role(py_acceptance(), "py_build", "", str.concat("t-acc-pass-", crypto.random_str_hex(4)), lexskill.py_work_dir(sprint))
  let __c := cleanup(sprint)
  match r {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("a build that passes its own tests on disk failed acceptance — the tzc13 verdict: ", e)),
  }
}

# ...and acceptance still means something: a failing suite fails it.
fn test_a_failing_build_on_disk_fails_acceptance() -> [io, proc, random] Result[Unit, Str] {
  let sprint := str.concat("t-acc-fail/", crypto.random_str_hex(4))
  let __s := seed(sprint, "def add(a, b):\n    return a - b\n", "from app import add\ndef test_add():\n    assert add(2, 2) == 4\n")
  let r := runner.verify_shell_for_role(py_acceptance(), "py_build", "", str.concat("t-acc-fail-", crypto.random_str_hex(4)), lexskill.py_work_dir(sprint))
  let __c := cleanup(sprint)
  match r {
    Ok(_) => Err("a build whose own tests fail passed acceptance — acceptance no longer checks anything"),
    Err(_) => Ok(()),
  }
}

# A build with no tests on disk cannot be accepted, whatever its prose says.
fn test_no_tests_on_disk_fails_acceptance_even_with_fenced_prose() -> [io, proc, random] Result[Unit, Str] {
  let sprint := str.concat("t-acc-none/", crypto.random_str_hex(4))
  let d := lexskill.py_work_dir(sprint)
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf '", d, "' && mkdir -p '", d, "' && printf 'X = 1' > '", d, "/app.py'"], "")])
  let prose := "```test_app.py\ndef test_x():\n    assert True\n```\n"
  let r := runner.verify_shell_for_role(py_acceptance(), "py_build", prose, str.concat("t-acc-none-", crypto.random_str_hex(4)), d)
  let __c := cleanup(sprint)
  match r {
    Ok(_) => Err("a test that exists only in prose satisfied acceptance — the fence hole, at the last gate"),
    Err(_) => Ok(()),
  }
}

fn suite() -> [io, proc, random] List[Result[Unit, Str]] {
  [test_a_passing_build_on_disk_passes_acceptance_with_no_prose(), test_a_failing_build_on_disk_fails_acceptance(), test_no_tests_on_disk_fails_acceptance_even_with_fenced_prose(), test_acceptance_reexecutes_the_build_roles_work_dir()]
}

fn run_all() -> [io, proc, random] Unit {
  let failures := list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
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

