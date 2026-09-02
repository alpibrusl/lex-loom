import "std.list" as list

import "std.str" as str

import "std.int" as int

import "../src/graph" as graph

import "../src/metaspec" as meta

import "../src/orchestrator" as orch

import "../src/role_kinds" as role_kinds

# ── Fixtures ──────────────────────────────────────────────────────────────────
fn node(id :: Str, role :: Str) -> graph.Node {
  let gate := if role == "build" {
    "spec compiles"
  } else {
    if role == "py_build" {
      "spec compiles"
    } else {
      "spec non-empty"
    }
  }
  { id: id, role: role, gate: gate, expand: None, activate_when: "" }
}

fn edge(from :: Str, to :: Str) -> graph.Edge {
  { from: from, to: to, handoff: "schema {}" }
}

fn g(id :: Str, nodes :: List[graph.Node], edges :: List[graph.Edge]) -> graph.SprintGraph {
  { id: id, phase: graph.Intake, nodes: nodes, edges: edges }
}

# ── Helpers ───────────────────────────────────────────────────────────────────
fn assert_valid(label :: Str, gr :: graph.SprintGraph) -> Result[Unit, Str] {
  match meta.check(gr) {
    Valid => Ok(()),
    Invalid(vs) => Err(str.join([label, " should be valid but got violations: ", list.fold(vs, "", fn (acc :: Str, v :: meta.Violation) -> Str {
      str.join([acc, v.rule, ": ", v.message, "; "], "")
    })], "")),
  }
}

fn assert_has_rule(label :: Str, rule :: Str, gr :: graph.SprintGraph) -> Result[Unit, Str] {
  match meta.check(gr) {
    Valid => Err(str.join([label, " should fail rule '", rule, "' but was Valid"], "")),
    Invalid(vs) => if list.fold(vs, false, fn (found :: Bool, v :: meta.Violation) -> Bool {
      if found {
        true
      } else {
        v.rule == rule
      }
    }) {
      Ok(())
    } else {
      Err(str.join([label, " expected rule '", rule, "' but violations were: ", list.fold(vs, "", fn (acc :: Str, v :: meta.Violation) -> Str {
        str.join([acc, "[", v.rule, "] "], "")
      })], ""))
    },
  }
}

# ── Tests ─────────────────────────────────────────────────────────────────────
fn test_valid_single_node() -> Result[Unit, Str] {
  assert_valid("single node", g("m1", [node("n1", "build")], []))
}

fn test_valid_qa_demo() -> Result[Unit, Str] {
  assert_valid("qa→demo", g("m2", [node("q", "qa"), node("d", "demo")], [edge("q", "d")]))
}

fn test_valid_pipeline() -> Result[Unit, Str] {
  assert_valid("build→qa→demo", g("m3", [node("b", "build"), node("ta", "test_author"), node("q", "qa"), node("d", "demo")], [edge("ta", "q"), edge("b", "q"), edge("q", "d")]))
}

fn test_empty_fails_non_empty() -> Result[Unit, Str] {
  assert_has_rule("empty graph", "non-empty", g("m4", [], []))
}

fn test_ungated_fails() -> Result[Unit, Str] {
  assert_has_rule("ungated node", "all-nodes-gated", g("m5", [{ id: "n1", role: "build", gate: "", expand: None, activate_when: "" }], []))
}

fn test_no_role_fails() -> Result[Unit, Str] {
  assert_has_rule("no role", "all-nodes-have-role", g("m6", [{ id: "n1", role: "", gate: "spec true", expand: None, activate_when: "" }], []))
}

fn test_no_handoff_fails() -> Result[Unit, Str] {
  assert_has_rule("no handoff", "all-edges-have-handoff", g("m7", [node("a", "build"), node("b", "test")], [{ from: "a", to: "b", handoff: "" }]))
}

fn test_cycle_fails_dag() -> Result[Unit, Str] {
  assert_has_rule("cycle", "dag-or-budgeted-cycle", g("m8", [node("a", "build"), node("b", "test")], [edge("a", "b"), edge("b", "a")]))
}

fn test_demo_without_qa_fails() -> Result[Unit, Str] {
  assert_has_rule("demo no qa", "qa-dominates-demo", g("m9", [node("d", "demo")], []))
}

fn test_indirect_qa_valid() -> Result[Unit, Str] {
  assert_valid("indirect qa→security→demo", g("m10", [node("b", "build"), node("ta", "test_author"), node("q", "qa"), node("r", "security"), node("d", "demo")], [edge("ta", "q"), edge("b", "q"), edge("q", "r"), edge("r", "d")]))
}

# ── #33: role-resolution + gate-well-formedness ───────────────────────────────
fn test_unknown_role_fails() -> Result[Unit, Str] {
  assert_has_rule("hallucinated role", "roles-resolve", g("m12", [node("n1", "builder")], []))
}

fn test_known_roles_pass_resolution() -> Result[Unit, Str] {
  assert_valid("launch is a known role", g("m13", [node("b", "build"), node("ta", "test_author"), node("q", "qa"), node("l", "launch"), node("d", "demo")], [edge("ta", "q"), edge("b", "q"), edge("q", "l"), edge("l", "d")]))
}

# #84/#88: distribution roles resolve — a company can now build a graph that
# markets what it shipped, not just build/QA/demo it.
fn test_distribution_roles_pass_resolution() -> Result[Unit, Str] {
  assert_valid("distribution roles are known", g("m13d", [node("b", "build"), node("ta", "test_author"), node("q", "qa"), node("d", "demo"), node("bs", "brand_strategist"), node("cw", "copywriter"), node("cc", "content_creator"), node("seo", "seo_specialist"), node("sc", "scribe")], [edge("ta", "q"), edge("b", "q"), edge("q", "d"), edge("d", "bs"), edge("bs", "cw"), edge("cw", "cc"), edge("cc", "seo"), edge("seo", "sc")]))
}

# #84/#92: finance + legal role-packs resolve — tech-agnostic business
# functions, independent of the distribution phase.
fn test_finance_legal_roles_pass_resolution() -> Result[Unit, Str] {
  assert_valid("finance/legal roles are known", g("m13e", [node("b", "build"), node("ta", "test_author"), node("q", "qa"), node("d", "demo"), node("fin", "finance"), node("leg", "legal"), node("sc", "scribe")], [edge("ta", "q"), edge("b", "q"), edge("q", "d"), edge("d", "fin"), edge("fin", "leg"), edge("leg", "sc")]))
}

# #89: monetization_handoff resolves as a known role, AND is rejected unless
# its gate is 'human <oracle>' — the one node a model must never self-certify.
fn test_monetization_handoff_resolves_with_human_gate() -> Result[Unit, Str] {
  let mh := { id: "mh", role: "monetization_handoff", gate: "human founder", expand: None, activate_when: "" }
  assert_valid("monetization_handoff with a human gate is valid", g("m13f", [node("b", "build"), node("ta", "test_author"), node("q", "qa"), node("d", "demo"), node("fin", "finance"), mh, node("sc", "scribe")], [edge("ta", "q"), edge("b", "q"), edge("q", "d"), edge("d", "fin"), edge("fin", "mh"), edge("mh", "sc")]))
}

fn test_monetization_handoff_rejects_autonomous_gate() -> Result[Unit, Str] {
  let mh := { id: "mh", role: "monetization_handoff", gate: "spec judge \"looks fine\"", expand: None, activate_when: "" }
  assert_has_rule("monetization_handoff with a judge gate is rejected", "monetization-handoff-human-gated", g("m13g", [node("b", "build"), node("q", "qa"), node("d", "demo"), mh], [edge("b", "q"), edge("q", "d"), edge("d", "mh")]))
}

fn test_unrecognized_gate_fails() -> Result[Unit, Str] {
  assert_has_rule("garbage gate", "gates-well-formed", g("m14", [{ id: "n1", role: "build", gate: "spec maybe-ok", expand: None, activate_when: "" }], []))
}

fn test_grounded_gate_is_well_formed() -> Result[Unit, Str] {
  assert_valid("spec compiles is well-formed", g("m15", [{ id: "n1", role: "build", gate: "spec compiles", expand: None, activate_when: "" }], []))
}

fn test_multiple_violations_collected() -> Result[Unit, Str] {
  match meta.check(g("m11", [node("a", "build"), node("b", "build"), node("d", "demo")], [edge("a", "b"), edge("b", "a")])) {
    Valid => Err("expected Invalid"),
    Invalid(vs) => if list.len(vs) > 1 {
      Ok(())
    } else {
      Err(str.concat("expected multiple violations, got: ", int.to_str(list.len(vs))))
    },
  }
}

fn test_expand_weak_gate_fails() -> Result[Unit, Str] {
  let expand_node := { id: "e1", role: "build", gate: "spec len-gt 10", expand: Some("sub-task"), activate_when: "" }
  assert_has_rule("expand node with len-gt gate", "expand-gate", g("m12", [expand_node], []))
}

fn test_expand_strong_gate_valid() -> Result[Unit, Str] {
  let expand_node := { id: "e1", role: "build", gate: "spec json", expand: Some("sub-task"), activate_when: "" }
  assert_valid("expand node with json gate", g("m13", [expand_node], []))
}

fn test_expand_non_empty_gate_valid() -> Result[Unit, Str] {
  let expand_node := { id: "e1", role: "build", gate: "spec non-empty", expand: Some("sub-task"), activate_when: "" }
  assert_valid("expand node with non-empty gate", g("m14", [expand_node], []))
}

# Found live (pdfx2 company run): a real Architect (kimi-k2.7-code) scoped a
# "build" node with gate 'spec sh "npm ci && npm run build"' -- hallucinating
# an entire Node/TypeScript stack for a role whose only real tool is
# lex_check against Lex source. The gate ran for real and burned a full
# iteration's spend on a real npm error, since there was never an npm
# project to begin with. build/py_build MUST use 'spec compiles'.
fn test_build_role_with_shell_gate_fails() -> Result[Unit, Str] {
  let n := { id: "n1", role: "build", gate: "spec sh \"npm ci && npm run build\"", expand: None, activate_when: "" }
  assert_has_rule("build role with a shell gate", "build-role-requires-compiles-gate", g("m16", [n], []))
}

fn test_py_build_role_with_judge_gate_fails() -> Result[Unit, Str] {
  let n := { id: "n1", role: "py_build", gate: "spec judge \"looks reasonable\"", expand: None, activate_when: "" }
  assert_has_rule("py_build role with a judge gate", "build-role-requires-compiles-gate", g("m17", [n], []))
}

fn test_build_role_with_compiles_gate_passes() -> Result[Unit, Str] {
  assert_valid("build role with the correct compiles gate", g("m18", [node("n1", "build")], []))
}

# Expand nodes recurse into a whole child sprint (rule 9 governs their gate,
# not rule 12) -- a shell gate on an expand node is NOT the same real bug.
fn test_expand_build_node_with_shell_gate_is_exempt() -> Result[Unit, Str] {
  let n := { id: "e1", role: "build", gate: "spec sh \"some real verifier\"", expand: Some("sub-task"), activate_when: "" }
  assert_valid("expand build node with a shell gate is exempt from rule 12", g("m19", [n], []))
}

# ── Suite ─────────────────────────────────────────────────────────────────────
# Found live (tzconvert reliability baseline): metaspec kept its OWN copy of
# the role list, and it drifted. `cx` and `research` had real agents, were in
# the pack registry, and were advertised to the Architect in its system prompt
# -- but were missing from metaspec's copy. The Architect did as instructed,
# added a cx node, and the whole graph was rejected: 3 attempts, the iteration
# dead at Design, no build node ever reached. These pin the two lists together.
fn test_every_registered_role_kind_is_accepted() -> Result[Unit, Str] {
  let unknown := list.filter(role_kinds.known_kinds(), fn (k :: Str) -> Bool {
    not meta.role_is_known(k)
  })
  if list.is_empty(unknown) {
    Ok(())
  } else {
    Err(str.concat("metaspec rejects roles that have real agents: ", str.join(unknown, ", ")))
  }
}

fn test_cx_and_research_specifically() -> Result[Unit, Str] {
  if meta.role_is_known("cx") {
    if meta.role_is_known("research") {
      Ok(())
    } else {
      Err("research has an agent and is advertised to the Architect; rejecting it kills the graph")
    }
  } else {
    Err("cx has an agent and is advertised to the Architect; rejecting it kills the graph")
  }
}

fn test_a_genuinely_unknown_role_is_still_rejected() -> Result[Unit, Str] {
  if meta.role_is_known("wizard") {
    Err("deriving the list must not make metaspec accept anything")
  } else {
    Ok(())
  }
}

# Found live (tzconvert baseline): the Architect paired py_build with a plain
# `qa` node -- the LEX judge -- which then ran lex_check sixty times against
# Python source and could never ground a verdict. py_qa exists, is in the
# always-staffed core pack, and has its own run_code tool; nothing enforced
# the pairing, so the wrong pick was invisible until QA had spent the sprint.
fn test_python_build_with_lex_qa_is_rejected() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "ta", role: "py_test_author", gate: "spec len-gt 50", expand: None, activate_when: "" }, { id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "q", role: "qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }], edges: [{ from: "ta", to: "q", handoff: "schema {}" }, { from: "b", to: "q", handoff: "schema {}" }] }
  match meta.check(gph) {
    Valid => Err("a Lex qa node judging a Python build must be rejected — lex_check cannot read Python"),
    Invalid(_) => Ok(()),
  }
}

fn test_python_build_with_py_qa_is_accepted() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "ta", role: "py_test_author", gate: "spec len-gt 50", expand: None, activate_when: "" }, { id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "q", role: "py_qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }, { id: "d", role: "demo", gate: "spec len-gt 50", expand: None, activate_when: "" }], edges: [{ from: "ta", to: "q", handoff: "schema {}" }, { from: "b", to: "q", handoff: "schema {}" }, { from: "q", to: "d", handoff: "schema {}" }] }
  match meta.check(gph) {
    Valid => Ok(()),
    Invalid(vs) => Err(str.concat("the correct pairing must stay valid, got: ", str.join(list.map(vs, fn (v :: meta.Violation) -> Str {
      v.message
    }), "; "))),
  }
}

# A graph building in BOTH languages is the documented DUAL LAUNCH pattern.
# The pairing is genuinely ambiguous there, so the rule must not guess.
# A dual-language graph needs an author per LANGUAGE. The sibling rules abstain
# on multi-build graphs because they cannot tell which QA belongs to which
# build; this one does not have to guess -- a Lex build and a Python build each
# need their own independent oracle.
fn test_multi_language_graph_is_left_alone() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "ta", role: "test_author", gate: "spec len-gt 50", expand: None, activate_when: "" }, { id: "ta2", role: "py_test_author", gate: "spec len-gt 50", expand: None, activate_when: "" }, { id: "b1", role: "build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "b2", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "q", role: "qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }, { id: "d", role: "demo", gate: "spec len-gt 50", expand: None, activate_when: "" }], edges: [{ from: "ta", to: "q", handoff: "schema {}" }, { from: "ta2", to: "q", handoff: "schema {}" }, { from: "b1", to: "q", handoff: "schema {}" }, { from: "b2", to: "q", handoff: "schema {}" }, { from: "q", to: "d", handoff: "schema {}" }] }
  match meta.check(gph) {
    Valid => Ok(()),
    Invalid(vs) => Err(str.concat("a dual-language graph must not trip this rule, got: ", str.join(list.map(vs, fn (v :: meta.Violation) -> Str {
      v.message
    }), "; "))),
  }
}

# Acceptance: the deliverable is checked, not the claim about it. Both false
# greens this repo produced passed every gate -- one sealed with a QA verdict
# of "11/11 tests pass" and no tests in the deliverable, another sealed after
# its build node was denied four times and wrote no file. The gates grounded
# verdicts in evidence the JUDGED PARTY produced. Acceptance re-executes what
# was SEALED, mechanically, with no model to persuade.
fn test_python_acceptance_requires_a_test_file() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }], edges: [] }
  let cmd := orch.acceptance_command(gph)
  if str.contains(cmd, "pytest") {
    if str.contains(cmd, "no test file in the sealed artifact") {
      Ok(())
    } else {
      Err("a sealed artifact with no tests must fail acceptance — that is the exact hole that let a zero-test deliverable seal")
    }
  } else {
    Err("a Python graph must be accepted by running pytest")
  }
}

fn test_lex_acceptance_requires_a_test_file() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "b", role: "build", gate: "spec compiles", expand: None, activate_when: "" }], edges: [] }
  let cmd := orch.acceptance_command(gph)
  if str.contains(cmd, "run_all") {
    if str.contains(cmd, "no test file in the sealed artifact") {
      Ok(())
    } else {
      Err("the Lex path must reject a testless artifact too")
    }
  } else {
    Err("a Lex graph must be accepted by running its test suite")
  }
}

# A stack with no acceptance runner abstains rather than inventing a pass.
# Abstaining is recorded in the trail; a fake pass would not be.
fn test_unknown_stack_abstains_rather_than_passing() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "b", role: "ts_build", gate: "spec compiles", expand: None, activate_when: "" }], edges: [] }
  if str.is_empty(orch.acceptance_command(gph)) {
    Ok(())
  } else {
    Err("a stack with no runner must abstain, not run someone else's test command")
  }
}

# Tests must be authored independently of the implementation. Found live
# (tzconvert): one build node wrote the service AND its tests. The service was
# correct -- proper zoneinfo, proper RFC 2822 formatting -- and two tests were
# wrong: an epoch an hour off, and an assertion demanding "GMT" where "+0000"
# is equally valid. Every gate then worked perfectly and refused to seal, and
# the bounce told the builder its tests failed. The rational response to that
# message is to change correct code until a wrong test passes.
#
# Independence is topological, not advisory: a test author downstream of the
# build can read the code it is meant to judge.
fn test_test_author_downstream_of_build_is_rejected() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "b", role: "build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "t", role: "test_author", gate: "spec len-gt 50", expand: None, activate_when: "" }, { id: "q", role: "qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }, { id: "d", role: "demo", gate: "spec len-gt 50", expand: None, activate_when: "" }], edges: [{ from: "b", to: "t", handoff: "schema {}" }, { from: "t", to: "q", handoff: "schema {}" }, { from: "q", to: "d", handoff: "schema {}" }] }
  match meta.check(gph) {
    Valid => Err("a test author that runs after the build can read the code it is judging — that must be rejected"),
    Invalid(_) => Ok(()),
  }
}

# The correct shape: test_author and build are SIBLINGS, both fed from the spec.
fn test_test_author_as_a_sibling_of_build_is_accepted() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "pm", role: "pm", gate: "spec len-gt 50", expand: None, activate_when: "" }, { id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "t", role: "py_test_author", gate: "spec len-gt 50", expand: None, activate_when: "" }, { id: "q", role: "py_qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }, { id: "d", role: "demo", gate: "spec len-gt 50", expand: None, activate_when: "" }], edges: [{ from: "pm", to: "b", handoff: "schema {}" }, { from: "pm", to: "t", handoff: "schema {}" }, { from: "b", to: "q", handoff: "schema {}" }, { from: "t", to: "q", handoff: "schema {}" }, { from: "q", to: "d", handoff: "schema {}" }] }
  match meta.check(gph) {
    Valid => Ok(()),
    Invalid(vs) => Err(str.concat("the sibling shape is the one we are asking for and must stay valid: ", str.join(list.map(vs, fn (v :: meta.Violation) -> Str {
      v.message
    }), "; "))),
  }
}

# A graph with no build node has nothing to be independent OF.
fn test_graph_without_a_build_is_unaffected() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "t", role: "test_author", gate: "spec len-gt 50", expand: None, activate_when: "" }], edges: [] }
  match meta.check(gph) {
    Valid => Ok(()),
    Invalid(vs) => Err(str.concat("no build means nothing to be independent of: ", str.join(list.map(vs, fn (v :: meta.Violation) -> Str {
      v.message
    }), "; "))),
  }
}

# The test author is split by language for the same reason build/py_build are:
# its tools ARE the language's tools. Measured directly against the model —
# given a Python spec and the Lex tools alongside py_check, it called
# lex_guidelines first, because that tool's own description says to call it
# FIRST before writing any Lex code. Asked to enumerate its tools it listed all
# three correctly, so this was never a perception problem; it was an
# instruction aimed at the wrong language.
fn test_python_build_with_lex_test_author_is_rejected() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "pm", role: "pm", gate: "spec len-gt 50", expand: None, activate_when: "" }, { id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "t", role: "test_author", gate: "spec len-gt 50", expand: None, activate_when: "" }, { id: "q", role: "py_qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }, { id: "d", role: "demo", gate: "spec len-gt 50", expand: None, activate_when: "" }], edges: [{ from: "pm", to: "b", handoff: "schema {}" }, { from: "pm", to: "t", handoff: "schema {}" }, { from: "b", to: "q", handoff: "schema {}" }, { from: "t", to: "q", handoff: "schema {}" }, { from: "q", to: "d", handoff: "schema {}" }] }
  match meta.check(gph) {
    Valid => Err("a Lex test author on a Python build gets Lex tools it must not use — that must be rejected"),
    Invalid(_) => Ok(()),
  }
}

fn test_python_build_with_py_test_author_is_accepted() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "pm", role: "pm", gate: "spec len-gt 50", expand: None, activate_when: "" }, { id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "t", role: "py_test_author", gate: "spec len-gt 50", expand: None, activate_when: "" }, { id: "q", role: "py_qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }, { id: "d", role: "demo", gate: "spec len-gt 50", expand: None, activate_when: "" }], edges: [{ from: "pm", to: "b", handoff: "schema {}" }, { from: "pm", to: "t", handoff: "schema {}" }, { from: "b", to: "q", handoff: "schema {}" }, { from: "t", to: "q", handoff: "schema {}" }, { from: "q", to: "d", handoff: "schema {}" }] }
  match meta.check(gph) {
    Valid => Ok(()),
    Invalid(vs) => Err(str.concat("the language-matched pairing must stay valid: ", str.join(list.map(vs, fn (v :: meta.Violation) -> Str {
      v.message
    }), "; "))),
  }
}

# Independence still applies to the Python role, not just the Lex one.
fn test_py_test_author_downstream_of_build_is_rejected() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "t", role: "py_test_author", gate: "spec len-gt 50", expand: None, activate_when: "" }, { id: "q", role: "py_qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }, { id: "d", role: "demo", gate: "spec len-gt 50", expand: None, activate_when: "" }], edges: [{ from: "b", to: "t", handoff: "schema {}" }, { from: "t", to: "q", handoff: "schema {}" }, { from: "q", to: "d", handoff: "schema {}" }] }
  match meta.check(gph) {
    Valid => Err("a Python test author that runs after the build can read the code it is judging"),
    Invalid(_) => Ok(()),
  }
}

# The evasion, exactly as it happened. tzcontract's Architect emitted three
# py_build nodes and routed test-writing to the one it NAMED "py-build-tests".
# Every rule passed, and QA judged the implementation against tests written by
# the same role that wrote it.
fn test_build_node_named_tests_does_not_count_as_an_author() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "py-build-core", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "py-build-tests", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "q", role: "py_qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }, { id: "d", role: "demo", gate: "spec len-gt 50", expand: None, activate_when: "" }], edges: [{ from: "py-build-core", to: "py-build-tests", handoff: "schema {}" }, { from: "py-build-tests", to: "q", handoff: "schema {}" }, { from: "q", to: "d", handoff: "schema {}" }] }
  match meta.check(gph) {
    Valid => Err("a build node named 'py-build-tests' is still the implementer writing its own oracle"),
    Invalid(_) => Ok(()),
  }
}

fn test_a_real_test_author_satisfies_it() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "pm", role: "pm", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "t", role: "py_test_author", gate: "spec len-gt 50", expand: None, activate_when: "" }, { id: "q", role: "py_qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }, { id: "d", role: "demo", gate: "spec len-gt 50", expand: None, activate_when: "" }], edges: [{ from: "pm", to: "b", handoff: "schema {}" }, { from: "pm", to: "t", handoff: "schema {}" }, { from: "b", to: "q", handoff: "schema {}" }, { from: "t", to: "q", handoff: "schema {}" }, { from: "q", to: "d", handoff: "schema {}" }] }
  match meta.check(gph) {
    Valid => Ok(()),
    Invalid(vs) => Err(str.concat("a build with a sibling test author and QA must be valid: ", str.join(list.map(vs, fn (v :: meta.Violation) -> Str {
      v.message
    }), "; "))),
  }
}

# A build with no QA is not being judged, so it owes no independent oracle --
# the rule must not force a test author onto every graph that compiles.
fn test_build_without_qa_needs_no_author() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "b", role: "py_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "dk", role: "docs", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [{ from: "b", to: "dk", handoff: "schema {}" }] }
  match meta.check(gph) {
    Valid => Ok(()),
    Invalid(_) => Err("a graph with no QA node is judging nothing and needs no independent author"),
  }
}

# Generality: the same requirement must reach a language the rule never names.
fn test_the_rule_reaches_typescript() -> Result[Unit, Str] {
  let gph := { id: "g", phase: graph.Implementation, nodes: [{ id: "b", role: "ts_build", gate: "spec compiles", expand: None, activate_when: "" }, { id: "q", role: "ts_qa", gate: "spec json-verdict-pass", expand: None, activate_when: "" }, { id: "d", role: "demo", gate: "spec len-gt 50", expand: None, activate_when: "" }], edges: [{ from: "b", to: "q", handoff: "schema {}" }, { from: "q", to: "d", handoff: "schema {}" }] }
  match meta.check(gph) {
    Valid => Err("a TS build judged by ts_qa with no ts_test_author must be rejected too"),
    Invalid(_) => Ok(()),
  }
}

# The contradiction, as it happened. #286 told the Architect to gate py_build
# with check_imports.py; rule 12 rejected the graph for obeying. tzauthor's
# Architect hit this and fell back to the weaker gate.
fn test_loom_verifier_shell_gate_is_allowed_on_a_build() -> Result[Unit, Str] {
  let gph := g("mv1", [node("b", "py_build"), node("ta", "py_test_author"), node("q", "py_qa"), node("d", "demo")], [edge("ta", "q"), edge("b", "q"), edge("q", "d")])
  let gated := { id: gph.id, phase: gph.phase, nodes: list.map(gph.nodes, fn (n :: graph.Node) -> graph.Node {
    if n.id == "b" {
      { id: n.id, role: n.role, gate: "spec sh \"python3 $LOOM_ROOT/bin/check_imports.py .\"", expand: n.expand, activate_when: n.activate_when }
    } else {
      n
    }
  }), edges: gph.edges }
  match meta.check(gated) {
    Valid => Ok(()),
    Invalid(vs) => Err(str.concat("a build gated by loom's own verifier must be valid: ", str.join(list.map(vs, fn (v :: meta.Violation) -> Str {
      v.message
    }), "; "))),
  }
}

# The original hazard must stay closed: a command the model invented, naming a
# stack that was never built, is still rejected.
fn test_invented_shell_command_on_a_build_is_still_rejected() -> Result[Unit, Str] {
  let gph := g("mv2", [node("b", "build"), node("ta", "test_author"), node("q", "qa"), node("d", "demo")], [edge("ta", "q"), edge("b", "q"), edge("q", "d")])
  let gated := { id: gph.id, phase: gph.phase, nodes: list.map(gph.nodes, fn (n :: graph.Node) -> graph.Node {
    if n.id == "b" {
      { id: n.id, role: n.role, gate: "spec sh \"npm ci && npm run build\"", expand: n.expand, activate_when: n.activate_when }
    } else {
      n
    }
  }), edges: gph.edges }
  match meta.check(gated) {
    Valid => Err("'npm ci' on a Lex build node hallucinates a stack that was never written — still a violation"),
    Invalid(_) => Ok(()),
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_valid_single_node(), test_valid_qa_demo(), test_valid_pipeline(), test_empty_fails_non_empty(), test_ungated_fails(), test_no_role_fails(), test_no_handoff_fails(), test_cycle_fails_dag(), test_demo_without_qa_fails(), test_indirect_qa_valid(), test_multiple_violations_collected(), test_unknown_role_fails(), test_known_roles_pass_resolution(), test_distribution_roles_pass_resolution(), test_finance_legal_roles_pass_resolution(), test_monetization_handoff_resolves_with_human_gate(), test_monetization_handoff_rejects_autonomous_gate(), test_unrecognized_gate_fails(), test_grounded_gate_is_well_formed(), test_expand_weak_gate_fails(), test_expand_strong_gate_valid(), test_expand_non_empty_gate_valid(), test_build_role_with_shell_gate_fails(), test_py_build_role_with_judge_gate_fails(), test_build_role_with_compiles_gate_passes(), test_expand_build_node_with_shell_gate_is_exempt(), test_every_registered_role_kind_is_accepted(), test_cx_and_research_specifically(), test_a_genuinely_unknown_role_is_still_rejected(), test_python_build_with_lex_qa_is_rejected(), test_python_build_with_py_qa_is_accepted(), test_multi_language_graph_is_left_alone(), test_python_acceptance_requires_a_test_file(), test_lex_acceptance_requires_a_test_file(), test_unknown_stack_abstains_rather_than_passing(), test_test_author_downstream_of_build_is_rejected(), test_test_author_as_a_sibling_of_build_is_accepted(), test_graph_without_a_build_is_unaffected(), test_python_build_with_lex_test_author_is_rejected(), test_python_build_with_py_test_author_is_accepted(), test_py_test_author_downstream_of_build_is_rejected(), test_build_node_named_tests_does_not_count_as_an_author(), test_a_real_test_author_satisfies_it(), test_build_without_qa_needs_no_author(), test_the_rule_reaches_typescript(), test_loom_verifier_shell_gate_is_allowed_on_a_build(), test_invented_shell_command_on_a_build_is_still_rejected()]
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

