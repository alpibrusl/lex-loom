# test_verify.lex — pure-logic tests for the sprint verifier (#47).
# The end-to-end re-derivation (tamper detection) is exercised live; here we lock
# down the artifact-hash extraction and report formatting.

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "../src/verify" as verify

import "../src/roles" as roles

import "../src/role_tools" as rt

import "lex-llm/src/tool" as tl

fn test_extracts_artifact_hash() -> Result[Unit, Str] {
  let h := verify.artifact_hash("{\"node\":\"build\",\"artifact\":\"abc123\"}")
  if h == "abc123" {
    Ok(())
  } else {
    Err(str.concat("expected abc123, got ", h))
  }
}

fn test_missing_artifact_field() -> Result[Unit, Str] {
  if str.is_empty(verify.artifact_hash("{\"node\":\"build\"}")) {
    Ok(())
  } else {
    Err("expected empty hash when artifact field absent")
  }
}

fn test_bad_json() -> Result[Unit, Str] {
  if str.is_empty(verify.artifact_hash("not json")) {
    Ok(())
  } else {
    Err("expected empty hash on unparseable data")
  }
}

fn test_report_verified() -> Result[Unit, Str] {
  let j := verify.report_json({ sprint_id: "s1", checked: 3, intact: 3, mismatched: 0, missing: 0, verified: true })
  if str.contains(j, "\"verdict\":\"verified\"") {
    Ok(())
  } else {
    Err(str.concat("expected verified verdict, got ", j))
  }
}

fn test_report_failed() -> Result[Unit, Str] {
  let j := verify.report_json({ sprint_id: "s1", checked: 3, intact: 2, mismatched: 1, missing: 0, verified: false })
  if str.contains(j, "\"verdict\":\"FAILED\"") {
    Ok(())
  } else {
    Err(str.concat("expected FAILED verdict, got ", j))
  }
}

fn test_node_gates_and_lookup() -> Result[Unit, Str] {
  let g := "{\"id\":\"s\",\"phase\":\"Design\",\"nodes\":[{\"id\":\"build\",\"role\":\"build\",\"gate\":\"spec compiles\"},{\"id\":\"demo\",\"role\":\"demo\",\"gate\":\"spec len-gt 50\"}],\"edges\":[]}"
  let pairs := verify.node_gates(g)
  if verify.lookup_gate(pairs, "build") == "spec compiles" {
    if verify.lookup_gate(pairs, "demo") == "spec len-gt 50" {
      if str.is_empty(verify.lookup_gate(pairs, "nope")) {
        Ok(())
      } else {
        Err("unknown node should map to empty gate")
      }
    } else {
      Err("demo gate wrong")
    }
  } else {
    Err("build gate wrong")
  }
}

fn test_is_grounded_gate() -> Result[Unit, Str] {
  if verify.is_grounded_gate("spec compiles") {
    if verify.is_grounded_gate("spec sh \"docker build .\"") {
      if verify.is_grounded_gate("spec len-gt 50") {
        Err("len-gt is not a grounded gate")
      } else {
        Ok(())
      }
    } else {
      Err("spec sh should be grounded")
    }
  } else {
    Err("spec compiles should be grounded")
  }
}

fn test_grant_within_policy() -> Result[Unit, Str] {
  if verify.grant_ok("build", "lex_guidelines,lex_check") {
    if verify.grant_ok("demo", "") {
      Ok(())
    } else {
      Err("empty grant for prose role should be ok")
    }
  } else {
    Err("build's canonical tools should be within policy")
  }
}

fn test_grant_violation() -> Result[Unit, Str] {
  if verify.grant_ok("demo", "lex_run") {
    Err("demo granted lex_run must be a violation")
  } else {
    if verify.grant_ok("build", "lex_check,rm_rf") {
      Err("unknown tool in a build grant must be a violation")
    } else {
      Ok(())
    }
  }
}

fn test_authreport_json() -> Result[Unit, Str] {
  let v := verify.authreport_json({ sprint_id: "s1", nodes: 4, ok: 4, violations: 0, verified: true })
  if str.contains(v, "\"verdict\":\"authority-ok\"") {
    let b := verify.authreport_json({ sprint_id: "s1", nodes: 4, ok: 3, violations: 1, verified: false })
    if str.contains(b, "\"verdict\":\"VIOLATION\"") {
      Ok(())
    } else {
      Err(str.concat("expected VIOLATION verdict, got ", b))
    }
  } else {
    Err(str.concat("expected authority-ok verdict, got ", v))
  }
}

fn test_opreport_json() -> Result[Unit, Str] {
  let ok := verify.opreport_json({ sprint_id: "s1", ops: 5, in_grant: 5, exceeded: 0, verified: true })
  if str.contains(ok, "\"verdict\":\"ops-within-grant\"") {
    let bad := verify.opreport_json({ sprint_id: "s1", ops: 5, in_grant: 4, exceeded: 1, verified: false })
    if str.contains(bad, "\"verdict\":\"EXCEEDED\"") {
      Ok(())
    } else {
      Err(str.concat("expected EXCEEDED verdict, got ", bad))
    }
  } else {
    Err(str.concat("expected ops-within-grant verdict, got ", ok))
  }
}

# Regression (#47 review): the `launch` role carries a `run_server` tool, which
# the verifier's old hand-copied policy omitted — so every HTTP-server sprint got
# a spurious VIOLATION. With one shared policy (role_tools), the grant verifies.
fn test_launch_authority_regression() -> Result[Unit, Str] {
  if verify.grant_ok("launch", "run_server") {
    Ok(())
  } else {
    Err("launch/run_server flagged as a violation — verifier policy drifted from roles")
  }
}

fn role_tools_csv(tools :: List[tl.Tool]) -> Str {
  str.join(list.map(tools, fn (x :: tl.Tool) -> Str {
    x.name
  }), ",")
}

# Drift guard: the tools the runtime actually grants each role (roles.tools_of_role)
# must equal the canonical policy the verifier checks (role_tools.tools_for). This
# is what makes the independent re-derivation trustworthy — fails CI the moment
# the two diverge.
fn test_runtime_matches_policy() -> [env] Result[Unit, Str] {
  list.fold(["build", "py_build", "qa", "py_qa", "launch", "deploy", "content_creator", "cx"], Ok(()), fn (acc :: Result[Unit, Str], r :: Str) -> [env] Result[Unit, Str] {
    match acc {
      Err(e) => Err(e),
      Ok(_) => {
        let runtime := role_tools_csv(roles.tools_of_role(r, "", ""))
        let policy := str.join(rt.tools_for(r), ",")
        if runtime == policy {
          Ok(())
        } else {
          Err(str.join(["role ", r, ": runtime tools [", runtime, "] != policy [", policy, "]"], ""))
        }
      },
    }
  })
}

# Found live (pdfx company run this session): a real ModuleNotFoundError from
# an unavailable third-party package (the sandbox has no pip/install step)
# left zero trace in any artifact or scribe note -- py_build silently
# rewrote around it. annotate_missing_dependency gives the retry loop an
# explicit, unmissable marker instead.
fn test_annotate_missing_dependency_flags_module_not_found() -> Result[Unit, Str] {
  let out := roles.annotate_missing_dependency("Traceback (most recent call last):\nModuleNotFoundError: No module named 'pdfplumber'\n##EXIT:1")
  if str.contains(out, "[MISSING_DEPENDENCY]") {
    Ok(())
  } else {
    Err(str.concat("expected the missing-dependency marker: ", out))
  }
}

fn test_annotate_missing_dependency_flags_import_error() -> Result[Unit, Str] {
  let out := roles.annotate_missing_dependency("ImportError: cannot import name 'foo' from 'bar'\n##EXIT:1")
  if str.contains(out, "[MISSING_DEPENDENCY]") {
    Ok(())
  } else {
    Err(str.concat("expected the missing-dependency marker: ", out))
  }
}

fn test_annotate_missing_dependency_leaves_unrelated_failures_alone() -> Result[Unit, Str] {
  let raw := "AssertionError: expected 2 got 3\n##EXIT:1"
  let out := roles.annotate_missing_dependency(raw)
  if out == raw {
    Ok(())
  } else {
    Err(str.concat("an unrelated failure should be passed through unchanged: ", out))
  }
}

# Found live (pdfx2 company run): a single build/py_build node asked to add
# a route + wire a payment gate + integrate a subprocess call all at once
# reliably returned EMPTY output across repeated real attempts (iters 10,
# 15, 16, 18) -- a genuine model complexity ceiling, not a wiring bug. The
# Architect already has an "expand node" mechanism built for exactly this
# (delegating a large sub-task to its own recursive PM->build->QA pipeline)
# but nothing told it to reach for that -- or for sequential build nodes --
# when a single build task gets overloaded.
fn test_architect_prompt_warns_against_oversized_build_tasks() -> Result[Unit, Str] {
  let prompt := roles.architect_system_prompt()
  if str.contains(prompt, "EMPTY output") {
    if str.contains(prompt, "split it") {
      Ok(())
    } else {
      Err("expected the architect prompt to instruct splitting an oversized build task")
    }
  } else {
    Err("expected the architect prompt to warn about oversized build tasks returning empty output")
  }
}

fn suite() -> [env] List[Result[Unit, Str]] {
  [test_extracts_artifact_hash(), test_missing_artifact_field(), test_bad_json(), test_report_verified(), test_report_failed(), test_node_gates_and_lookup(), test_is_grounded_gate(), test_grant_within_policy(), test_grant_violation(), test_authreport_json(), test_opreport_json(), test_launch_authority_regression(), test_runtime_matches_policy(), test_annotate_missing_dependency_flags_module_not_found(), test_annotate_missing_dependency_flags_import_error(), test_annotate_missing_dependency_leaves_unrelated_failures_alone(), test_architect_prompt_warns_against_oversized_build_tasks()]
}

fn run_all() -> [env] Unit {
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

