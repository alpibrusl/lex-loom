# dag_view.lex — render a sprint's graph (and any expand-node sub-sprints) as
# a Mermaid flowchart, with each node coloured by its current status.
#
# Status is read from `traces` (node_started/node_accepted/node_denied), not
# node_results — node_results is only ever written by the queue path
# (transport.write_node_result); in-process sprints (the default) only ever
# emit trace events, so traces is the one status source that works for both
# execution paths.
#
# Expand nodes (graph.Node.expand) run as a full child sprint whose id is
# "<parent_id>/<node_id>" (orchestrator.invoke_expand_node) — this module
# recursively renders that child graph as a Mermaid `subgraph` nested inside
# the expand node's own box, so a multi-level loom-of-looms shows up as one
# diagram, not just its top level.
#
# Output is a single Mermaid `flowchart TD` string — paste into
# https://mermaid.live, a GitHub/GitLab markdown code fence
# (```mermaid ... ```), or any Mermaid renderer.

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "lex-schema/json_value" as jv

import "./graph" as graph

fn sq(s :: Str) -> Str {
  str.replace(s, "'", "''")
}

# ── Load the latest graph saved for a sprint_id ──────────────────────────────
type GraphRow = { graph_json :: Str }

fn load_latest_graph(db :: conn.ConnDb, sprint_id :: Str) -> [sql, fs_read] Option[graph.SprintGraph] {
  let q := str.join(["SELECT graph_json FROM sprint_graphs WHERE sprint_id='", sq(sprint_id), "' ORDER BY created_at DESC LIMIT 1"], "")
  let rows :: Result[List[GraphRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => None,
    Ok(rs) => match list.head(rs) {
      None => None,
      Some(r) => match graph.from_json_str(r.graph_json) {
        Err(_) => None,
        Ok(g) => Some(g),
      },
    },
  }
}

# ── Node status, from traces ──────────────────────────────────────────────────
type NodeStatus = Pending | Running | Accepted | Denied

type TraceRow = { event_kind :: Str, data_json :: Str }

fn load_traces(db :: conn.ConnDb, sprint_id :: Str) -> [sql, fs_read] List[TraceRow] {
  let q := str.join(["SELECT event_kind, data_json FROM traces WHERE agent_id='", sq(sprint_id), "' AND event_kind IN ('node_started','node_accepted','node_denied','node_reused','node_skipped') ORDER BY id"], "")
  let rows :: Result[List[TraceRow], SqlError] := sql.query(db.handle, q, [])
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

fn trace_node_id(t :: TraceRow) -> Str {
  match jv.parse(t.data_json) {
    Err(_) => "",
    Ok(j) => match jv.get_field(j, "node") {
      Some(JStr(s)) => s,
      _ => "",
    },
  }
}

# Later events override earlier ones for the same node — this walks traces in
# order (ORDER BY id) and keeps overwriting, so the final fold value is each
# node's MOST RECENT status, correctly reflecting retries (denied -> accepted).
fn status_map(traces :: List[TraceRow]) -> List[(Str, NodeStatus)] {
  list.fold(traces, [], fn (acc :: List[(Str, NodeStatus)], t :: TraceRow) -> List[(Str, NodeStatus)] {
    let nid := trace_node_id(t)
    if str.is_empty(nid) {
      acc
    } else {
      let st := if t.event_kind == "node_started" {
        Running
      } else {
        if t.event_kind == "node_denied" {
          Denied
        } else {
          Accepted
        }
      }
      set_status(acc, nid, st)
    }
  })
}

fn set_status(m :: List[(Str, NodeStatus)], nid :: Str, st :: NodeStatus) -> List[(Str, NodeStatus)] {
  let without := list.filter(m, fn (p :: (Str, NodeStatus)) -> Bool {
    match p {
      (k, _) => k != nid,
    }
  })
  list.concat(without, [(nid, st)])
}

fn status_of(m :: List[(Str, NodeStatus)], nid :: Str) -> NodeStatus {
  list.fold(m, Pending, fn (acc :: NodeStatus, p :: (Str, NodeStatus)) -> NodeStatus {
    match p {
      (k, v) => if k == nid {
        v
      } else {
        acc
      },
    }
  })
}

fn status_class(st :: NodeStatus) -> Str {
  match st {
    Pending => "pending",
    Running => "running",
    Accepted => "accepted",
    Denied => "denied",
  }
}

fn status_label(st :: NodeStatus) -> Str {
  match st {
    Pending => "pending",
    Running => "running",
    Accepted => "done",
    Denied => "FAILED",
  }
}

# ── Mermaid rendering ─────────────────────────────────────────────────────────
# One flat, unique id per node across the whole (possibly multi-level) diagram
# -- Mermaid node ids must be unique document-wide, so a child sprint's node
# ids (which repeat role/id patterns across sub-sprints) are namespaced by
# their full sprint path.
fn mermaid_id(sprint_id :: Str, node_id :: Str) -> Str {
  str.replace(str.replace(str.join([sprint_id, "__", node_id], ""), "/", "_"), "-", "_")
}

fn escape_label(s :: Str) -> Str {
  str.replace(str.replace(s, "\"", "'"), "\n", " ")
}

fn render_node_line(sprint_id :: Str, n :: graph.Node, statuses :: List[(Str, NodeStatus)]) -> Str {
  let mid := mermaid_id(sprint_id, n.id)
  let st := status_of(statuses, n.id)
  let label := str.join([n.id, "\\n[", n.role, "]\\n(", status_label(st), ")"], "")
  str.join(["  ", mid, "[\"", escape_label(label), "\"]:::", status_class(st)], "")
}

fn render_edge_line(sprint_id :: Str, e :: graph.Edge) -> Str {
  str.join(["  ", mermaid_id(sprint_id, e.from), " --> ", mermaid_id(sprint_id, e.to)], "")
}

# Renders one sprint's graph as Mermaid node/edge lines, recursing into any
# expand node's child sprint as a nested `subgraph`. depth caps recursion to
# match orchestrator.max_expand_depth() (3) so a malformed/cyclic id scheme
# can't loop forever.
fn render_lines(db :: conn.ConnDb, sprint_id :: Str, depth :: Int) -> [sql, fs_read] List[Str] {
  if depth > 3 {
    []
  } else {
    match load_latest_graph(db, sprint_id) {
      None => [str.join(["  ", mermaid_id(sprint_id, "_missing"), "[\"(no graph saved for ", sprint_id, ")\"]"], "")],
      Some(g) => {
        let statuses := status_map(load_traces(db, sprint_id))
        let node_lines := list.fold(g.nodes, [], fn (acc :: List[Str], n :: graph.Node) -> [sql, fs_read] List[Str] {
          let own := render_node_line(sprint_id, n, statuses)
          match n.expand {
            None => list.concat(acc, [own]),
            Some(_) => {
              let child_id := str.join([sprint_id, "/", n.id], "")
              let child_lines := render_lines(db, child_id, depth + 1)
              let wrapped := list.concat([str.join(["  subgraph ", mermaid_id(sprint_id, n.id), "_expand [\"expand: ", n.id, "\"]"], "")], list.concat(child_lines, ["  end"]))
              list.concat(acc, list.concat([own], wrapped))
            },
          }
        })
        let edge_lines := list.map(g.edges, fn (e :: graph.Edge) -> Str {
          render_edge_line(sprint_id, e)
        })
        list.concat(node_lines, edge_lines)
      },
    }
  }
}

fn style_defs() -> List[Str] {
  ["  classDef pending fill:#e5e7eb,stroke:#9ca3af,color:#374151", "  classDef running fill:#fef9c3,stroke:#ca8a04,color:#713f12", "  classDef accepted fill:#dcfce7,stroke:#16a34a,color:#14532d", "  classDef denied fill:#fee2e2,stroke:#dc2626,color:#7f1d1d"]
}

# Public entry point: full Mermaid `flowchart TD` document for a sprint,
# including every expand-node sub-sprint nested as its own subgraph.
fn sprint_dag_mermaid(db :: conn.ConnDb, sprint_id :: Str) -> [sql, fs_read] Str {
  let body := render_lines(db, sprint_id, 0)
  str.join(list.concat(["flowchart TD"], list.concat(body, style_defs())), "\n")
}

