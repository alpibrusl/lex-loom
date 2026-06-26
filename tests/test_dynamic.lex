# test_dynamic.lex — unit tests for the dynamic-DAG extension helpers (#41).
#
# Covers the pure pieces of the extension loop: which nodes count as "new" when
# the architect returns an extended graph, and how an artifact cache is seeded
# from a phase's accepted outcomes (so re-running the extended graph skips the
# already-done nodes). The live loop (run_extensions) is exercised by the
# DYNAMIC_DAG=1 demo sprint; here we lock down the deterministic logic.

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "../src/graph" as graph

import "../src/orchestrator" as orch

fn node(id :: Str) -> graph.Node {
  { id: id, role: "build", gate: "spec non-empty", expand: None }
}

fn g(nodes :: List[graph.Node]) -> graph.SprintGraph {
  { id: "g", phase: graph.Implementation, nodes: nodes, edges: [] }
}

fn outcome(id :: Str, attested :: Bool, artifact :: Str) -> orch.NodeOutcome {
  { node_id: id, attested: attested, sealed: attested, artifact: artifact, reason: "" }
}

# ── new_node_ids ──────────────────────────────────────────────────────────────
fn test_new_nodes_added() -> Result[Unit, Str] {
  let base := g([node("a"), node("b")])
  let ext := g([node("a"), node("b"), node("c"), node("d")])
  let news := orch.new_node_ids(base, ext)
  if list.len(news) == 2 {
    if graph.str_contains(news, "c") and graph.str_contains(news, "d") {
      Ok(())
    } else {
      Err("expected c and d to be new")
    }
  } else {
    Err(str.concat("expected 2 new nodes, got ", int.to_str(list.len(news))))
  }
}

fn test_no_new_nodes_when_unchanged() -> Result[Unit, Str] {
  let base := g([node("a"), node("b")])
  let ext := g([node("a"), node("b")])
  if list.is_empty(orch.new_node_ids(base, ext)) {
    Ok(())
  } else {
    Err("expected no new nodes for an unchanged graph")
  }
}

fn test_dropped_node_is_not_new() -> Result[Unit, Str] {
  let base := g([node("a"), node("b")])
  let ext := g([node("a")])
  if list.is_empty(orch.new_node_ids(base, ext)) {
    Ok(())
  } else {
    Err("a graph that only drops nodes has no NEW nodes")
  }
}

# ── cache_from_outcomes ───────────────────────────────────────────────────────
fn test_cache_includes_only_attested_with_artifact() -> Result[Unit, Str] {
  let outs := [outcome("a", true, "hashA"), outcome("b", false, ""), outcome("c", true, "")]
  let cache := orch.cache_from_outcomes(outs)
  match orch.cache_get(cache, "a") {
    None => Err("expected a in cache"),
    Some(h) => if h == "hashA" {
      match orch.cache_get(cache, "b") {
        Some(_) => Err("b is not attested — must not be cached"),
        None => match orch.cache_get(cache, "c") {
          Some(_) => Err("c has empty artifact — must not be cached"),
          None => Ok(()),
        },
      }
    } else {
      Err(str.concat("wrong hash for a: ", h))
    },
  }
}

# ── Suite ─────────────────────────────────────────────────────────────────────
fn suite() -> List[Result[Unit, Str]] {
  [test_new_nodes_added(), test_no_new_nodes_when_unchanged(), test_dropped_node_is_not_new(), test_cache_includes_only_attested_with_artifact()]
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

