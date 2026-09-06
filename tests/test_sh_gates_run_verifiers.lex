# test_sh_gates_run_verifiers.lex — a shell gate may not run a script no role
# produces (#329).
#
# tzc9's Architect added a smoke-gate node with `spec sh "python3
# smoke_check.py"`. The build had mentioned smoke_check.py in prose, so to the
# Architect the file existed; on disk it never did, and the gate failed four
# times on "can't open file". A gate that runs a script the graph does not
# produce is an assertion about a file, not a check.

import "std.str" as str

import "std.list" as list

import "../src/graph" as graph

import "../src/metaspec" as meta

fn mk(id :: Str, role :: Str, gate :: Str) -> graph.Node {
  { id: id, role: role, gate: gate, expand: None, activate_when: "" }
}

fn has_rule(res :: meta.MetaspecResult, rule :: Str) -> Bool {
  match res {
    Valid => false,
    Invalid(vs) => list.fold(vs, false, fn (acc :: Bool, v :: meta.Violation) -> Bool {
      acc or v.rule == rule
    }),
  }
}

fn gate_graph(gate :: Str) -> graph.SprintGraph {
  { id: "g", phase: graph.Implementation, nodes: [mk("b", "py_build", "spec compiles"), mk("x", "docs", gate)], edges: [{ from: "b", to: "x", handoff: "build" }] }
}

fn test_a_bare_script_gate_is_rejected() -> Result[Unit, Str] {
  if has_rule(meta.check(gate_graph("spec sh \"python3 smoke_check.py\"")), "sh-gate-runs-a-script-nobody-produces") {
    Ok(())
  } else {
    Err("`python3 smoke_check.py` was accepted as a gate — the file it runs does not exist")
  }
}

fn test_a_dot_slash_script_is_rejected() -> Result[Unit, Str] {
  if has_rule(meta.check(gate_graph("spec sh \"./run_checks.sh\"")), "sh-gate-runs-a-script-nobody-produces") {
    Ok(())
  } else {
    Err("`./run_checks.sh` was accepted as a gate")
  }
}

# The negative controls: every gate the Architect legitimately produces today
# must stay valid, or the rule rejects the runs that work.
fn test_legitimate_gates_stay_valid() -> Result[Unit, Str] {
  let ok_gates := ["spec sh \"python3 $LOOM_ROOT/bin/check_imports.py .\"", "spec sh \"python3 $LOOM_ROOT/bin/check_derived_values.py .\"", "spec sh \"pytest -q\"", "spec sh \"python3 -m pytest -q\"", "spec sh \"docker build -t tzconvert .\"", "spec sh \"npm ci && npm run build\"", "spec sh \"lex test\""]
  let rejected := list.filter(ok_gates, fn (g :: Str) -> Bool {
    has_rule(meta.check(gate_graph(g)), "sh-gate-runs-a-script-nobody-produces")
  })
  if list.is_empty(rejected) {
    Ok(())
  } else {
    Err(str.concat("legitimate gates were rejected: ", str.join(rejected, " | ")))
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_a_bare_script_gate_is_rejected(), test_a_dot_slash_script_is_rejected(), test_legitimate_gates_stay_valid()]
}

fn run_all() -> Unit {
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

