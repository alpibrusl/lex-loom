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
# That was fixed by reusing impl_result instead of re-running -- but reuse
# meant the QA<->Implementation bounce became unreachable for exactly those
# graphs, so a QA failure sank the sprint without the builder ever being told
# (observed live in tzlocal2: every iteration ended bounced=0).
#
# run_sprint now SPLITS the Architect's graph instead: graph.impl_subgraph
# runs in Implementation, graph.qa_subgraph runs in QA with the bounce
# available. Each node still executes exactly once per round -- the split is
# a partition, which is what keeps the original double-execution bug fixed --
# and the tests below pin that partition. qa_demo_role_nodes is retained as
# the pure detector this file already covers.

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

# The partition is what keeps the original double-execution bug dead: every
# node must land in exactly ONE half, so no node can run twice per round.
fn test_split_is_a_partition() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "q", role: "py_qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }, { id: "d", role: "demo", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [{ from: "b", to: "q", handoff: "schema {}" }, { from: "q", to: "d", handoff: "schema {}" }] }
  let impl_n := list.len(graph.impl_subgraph(gph).nodes)
  let qa_n := list.len(graph.qa_subgraph(gph).nodes)
  if impl_n + qa_n == list.len(gph.nodes) {
    if impl_n == 1 {
      Ok(())
    } else {
      Err("the build node alone belongs to the Implementation half")
    }
  } else {
    Err("split must be a partition -- a node in both halves would run twice, which is the bug this file exists for")
  }
}

# An edge whose other end was filtered out must be dropped, or the subgraph
# fails validate_edge_refs and the phase cannot run at all.
fn test_split_drops_edges_that_cross_the_halves() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "q", role: "py_qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }], edges: [{ from: "b", to: "q", handoff: "schema {}" }] }
  if list.is_empty(graph.qa_subgraph(gph).edges) {
    if list.is_empty(graph.impl_subgraph(gph).edges) {
      Ok(())
    } else {
      Err("the b->q edge crosses the halves and must not survive in the impl half")
    }
  } else {
    Err("the b->q edge crosses the halves and must not survive in the qa half")
  }
}

# py_qa and ts_qa are QA. Matching only the bare "qa" is what let a Python
# sprint's judge run inside Implementation.
fn test_language_specific_qa_roles_are_qa() -> Result[Unit, Str] {
  if graph.is_qa_role("py_qa") {
    if graph.is_qa_role("ts_qa") {
      if graph.is_qa_role("py_build") {
        Err("a build role must not be treated as QA")
      } else {
        Ok(())
      }
    } else {
      Err("ts_qa is a QA role")
    }
  } else {
    Err("py_qa is a QA role -- missing this ran the Python judge inside Implementation")
  }
}

# A graph with a demo node but no judge must still take the synthetic path:
# demo alone is not a gate, and treating it as one is what disabled bouncing.
fn test_demo_alone_is_not_a_qa_node() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "d", role: "demo", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [] }
  if graph.has_qa_node(gph) {
    Err("a demo node is not a judge -- counting it as one is what left real QA failures unbounced")
  } else {
    Ok(())
  }
}

# Found live (tzconvert baseline, third attempt): the Architect produced a
# CORRECT graph -- py_build-1..3 each paired with py_qa-1..3 -- and all three
# py_qa nodes were silently discarded. run_sprint rebound `sprint_graph` to the
# extension of the implementation-only half, which by construction holds no QA
# node, so has_qa_node was always false and every sprint fell through to the
# synthetic fallback. A Lex judge then ran lex_check against Python.
#
# The split must narrow what Implementation RUNS without narrowing what QA is
# SELECTED from. This pins the property directly: a graph whose QA nodes are
# py_qa must still be detected as having QA.
fn test_py_qa_nodes_are_detected_as_qa() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "q", role: "py_qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }], edges: [{ from: "b", to: "q", handoff: "schema {}" }] }
  if graph.has_qa_node(gph) {
    if list.len(graph.qa_subgraph(gph).nodes) == 1 {
      Ok(())
    } else {
      Err("the py_qa node must land in the QA half")
    }
  } else {
    Err("a graph with py_qa nodes has QA — missing this discards the Architect's own judges")
  }
}

# The implementation half must never be mistaken for the whole graph when
# deciding whether QA exists: that is exactly the clobber that caused the bug.
fn test_impl_half_alone_has_no_qa() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "q", role: "py_qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }], edges: [] }
  if graph.has_qa_node(graph.impl_subgraph(gph)) {
    Err("the implementation half must not report QA — testing it instead of the full graph is what silently dropped py_qa")
  } else {
    Ok(())
  }
}

# The synthetic fallback must pick a judge that can read the code.
fn test_synthetic_qa_role_follows_the_build_language() -> Result[Unit, Str] {
  let py := { id: "g", phase: graph.Implementation, nodes: [{ id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }], edges: [] }
  let lx := { id: "g", phase: graph.Implementation, nodes: [{ id: "b", role: "build", gate: "spec compiles", expand: None, activate_when: "" }], edges: [] }
  let mixed := { id: "g", phase: graph.Implementation, nodes: [{ id: "b1", role: "build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "b2", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }], edges: [] }
  if graph.qa_role_for_graph(py) == "py_qa" {
    if graph.qa_role_for_graph(lx) == "qa" {
      if graph.qa_role_for_graph(mixed) == "qa" {
        Ok(())
      } else {
        Err("a mixed-language graph has no single right judge; it must keep the generic one rather than guess")
      }
    } else {
      Err("a Lex build takes the Lex judge")
    }
  } else {
    Err("a Python build must get py_qa — the Lex judge cannot read Python")
  }
}

# A DAG's edges are its schedule. Filtering edges when splitting the graph
# dropped every edge that crossed the halves, and with it the ordering those
# edges carried: pm -> py_build -> py_qa -> launch became pm -> py_build with
# launch orphaned, so launch became a ROOT and ran FIRST. In a live company
# exactly that happened -- launch, devops, legal and scribe executed while
# py_build and py_test_author were never enqueued, and QA then denied with
# "work dir missing" because it judged a build that had never run.
fn test_ordering_through_a_removed_node_survives() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "q", role: "py_qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }, { id: "l", role: "launch", gate: "spec json-ok-true", expand: None, activate_when: "" }], edges: [{ from: "b", to: "q", handoff: "s" }, { from: "q", to: "l", handoff: "s" }] }
  let impl := graph.impl_subgraph(gph)
  match graph.topo_sort(impl) {
    Err(e) => Err(str.concat("impl half must stay a valid DAG: ", e)),
    Ok(layers) => match list.head(layers) {
      None => Err("no layers"),
      Some(first) => if graph.str_contains(first, "l") {
        Err("launch must NOT be in the first layer — the build has not run yet, which is how a launch node ended up executing before any code existed")
      } else {
        Ok(())
      },
    },
  }
}

# The surviving order must be the real one: build strictly before launch.
fn test_transitive_edge_is_added() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "q", role: "py_qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }, { id: "l", role: "launch", gate: "spec json-ok-true", expand: None, activate_when: "" }], edges: [{ from: "b", to: "q", handoff: "s" }, { from: "q", to: "l", handoff: "s" }] }
  let has := list.fold(graph.impl_subgraph(gph).edges, false, fn (acc :: Bool, e :: graph.Edge) -> Bool {
    if acc {
      true
    } else {
      if e.from == "b" {
        e.to == "l"
      } else {
        false
      }
    }
  })
  if has {
    Ok(())
  } else {
    Err("b -> l must be synthesised: the ordering passed through the removed qa node")
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_python_sprint_shape_is_detected_via_demo_role(), test_lex_sprint_shape_is_detected_via_qa_role(), test_bare_build_graph_has_none(), test_split_is_a_partition(), test_split_drops_edges_that_cross_the_halves(), test_language_specific_qa_roles_are_qa(), test_demo_alone_is_not_a_qa_node(), test_py_qa_nodes_are_detected_as_qa(), test_impl_half_alone_has_no_qa(), test_synthetic_qa_role_follows_the_build_language(), test_ordering_through_a_removed_node_survives(), test_transitive_edge_is_added()]
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

