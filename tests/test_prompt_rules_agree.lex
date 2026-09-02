# test_prompt_rules_agree.lex — loom must not tell the Architect to do something
# loom then rejects it for doing.
#
# Found live twice, both self-inflicted. #286 added bin/check_imports.py and
# documented it to the Architect as "strictly stronger than 'spec compiles' --
# use this on py_build whenever a launch or deploy node is in the graph". Rule
# 12 required build nodes to use 'spec compiles' and nothing else. tzauthor's
# Architect followed the instruction, had its graph rejected for it, and fell
# back to the weaker gate -- so the verifier built to catch an unimportable
# module could not be used on the node that produces one. Separately, the
# STANDARD GRAPH PATTERN examples showed build -> qa -> demo while the same
# prompt's doctrine demanded a parallel test author, and the examples won.
#
# A model reading two of our instructions that disagree will follow one and be
# punished by the other, and the trace blames the model. This asserts the
# agreement mechanically: every verifier the Architect prompt recommends must
# survive metaspec on a real graph.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "../src/roles" as roles

import "../src/metaspec" as meta

import "../src/graph" as graph

fn node(id :: Str, role :: Str, gate :: Str) -> graph.Node {
  { id: id, role: role, gate: gate, expand: None, activate_when: "" }
}

fn edge(f :: Str, t :: Str) -> graph.Edge {
  { from: f, to: t, handoff: "schema {}" }
}

# Every "$LOOM_ROOT/bin/<tool>" the Architect prompt names, in the order it
# names them.
fn recommended_verifiers() -> [env] List[Str] {
  let parts := str.split(roles.architect_system_prompt(), "$LOOM_ROOT/bin/")
  list.filter(list.map(list.tail(parts), fn (p :: Str) -> Str {
    match list.head(str.split(p, " ")) {
      None => "",
      Some(tok) => str.trim(tok),
    }
  }), fn (t :: Str) -> Bool {
    str.ends_with(t, ".py")
  })
}

fn gate_for(tool :: Str) -> Str {
  str.join(["spec sh \"python3 $LOOM_ROOT/bin/", tool, " .\""], "")
}

# A minimal graph that is valid in every other respect, so the only thing under
# test is whether the recommended gate is accepted.
fn graph_with_build_gate(gate :: Str) -> graph.SprintGraph {
  { id: "pr1", phase: graph.Implementation, nodes: [node("pm", "pm", "spec non-empty"), node("b", "py_build", gate), node("ta", "py_test_author", "spec len-gt 50"), node("q", "py_qa", "spec json-verdict-pass"), node("d", "demo", "spec len-gt 50")], edges: [edge("pm", "b"), edge("pm", "ta"), edge("b", "q"), edge("ta", "q"), edge("q", "d")] }
}

fn test_every_recommended_verifier_is_accepted() -> [env, io] Result[Unit, Str] {
  let tools := recommended_verifiers()
  if list.is_empty(tools) {
    Err("the Architect prompt names no verifier at all — either the prompt lost them or this test stopped finding them")
  } else {
    list.fold(tools, Ok(()), fn (acc :: Result[Unit, Str], t :: Str) -> Result[Unit, Str] {
      match acc {
        Err(e) => Err(e),
        Ok(_) => match meta.check(graph_with_build_gate(gate_for(t))) {
          Valid => Ok(()),
          Invalid(vs) => Err(str.join(["the prompt recommends ", t, " but metaspec rejects a graph using it: ", str.join(list.map(vs, fn (v :: meta.Violation) -> Str {
            v.rule
          }), ",")], "")),
        },
      }
    })
  }
}

# Every verifier the prompt names must actually exist on disk — a prompt that
# recommends a tool we deleted sends the Architect to a gate that always fails.
fn test_every_recommended_verifier_exists() -> [env, io, proc] Result[Unit, Str] {
  list.fold(recommended_verifiers(), Ok(()), fn (acc :: Result[Unit, Str], t :: Str) -> [proc] Result[Unit, Str] {
    match acc {
      Err(e) => Err(e),
      Ok(_) => match proc.run("bash", ["-c", str.concat("test -f bin/", t)]) {
        Err(_) => Err(str.concat("could not check for bin/", t)),
        Ok(r) => if r.exit_code == 0 {
          Ok(())
        } else {
          Err(str.concat("the Architect prompt recommends a verifier that does not exist: bin/", t))
        },
      },
    }
  })
}

# The prompt's own worked examples must satisfy the rules the prompt is checked
# against. The STANDARD GRAPH PATTERN showed build → qa → demo for months while
# the doctrine three paragraphs above demanded a parallel test author.
fn test_the_documented_standard_pattern_is_valid() -> Result[Unit, Str] {
  let g := { id: "pr2", phase: graph.Implementation, nodes: [node("pm", "pm", "spec non-empty"), node("b", "build", "spec compiles"), node("ta", "test_author", "spec len-gt 50"), node("q", "qa", "spec json-verdict-pass"), node("l", "launch", "spec json-ok-true"), node("d", "demo", "spec len-gt 50"), node("s", "scribe", "spec len-gt 50")], edges: [edge("pm", "b"), edge("pm", "ta"), edge("b", "q"), edge("ta", "q"), edge("q", "l"), edge("l", "d"), edge("d", "s")] }
  match meta.check(g) {
    Valid => Ok(()),
    Invalid(vs) => Err(str.join(["the pattern the prompt tells the Architect to follow is rejected by our own rules: ", str.join(list.map(vs, fn (v :: meta.Violation) -> Str {
      v.rule
    }), ",")], "")),
  }
}

fn run_all() -> [env, io, proc] Int {
  let results := [("every recommended verifier is accepted", test_every_recommended_verifier_is_accepted()), ("every recommended verifier exists", test_every_recommended_verifier_exists()), ("the documented standard pattern is valid", test_the_documented_standard_pattern_is_valid())]
  list.fold(results, 0, fn (fails :: Int, r :: (Str, Result[Unit, Str])) -> [io] Int {
    match r {
      (name, Ok(_)) => {
        let __ := io.print(str.concat("ok   ", name))
        fails
      },
      (name, Err(e)) => {
        let __ := io.print(str.join(["FAIL ", name, ": ", e], ""))
        fails + 1
      },
    }
  })
}

