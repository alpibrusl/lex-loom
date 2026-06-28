# hello.lex — offline hello-world: validates a SprintGraph and runs phase transitions.
# No LLM, no DB, no network. Pure M1 logic end-to-end.
#
# Run:
#   lex run --allow-effects io src/hello.lex hello
#
# Expected output: a valid graph and a full Intake→Digest phase walk, no errors.

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "./graph" as graph

import "./phase" as phase

import "./metaspec" as meta

import "./diff" as diff

fn sep() -> [io] Unit {
  let __p := io.print("─────────────────────────────────────────")
  ()
}

fn ok(label :: Str) -> [io] Unit {
  let __p := io.print(str.concat("  ✓ ", label))
  ()
}

fn fail(label :: Str, reason :: Str) -> [io] Unit {
  let __p := io.print(str.join(["  ✗ ", label, ": ", reason], ""))
  ()
}

fn check(label :: Str, r :: Result[Unit, Str]) -> [io] Unit {
  match r {
    Ok(_) => ok(label),
    Err(e) => fail(label, e),
  }
}

fn hello() -> [io] Unit {
  let __h := io.print("lex-loom hello world")
  let __s := sep()
  let __p1 := io.print("1. Graph validation")
  let sprint_graph := { id: "hello-sprint", phase: graph.Design, nodes: [{ id: "architect", role: "architect", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "build", role: "build", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "qa", role: "qa", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "demo", role: "demo", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [{ from: "architect", to: "build", handoff: "schema {}" }, { from: "build", to: "qa", handoff: "schema {}" }, { from: "qa", to: "demo", handoff: "schema {}" }] }
  let __v1 := check("valid graph passes graph.validate", graph.validate(sprint_graph))
  let __v2 := check("valid graph passes metaspec.check", match meta.check(sprint_graph) {
    Valid => Ok(()),
    Invalid(vs) => Err(list.fold(vs, "", fn (a :: Str, v :: meta.Violation) -> Str {
      str.concat(a, str.concat(v.rule, "; "))
    })),
  })
  let bad_graph := { id: "bad", phase: graph.Intake, nodes: [{ id: "demo", role: "demo", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [] }
  let __v3 := check("demo without qa rejected by metaspec", match meta.check(bad_graph) {
    Invalid(_) => Ok(()),
    Valid => Err("should have been rejected"),
  })
  let __s2 := sep()
  let __p2 := io.print("2. JSON round-trip")
  let json_str := graph.to_json_str(sprint_graph)
  let __v4 := check("serialize → parse round-trip", match graph.from_json_str(json_str) {
    Err(e) => Err(e),
    Ok(g2) => if g2.id == sprint_graph.id {
      Ok(())
    } else {
      Err(str.concat("id mismatch: ", g2.id))
    },
  })
  let __p2b := io.print(str.concat("  serialized: ", str.slice(json_str, 0, 60)))
  let __s3 := sep()
  let __p3 := io.print("3. Phase state machine (full Intake → Digest walk)")
  let walk_result := walk_phases()
  let __v5 := check("full phase walk completes without error", walk_result)
  let __s4 := sep()
  let __p4 := io.print("4. Semantic diff")
  let graph_v2 := { id: "hello-sprint", phase: graph.Design, nodes: [{ id: "architect", role: "architect", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "build", role: "build", gate: "spec output != ''", expand: None, activate_when: "" }, { id: "qa", role: "qa", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "demo", role: "demo", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "review", role: "review", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [{ from: "architect", to: "build", handoff: "schema {}" }, { from: "build", to: "review", handoff: "schema {}" }, { from: "review", to: "qa", handoff: "schema {}" }, { from: "qa", to: "demo", handoff: "schema {}" }] }
  let d := diff.diff(sprint_graph, graph_v2)
  let rerun := diff.nodes_to_rerun(d, graph_v2)
  let __v6 := check("diff detects 1 changed + 1 added node", if diff.is_empty(d) {
    Err("diff should not be empty")
  } else {
    Ok(())
  })
  let __p4b := io.print(str.join(["  nodes to re-run: ", int.to_str(list.len(rerun)), " — ", list.fold(rerun, "", fn (a :: Str, s :: Str) -> Str {
    str.concat(a, str.concat(s, " "))
  })], ""))
  let __sf := sep()
  let __pf := io.print("done — set ANTHROPIC_API_KEY and run src/main.lex for a live sprint")
  ()
}

# Walk every legal phase transition from Intake to Digest.
fn te_msg(e :: phase.TransitionError) -> Str {
  match e {
    IllegalMove(m) => m,
    WrongEvidence(m) => m,
  }
}

fn walk_phases() -> Result[Unit, Str] {
  match phase.advance(phase.Intake, phase.Design, phase.NoEvidence) {
    Err(e) => Err(str.concat("Intake→Design: ", te_msg(e))),
    Ok(_) => match phase.advance(phase.Design, phase.Implementation, phase.GraphValidated) {
      Err(e) => Err(str.concat("Design→Impl: ", te_msg(e))),
      Ok(_) => match phase.advance(phase.Implementation, phase.QA, phase.NoEvidence) {
        Err(e) => Err(str.concat("Impl→QA: ", te_msg(e))),
        Ok(_) => match phase.advance(phase.QA, phase.Demo, phase.QaAttested) {
          Err(e) => Err(str.concat("QA→Demo: ", te_msg(e))),
          Ok(_) => match phase.advance(phase.Demo, phase.Retro, phase.NoEvidence) {
            Err(e) => Err(str.concat("Demo→Retro: ", te_msg(e))),
            Ok(_) => match phase.advance(phase.Retro, phase.Digest, phase.NoEvidence) {
              Err(e) => Err(str.concat("Retro→Digest: ", te_msg(e))),
              Ok(_) => match phase.advance(phase.Digest, phase.Intake, phase.DigestComplete) {
                Err(e) => Err(str.concat("Digest→Intake: ", te_msg(e))),
                Ok(_) => Ok(()),
              },
            },
          },
        },
      },
    },
  }
}

