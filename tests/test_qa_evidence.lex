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

import "std.process" as proc

import "lex-schema/json_value" as jv

import "lex-llm/src/tool" as t

import "../src/agent/runner" as runner

import "../src/gates" as gates

import "../src/roles" as roles

import "../src/lex_skill" as lexskill

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

# Found live (pdfx2 company run + a standalone smoke test, both real): qa's
# verdict was denied with "no run_code evidence found" on EVERY attempt,
# regardless of what the model did -- because lex_check/lex_run (qa's only
# tools) never wrote any evidence file at all, unlike py_qa's run_code. Every
# Lex `qa` node in every company this project has ever run was structurally
# guaranteed to fail this gate. These tests exercise the REAL lex_check/
# lex_run tool bodies (not a mock) end-to-end against the evidence file.
fn test_lex_check_records_passing_evidence() -> [net, io, proc] Result[Unit, Str] {
  let path := "/tmp/loom-qa-evidence-test-lex-check-pass.json"
  let __c := runner.clear_qa_evidence(path)
  let tool := lexskill.make_lex_check_tool(path, "test-qa-evidence")
  let args := JObj([("filename", JStr("evidence_test_pass.lex")), ("code", JStr("fn main() -> Unit { () }"))])
  match tool.execute(args) {
    Err(_) => Err("lex_check tool call itself failed"),
    Ok(_) => match runner.verify_json_verdict_evidence(path, true) {
      Ok(_) => Ok(()),
      Err(e) => Err(str.concat("expected a claimed PASS to be allowed after a real passing lex_check, got: ", e)),
    },
  }
}

fn test_lex_check_records_failing_evidence() -> [net, io, proc] Result[Unit, Str] {
  let path := "/tmp/loom-qa-evidence-test-lex-check-fail.json"
  let __c := runner.clear_qa_evidence(path)
  let tool := lexskill.make_lex_check_tool(path, "test-qa-evidence")
  let args := JObj([("filename", JStr("evidence_test_fail.lex")), ("code", JStr("this is not valid lex at all }{"))])
  match tool.execute(args) {
    Err(_) => Err("lex_check tool call itself failed"),
    Ok(_) => match runner.verify_json_verdict_evidence(path, true) {
      Ok(_) => Err("expected a claimed PASS to be denied after a real failing lex_check"),
      Err(_) => Ok(()),
    },
  }
}

# The exact scenario the gate exists for: qa calls lex_check (passes), then
# lex_run on a test file (fails) -- the merged evidence must reflect the
# TRUE combined outcome, not just whichever tool ran last.
fn test_lex_check_then_failing_lex_run_merges_to_overall_fail() -> [net, io, proc] Result[Unit, Str] {
  let path := "/tmp/loom-qa-evidence-test-merge-fail.json"
  let __c := runner.clear_qa_evidence(path)
  let check_tool := lexskill.make_lex_check_tool(path, "test-qa-evidence")
  let check_args := JObj([("filename", JStr("evidence_test_merge.lex")), ("code", JStr("fn run_all() -> Int { 1 / 0 }"))])
  match check_tool.execute(check_args) {
    Err(_) => Err("lex_check tool call itself failed"),
    Ok(_) => {
      let run_tool := lexskill.make_lex_run_tool(path, "test-qa-evidence")
      let run_args := JObj([("filename", JStr("evidence_test_merge.lex")), ("fn_name", JStr("run_all")), ("args", JStr(""))])
      match run_tool.execute(run_args) {
        Err(_) => Err("lex_run tool call itself failed"),
        Ok(_) => match runner.verify_json_verdict_evidence(path, true) {
          Ok(_) => Err("run_all returning 1 (nonzero exit-equivalent) means real failures were reported; a claimed PASS should be denied"),
          Err(_) => Ok(()),
        },
      }
    },
  }
}

# Found live (second smoke-test run, AFTER #110 merged): the qa role STILL
# denied every verdict, because `fn qa(model)` -- the actual agent
# constructor `for_role` calls -- hardcoded tools_of_role("qa", "") instead
# of threading through the real evidence_path it was given. #110 fixed
# lex_check/lex_run and tool_by_name in isolation, and unit-tested them in
# isolation, but never exercised the real construction path an orchestrator
# node actually uses -- so the fix never engaged in a live run. This test
# goes through roles.for_role (the same call the orchestrator makes) end to
# end, so a regression here can't hide behind a lower-level test passing.
fn test_for_role_qa_threads_evidence_path_to_its_tools() -> [env, net, io, proc] Result[Unit, Str] {
  let path := "/tmp/loom-qa-evidence-test-for-role-wiring.json"
  let __c := runner.clear_qa_evidence(path)
  match roles.for_role("qa", "test-model", path, "test-qa-evidence") {
    None => Err("expected for_role(\"qa\", ...) to resolve to an agent"),
    Some(agent) => {
      let lex_check_tools := list.filter(agent.tools, fn (tl :: t.Tool) -> Bool {
        tl.name == "lex_check"
      })
      match list.head(lex_check_tools) {
        None => Err("expected the qa agent to have a lex_check tool"),
        Some(tool) => {
          let args := JObj([("filename", JStr("evidence_test_for_role.lex")), ("code", JStr("fn main() -> Unit { () }"))])
          match tool.execute(args) {
            Err(_) => Err("lex_check tool call itself failed"),
            Ok(_) => match runner.verify_json_verdict_evidence(path, true) {
              Ok(_) => Ok(()),
              Err(e) => Err(str.concat("expected the qa agent's real lex_check tool (constructed via roles.for_role, the same path the orchestrator uses) to ground a claimed PASS, got: ", e)),
            },
          }
        },
      }
    },
  }
}

fn test_gates_classifies_json_verdict_pass() -> Result[Unit, Str] {
  if gates.is_json_verdict_pass("spec json-verdict-pass") and not gates.is_json_verdict_pass("spec compiles") {
    Ok(())
  } else {
    Err("expected is_json_verdict_pass to recognize only the exact gate string")
  }
}

# Found live (local-model smoke sprint, 2026-08-27): every QA node was denied
# with "verdict not grounded" while its own verdict JSON was well-formed and
# lex_check/lex_run had both really run. The evidence file read
# {"lex_check_ok":false,...,"passed":false} because check_ok was ANDed across
# the node's whole history -- the first failing check pinned it false and no
# amount of repair could clear it. The QA prompt tells the agent to "read the
# JSON errors and repair the code until ok='true'", so the normal path through
# that prompt guaranteed a denial.
fn test_repaired_file_clears_its_earlier_failure() -> [io, proc] Result[Unit, Str] {
  let path := "/tmp/loom-qa-evidence-test-repair.json"
  let __c := runner.clear_qa_evidence(path)
  let __bad := lexskill.record_lex_check_evidence(path, "a.lex", false)
  let __fixed := lexskill.record_lex_check_evidence(path, "a.lex", true)
  match runner.verify_json_verdict_evidence(path, true) {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("a file that failed then was repaired must not keep denying a PASS, got: ", e)),
  }
}

# The other half of the same rule: clearing one file must NOT clear another
# that is still broken, or the gate would stop catching real failures.
fn test_other_file_still_failing_still_denies() -> [io, proc] Result[Unit, Str] {
  let path := "/tmp/loom-qa-evidence-test-partial.json"
  let __c := runner.clear_qa_evidence(path)
  let __a := lexskill.record_lex_check_evidence(path, "a.lex", false)
  let __b := lexskill.record_lex_check_evidence(path, "b.lex", false)
  let __fix_a := lexskill.record_lex_check_evidence(path, "a.lex", true)
  match runner.verify_json_verdict_evidence(path, true) {
    Ok(_) => Err("b.lex is still failing its check -- a claimed PASS must stay denied"),
    Err(_) => Ok(()),
  }
}

fn suite() -> [env, net, io, proc] List[Result[Unit, Str]] {
  [test_evidence_path_is_stable_per_sprint_node(), test_evidence_path_sanitizes_slashes(), test_no_evidence_file_denies(), test_evidence_agreeing_with_claim_allows(), test_evidence_contradicting_claim_denies(), test_gates_classifies_json_verdict_pass(), test_lex_check_records_passing_evidence(), test_lex_check_records_failing_evidence(), test_lex_check_then_failing_lex_run_merges_to_overall_fail(), test_for_role_qa_threads_evidence_path_to_its_tools(), test_repaired_file_clears_its_earlier_failure(), test_other_file_still_failing_still_denies()]
}

fn run_all() -> [env, net, io, proc] Unit {
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

