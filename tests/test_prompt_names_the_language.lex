# test_prompt_names_the_language.lex — a company's prompts must SAY which
# language it builds in, not merely forbid changing it.
#
# FormCo runs on the `lex-web-api` path. Its manifest says so in [stack], in
# its mission text, and in the goal the strategist keeps rewriting. The
# strategist prompt already carried "THE STACK IS NOT YOURS TO CHANGE" (#468)
# and metaspec already refused a mismatched graph (#478) -- and the company
# still spent iteration 3 building Flask, because every guard named the RULE
# and none of them named the LANGUAGE. The architect, reading a role menu that
# offers py_build beside build and a package list that includes pytest, picked
# Python; the strategist, reading a goal that had just shipped Python, wrote
# "plus a pytest test suite" for the next two iterations running.
#
# These assert the directive is present, correct, language-specific, and
# silent on an unrecognised path -- and, with COMPANY_PATH set, that the agent
# the orchestrator actually casts carries it.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.env" as env

import "../src/roles" as roles

import "../src/role_kinds" as role_kinds

import "../src/economy_binding" as eb

import "../src/metaspec" as meta

import "../src/graph" as graph

fn expect_contains(hay :: Str, needle :: Str, what :: Str) -> Result[Unit, Str] {
  if str.contains(hay, needle) {
    Ok(())
  } else {
    Err(str.join([what, ": expected to find ", needle], ""))
  }
}

fn expect_absent(hay :: Str, needle :: Str, what :: Str) -> Result[Unit, Str] {
  if str.contains(hay, needle) {
    Err(str.join([what, ": expected NOT to find ", needle], ""))
  } else {
    Ok(())
  }
}

fn all_ok(rs :: List[Result[Unit, Str]]) -> Result[Unit, Str] {
  list.fold(rs, Ok(()), fn (acc :: Result[Unit, Str], r :: Result[Unit, Str]) -> Result[Unit, Str] {
    match acc {
      Err(e) => Err(e),
      Ok(_) => r,
    }
  })
}

# The exact live failure: a Lex company whose architect cast py_build.
fn test_lex_architect_is_told_lex_and_refused_python() -> Result[Unit, Str] {
  let p := roles.architect_system_prompt_for("lex")
  all_ok([expect_contains(p, "THIS COMPANY BUILDS IN LEX", "lex architect"), expect_contains(p, "CAST ONLY THESE BUILD ROLES: build, test_author, qa", "lex architect"), expect_contains(p, "py_build", "lex architect"), expect_contains(p, "REFUSED by metaspec", "lex architect"), expect_contains(p, "pytest", "lex architect")])
}

# The gate text `spec sh "python3 $LOOM_ROOT/bin/check_derived_values.py ."` is
# loom's own checker and appears on LEX nodes. It read as a vote for Python.
fn test_lex_architect_is_told_a_gate_is_not_a_language() -> Result[Unit, Str] {
  expect_contains(roles.architect_system_prompt_for("lex"), "is loom's own checker script", "lex architect")
}

fn test_python_architect_is_told_python_and_refused_lex() -> Result[Unit, Str] {
  let p := roles.architect_system_prompt_for("python")
  all_ok([expect_contains(p, "THIS COMPANY BUILDS IN PYTHON", "python architect"), expect_contains(p, "CAST ONLY THESE BUILD ROLES: py_build, py_test_author, py_qa", "python architect"), expect_absent(p, "THIS COMPANY BUILDS IN LEX", "python architect")])
}

fn test_node_architect_is_told_node() -> Result[Unit, Str] {
  let p := roles.architect_system_prompt_for("node")
  all_ok([expect_contains(p, "THIS COMPANY BUILDS IN NODE/TYPESCRIPT", "node architect"), expect_contains(p, "CAST ONLY THESE BUILD ROLES: ts_build, ts_test_author, ts_qa", "node architect")])
}

# An unrecognised path means no opinion -- the same contract the metaspec rule
# keeps, so a new skeleton is never told it is something it is not.
fn test_unknown_path_says_nothing() -> Result[Unit, Str] {
  if roles.architect_system_prompt_for("") == roles.architect_system_prompt() {
    if roles.strategist_system_prompt_for("") == roles.strategist_system_prompt() {
      Ok(())
    } else {
      Err("unknown path: the strategist prompt gained a directive it cannot justify")
    }
  } else {
    Err("unknown path: the architect prompt gained a directive it cannot justify")
  }
}

# The strategist wrote "plus a pytest test suite" into two consecutive goals.
fn test_lex_strategist_is_told_pytest_is_wrong() -> Result[Unit, Str] {
  let p := roles.strategist_system_prompt_for("lex")
  all_ok([expect_contains(p, "THIS COMPANY BUILDS IN LEX", "lex strategist"), expect_contains(p, "pytest", "lex strategist"), expect_contains(p, "THE STACK IS NOT YOURS TO CHANGE", "lex strategist")])
}

# The PM used to be asked for a "language preference (Python / Lex / both)",
# one layer above both of them.
fn test_pm_no_longer_picks_a_language() -> Result[Unit, Str] {
  expect_absent(roles.pm_system_prompt(), "language preference (Python / Lex / both)", "pm")
}

fn test_one_definition_of_the_path_language() -> Result[Unit, Str] {
  if role_kinds.language_of_path("lex-web-api") == "lex" {
    if eb.language_of_path("lex-web-api") == role_kinds.language_of_path("lex-web-api") {
      if role_kinds.language_of_path("python-flask") == "python" {
        if role_kinds.language_of_path("research-report") == "" {
          Ok(())
        } else {
          Err("an unknown path must classify as \"\"")
        }
      } else {
        Err("python-flask must classify as python")
      }
    } else {
      Err("economy_binding and role_kinds disagree about a path's language")
    }
  } else {
    Err("lex-web-api must classify as lex")
  }
}

# With COMPANY_PATH set, the agent the orchestrator casts must carry it: the
# pure directive being right is worth nothing if the constructor drops it.
fn test_cast_agent_carries_the_directive() -> [env] Result[Unit, Str] {
  match env.get("COMPANY_PATH") {
    None => Ok(()),
    Some(path) => {
      let lang := role_kinds.language_of_path(str.trim(path))
      if str.is_empty(lang) {
        Ok(())
      } else {
        let a := roles.architect_agent("test-model")
        let s := roles.strategist_agent("test-model")
        all_ok([expect_contains(a.system_prompt, roles.architect_language_directive(lang), "cast architect"), expect_contains(s.system_prompt, roles.language_directive(lang), "cast strategist")])
      }
    },
  }
}

fn node(id :: Str, role :: Str, gate :: Str) -> graph.Node {
  { id: id, role: role, gate: gate, expand: None, activate_when: "" }
}

fn edge(f :: Str, t :: Str) -> graph.Edge {
  { from: f, to: t, handoff: "schema {}" }
}

# A graph that is valid in every other respect, so the only thing under test is
# whether its build roles match the company's language.
fn graph_cast_as(build :: Str, ta :: Str, qa :: Str) -> graph.SprintGraph {
  { id: "lang1", phase: graph.Implementation, nodes: [node("pm", "pm", "spec non-empty"), node("b", build, "spec compiles"), node("ta", ta, "spec len-gt 50"), node("q", qa, "spec json-verdict-pass"), node("d", "demo", "spec len-gt 50")], edges: [edge("pm", "b"), edge("pm", "ta"), edge("b", "q"), edge("ta", "q"), edge("q", "d")] }
}

fn accepts(language :: Str, g :: graph.SprintGraph) -> Bool {
  match meta.check_for_company_on(g, false, false, language) {
    Valid => true,
    Invalid(_) => false,
  }
}

# The rule that refuses and the prompt that instructs must name the same three
# roles. A directive telling the architect to cast what metaspec then rejects
# is worse than no directive: it spends the sprint proving loom disagrees with
# itself (the same failure test_prompt_rules_agree.lex catches for gates).
fn language_agrees(language :: Str, mine :: graph.SprintGraph, theirs :: graph.SprintGraph) -> Result[Unit, Str] {
  if accepts(language, mine) {
    if accepts(language, theirs) {
      Err(str.join(["metaspec accepts another language's builders on a ", language, " company, so the directive forbids what the rule allows"], ""))
    } else {
      Ok(())
    }
  } else {
    Err(str.join(["metaspec refuses the very roles the ", language, " directive tells the architect to cast"], ""))
  }
}

# The three roles the directive actually names, read out of the prompt text so
# this cannot drift from what the architect is told.
fn at(l :: List[Str], i :: Int) -> Str {
  match list.head(l) {
    None => "",
    Some(h) => if i == 0 {
      h
    } else {
      at(list.tail(l), i - 1)
    },
  }
}

fn roles_named_by(language :: Str) -> List[Str] {
  let after := at(str.split(roles.architect_language_directive(language), "CAST ONLY THESE BUILD ROLES: "), 1)
  let names := at(str.split(after, "."), 0)
  list.map(str.split(names, ","), fn (n :: Str) -> Str {
    str.trim(n)
  })
}

fn graph_named_by(language :: Str) -> graph.SprintGraph {
  let r := roles_named_by(language)
  graph_cast_as(at(r, 0), at(r, 1), at(r, 2))
}

fn test_lex_directive_agrees_with_the_rule() -> Result[Unit, Str] {
  language_agrees("lex", graph_named_by("lex"), graph_named_by("python"))
}

fn test_python_directive_agrees_with_the_rule() -> Result[Unit, Str] {
  language_agrees("python", graph_named_by("python"), graph_named_by("node"))
}

fn test_node_directive_agrees_with_the_rule() -> Result[Unit, Str] {
  language_agrees("node", graph_named_by("node"), graph_named_by("lex"))
}

# A directive that names no role at all would make every agreement test above
# vacuous: "" builds a graph of empty role names, which metaspec refuses for
# other reasons entirely.
fn test_the_directive_actually_names_three_roles() -> Result[Unit, Str] {
  if list.len(roles_named_by("lex")) == 3 {
    if at(roles_named_by("lex"), 0) == "build" {
      Ok(())
    } else {
      Err("the lex directive no longer names `build` first")
    }
  } else {
    Err("the lex directive does not name exactly three build roles")
  }
}

fn run_all() -> [env, io] Int {
  let results := [("lex architect is told Lex and refused Python", test_lex_architect_is_told_lex_and_refused_python()), ("lex architect is told a gate is not a language", test_lex_architect_is_told_a_gate_is_not_a_language()), ("python architect is told Python and refused Lex", test_python_architect_is_told_python_and_refused_lex()), ("node architect is told Node", test_node_architect_is_told_node()), ("an unknown path says nothing", test_unknown_path_says_nothing()), ("lex strategist is told pytest is wrong", test_lex_strategist_is_told_pytest_is_wrong()), ("the PM no longer picks a language", test_pm_no_longer_picks_a_language()), ("one definition of a path's language", test_one_definition_of_the_path_language()), ("the cast agent carries the directive", test_cast_agent_carries_the_directive()), ("the lex directive agrees with the rule", test_lex_directive_agrees_with_the_rule()), ("the python directive agrees with the rule", test_python_directive_agrees_with_the_rule()), ("the node directive agrees with the rule", test_node_directive_agrees_with_the_rule()), ("the directive actually names three roles", test_the_directive_actually_names_three_roles())]
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

