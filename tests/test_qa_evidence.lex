# test_qa_evidence.lex — regression coverage for the `spec json-verdict-pass`
# grounding fix: gates.lex used to trust a QA agent's self-reported "verdict"
# field unconditionally, with no check that run_code was ever actually
# invoked. Found live running a real company (tzconvert): every py_qa-tests
# artifact claimed PASS while never covering a required output format the
# build genuinely didn't implement — the gate had no way to catch that
# because it never looked past the agent's own claim.
#
# The fix: make_run_code_tool writes real {"ran":true,"passed":...} evidence
# to a per-sprint+node file on every invocation; the orchestrator now denies
# a "PASS" verdict unless that evidence exists and agrees.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "../src/agent/runner" as runner

import "../src/gates" as gates

fn test_evidence_path_is_stable_per_sprint_node() -> Result[Unit, Str] {
  let a := runner.qa_evidence_path("tzconvert/iter-4", "py_qa-tests")
  let b := runner.qa_evidence_path("tzconvert/iter-4", "py_qa-tests")
  if a == b {
    Ok(())
  } else {
    Err("expected the same sprint+node to always derive the same evidence path")
  }
}

# Sprint ids routinely contain "/" (company iterations: "tzconvert/iter-4");
# a raw path with an embedded "/" would try to write into a directory that
# doesn't exist. Confirm the path is sanitized to a flat filename.
fn test_evidence_path_sanitizes_slashes() -> Result[Unit, Str] {
  let p := runner.qa_evidence_path("tzconvert/iter-4", "py_qa-tests")
  if str.contains(p, "/tmp/") and not str.contains(str.slice(p, 5, str.len(p)), "/") {
    Ok(())
  } else {
    Err(str.concat("expected a flat filename under /tmp, got: ", p))
  }
}

fn test_no_evidence_file_denies() -> [io, proc] Result[Unit, Str] {
  let path := "/tmp/loom-qa-evidence-test-no-evidence.json"
  let __c := runner.clear_qa_evidence(path)
  match runner.verify_json_verdict_evidence(path, true) {
    Ok(_) => Err("expected a claimed PASS with no run_code evidence at all to be denied"),
    Err(_) => Ok(()),
  }
}

fn test_evidence_agreeing_with_claim_allows() -> [io] Result[Unit, Str] {
  let path := "/tmp/loom-qa-evidence-test-agree.json"
  let __w := io.write(path, "{\"ran\":true,\"passed\":true}")
  match runner.verify_json_verdict_evidence(path, true) {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("expected agreeing evidence to allow, got: ", e)),
  }
}

# The exact scenario found live: the agent claims "verdict":"PASS" but the
# real run_code call actually failed. This must now be denied instead of
# silently trusted.
fn test_evidence_contradicting_claim_denies() -> [io] Result[Unit, Str] {
  let path := "/tmp/loom-qa-evidence-test-contradict.json"
  let __w := io.write(path, "{\"ran\":true,\"passed\":false}")
  match runner.verify_json_verdict_evidence(path, true) {
    Ok(_) => Err("expected a claimed PASS contradicted by real run_code evidence to be denied"),
    Err(_) => Ok(()),
  }
}

fn test_gates_classifies_json_verdict_pass() -> Result[Unit, Str] {
  if gates.is_json_verdict_pass("spec json-verdict-pass") and not gates.is_json_verdict_pass("spec compiles") {
    Ok(())
  } else {
    Err("expected is_json_verdict_pass to recognize only the exact gate string")
  }
}

fn suite() -> [io, proc] List[Result[Unit, Str]] {
  [test_evidence_path_is_stable_per_sprint_node(), test_evidence_path_sanitizes_slashes(), test_no_evidence_file_denies(), test_evidence_agreeing_with_claim_allows(), test_evidence_contradicting_claim_denies(), test_gates_classifies_json_verdict_pass()]
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

