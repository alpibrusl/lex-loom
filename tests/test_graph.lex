import "std.list" as list

import "std.str" as str

import "std.int" as int

import "../src/graph" as graph

# ── Fixtures ──────────────────────────────────────────────────────────────────
fn node(id :: Str, role :: Str) -> graph.Node {
  { id: id, role: role, gate: "spec true", expand: None, activate_when: "" }
}

fn edge(from :: Str, to :: Str) -> graph.Edge {
  { from: from, to: to, handoff: "schema {}" }
}

fn g(id :: Str, nodes :: List[graph.Node], edges :: List[graph.Edge]) -> graph.SprintGraph {
  { id: id, phase: graph.Intake, nodes: nodes, edges: edges }
}

# ── Tests (each returns Result[Unit, Str]) ────────────────────────────────────
fn test_empty_graph() -> Result[Unit, Str] {
  match graph.validate(g("t1", [], [])) {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("empty graph should be valid: ", e)),
  }
}

fn test_single_node() -> Result[Unit, Str] {
  match graph.validate(g("t2", [node("n1", "build")], [])) {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("single node should be valid: ", e)),
  }
}

fn test_duplicate_ids() -> Result[Unit, Str] {
  match graph.validate(g("t3", [node("n1", "build"), node("n1", "test")], [])) {
    Ok(_) => Err("duplicate ids should be rejected"),
    Err(e) => if str.contains(e, "duplicate node id: n1") {
      Ok(())
    } else {
      Err(str.concat("wrong error: ", e))
    },
  }
}

fn test_empty_role() -> Result[Unit, Str] {
  match graph.validate(g("t4", [{ id: "n1", role: "", gate: "spec true", expand: None, activate_when: "" }], [])) {
    Ok(_) => Err("empty role should be rejected"),
    Err(e) => if str.contains(e, "empty role") {
      Ok(())
    } else {
      Err(str.concat("wrong error: ", e))
    },
  }
}

fn test_ungated_node() -> Result[Unit, Str] {
  match graph.validate(g("t5", [{ id: "n1", role: "build", gate: "", expand: None, activate_when: "" }], [])) {
    Ok(_) => Err("ungated node should be rejected"),
    Err(e) => if str.contains(e, "no gate") {
      Ok(())
    } else {
      Err(str.concat("wrong error: ", e))
    },
  }
}

fn test_unknown_edge_target() -> Result[Unit, Str] {
  match graph.validate(g("t6", [node("n1", "build")], [edge("n1", "n2")])) {
    Ok(_) => Err("edge to unknown node should be rejected"),
    Err(e) => if str.contains(e, "unknown target") {
      Ok(())
    } else {
      Err(str.concat("wrong error: ", e))
    },
  }
}

fn test_unknown_edge_source() -> Result[Unit, Str] {
  match graph.validate(g("t7", [node("n1", "build")], [edge("n0", "n1")])) {
    Ok(_) => Err("edge from unknown node should be rejected"),
    Err(e) => if str.contains(e, "unknown source") {
      Ok(())
    } else {
      Err(str.concat("wrong error: ", e))
    },
  }
}

fn test_linear_dag() -> Result[Unit, Str] {
  match graph.validate(g("t8", [node("a", "build"), node("b", "test"), node("c", "deploy")], [edge("a", "b"), edge("b", "c")])) {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("linear DAG should be valid: ", e)),
  }
}

fn test_cycle_rejected() -> Result[Unit, Str] {
  match graph.validate(g("t9", [node("a", "build"), node("b", "test")], [edge("a", "b"), edge("b", "a")])) {
    Ok(_) => Err("cycle should be rejected"),
    Err(e) => if str.contains(e, "cycle") {
      Ok(())
    } else {
      Err(str.concat("wrong error: ", e))
    },
  }
}

fn test_diamond_dag() -> Result[Unit, Str] {
  match graph.validate(g("t10", [node("a", "plan"), node("b", "build"), node("c", "build"), node("d", "merge")], [edge("a", "b"), edge("a", "c"), edge("b", "d"), edge("c", "d")])) {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("diamond DAG should be valid: ", e)),
  }
}

fn test_topo_sort_layers() -> Result[Unit, Str] {
  match graph.topo_sort(g("t11", [node("a", "plan"), node("b", "build"), node("c", "test")], [edge("a", "b"), edge("b", "c")])) {
    Err(e) => Err(str.concat("topo sort failed: ", e)),
    Ok(layers) => if list.is_empty(layers) {
      Err("topo sort returned empty layers")
    } else {
      Ok(())
    },
  }
}

fn test_from_json_roundtrip() -> Result[Unit, Str] {
  let g0 := g("rt1", [node("a", "build")], [])
  let json_str := graph.to_json_str(g0)
  match graph.from_json_str(json_str) {
    Err(e) => Err(str.concat("round-trip parse failed: ", e)),
    Ok(g2) => if g2.id == "rt1" {
      Ok(())
    } else {
      Err(str.concat("wrong id after round-trip: ", g2.id))
    },
  }
}

fn test_activate_when_roundtrip() -> Result[Unit, Str] {
  let gated := { id: "g", role: "build", gate: "spec true", expand: None, activate_when: "iter ge 2" }
  let g0 := g("rt2", [gated], [])
  match graph.from_json_str(graph.to_json_str(g0)) {
    Err(e) => Err(str.concat("round-trip parse failed: ", e)),
    Ok(g2) => match list.head(g2.nodes) {
      None => Err("no nodes after round-trip"),
      Some(n) => if n.activate_when == "iter ge 2" {
        Ok(())
      } else {
        Err(str.concat("activate_when lost in round-trip: ", n.activate_when))
      },
    },
  }
}

fn test_phase_from_str() -> Result[Unit, Str] {
  match graph.phase_from_str("QA") {
    Err(e) => Err(str.concat("phase_from_str failed: ", e)),
    Ok(QA) => Ok(()),
    Ok(_) => Err("wrong phase"),
  }
}

# ── Suite ─────────────────────────────────────────────────────────────────────
fn suite() -> List[Result[Unit, Str]] {
  [test_empty_graph(), test_single_node(), test_duplicate_ids(), test_empty_role(), test_ungated_node(), test_unknown_edge_target(), test_unknown_edge_source(), test_linear_dag(), test_cycle_rejected(), test_diamond_dag(), test_topo_sort_layers(), test_from_json_roundtrip(), test_activate_when_roundtrip(), test_phase_from_str()]
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

