# test_qa_demo_reuse.lex — regression coverage for a silent double-execution
# bug found live while burning a real OpenCode subscription: run_sprint's
# "QA phase" step unconditionally re-ran the ENTIRE Implementation graph
# (build, qa, launch, demo, scribe -- everything) a second time, from
# scratch, with an empty cache, whenever the architect's own graph already
# contained a "qa" or "demo"-role node -- which is virtually every real
# graph, since "demo" is a standard terminal step and Python sprints use
# role "py_qa" (not "qa"). Every sprint with a normal demo step silently
# doubled its build+qa+launch+demo+scribe cost, with no denial or bounce
# ever recorded to explain it.
#
# qa_demo_role_nodes(g) is the pure detection orchestrator.run_sprint now
# checks BEFORE deciding whether to reuse impl_result directly (no re-run)
# or fall back to the synthetic qa+demo pair (only when the graph truly has
# no embedded gate to reuse).

import "std.list" as list

import "std.str" as str

import "../src/graph" as graph

import "../src/orchestrator" as orch

fn node(id :: Str, role :: Str) -> graph.Node {
  { id: id, role: role, gate: "spec non-empty", expand: None, activate_when: "" }
}

fn g(nodes :: List[graph.Node]) -> graph.SprintGraph {
  { id: "g", phase: graph.Implementation, nodes: nodes, edges: [] }
}

# The exact bug scenario: a Python sprint graph whose QA node is role
# "py_qa" (not "qa") but whose terminal node is role "demo" -- the standard
# shape for basically every Python sprint. This MUST be detected as
# "already has a demo gate", or the whole pipeline re-runs.
fn test_python_sprint_shape_is_detected_via_demo_role() -> Result[Unit, Str] {
  let graph_ := g([node("py_build", "py_build"), node("py_qa", "py_qa"), node("launch", "launch"), node("demo", "demo"), node("scribe", "scribe")])
  let found := orch.qa_demo_role_nodes(graph_)
  if list.len(found) == 1 {
    if graph.str_contains(found, "demo") {
      Ok(())
    } else {
      Err("expected the demo-role node to be the one detected")
    }
  } else {
    Err(str.concat("expected exactly 1 qa/demo-role node detected, got ", str.concat("", str.join(found, ","))))
  }
}

# A Lex sprint using the literal "qa" role is detected too.
fn test_lex_sprint_shape_is_detected_via_qa_role() -> Result[Unit, Str] {
  let graph_ := g([node("build", "build"), node("qa", "qa"), node("demo", "demo")])
  let found := orch.qa_demo_role_nodes(graph_)
  if list.len(found) == 2 {
    Ok(())
  } else {
    Err("expected both the qa-role and demo-role nodes to be detected")
  }
}

# A bare build-only graph with no qa/demo-style terminal at all must be
# reported empty -- that's the ONLY case where falling back to the
# synthetic qa+demo pair (and re-running the graph under it) is correct.
fn test_bare_build_graph_has_none() -> Result[Unit, Str] {
  let graph_ := g([node("build", "build")])
  if list.is_empty(orch.qa_demo_role_nodes(graph_)) {
    Ok(())
  } else {
    Err("a bare build-only graph must report no qa/demo-role node")
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_python_sprint_shape_is_detected_via_demo_role(), test_lex_sprint_shape_is_detected_via_qa_role(), test_bare_build_graph_has_none()]
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

