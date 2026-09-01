import "std.list" as list

import "std.str" as str

import "./graph" as graph

import "./gates" as gates

import "./role_kinds" as role_kinds

# ── Types ────────────────────────────────────────────────────────────────────
# A single rule violation. Collecting all violations (not short-circuiting)
# lets the Architect fix everything in one round-trip.
type Violation = { rule :: Str, message :: Str }

type MetaspecResult = Valid | Invalid(List[Violation])

fn rule_all_nodes_gated(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
    if str.is_empty(n.gate) {
      list.concat(acc, [{ rule: "all-nodes-gated", message: str.join(["node ", n.id, " has no gate"], "") }])
    } else {
      acc
    }
  })
}

# Rule 2: every edge must carry a handoff schema (structural; also in graph.validate).
fn rule_all_edges_have_handoff(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.edges, [], fn (acc :: List[Violation], e :: graph.Edge) -> List[Violation] {
    if str.is_empty(e.handoff) {
      list.concat(acc, [{ rule: "all-edges-have-handoff", message: str.join(["edge ", e.from, "->", e.to, " has no handoff schema"], "") }])
    } else {
      acc
    }
  })
}

# Rule 3: every node must have a non-empty role.
fn rule_all_nodes_have_role(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
    if str.is_empty(n.role) {
      list.concat(acc, [{ rule: "all-nodes-have-role", message: str.join(["node ", n.id, " has empty role"], "") }])
    } else {
      acc
    }
  })
}

# Rule 4: graph must be a DAG (no unbounded cycles).
# Bounded cycles are allowed in a future extension via an iteration-budget field
# on Edge; until that field exists every cycle is a violation.
fn rule_dag(g :: graph.SprintGraph) -> List[Violation] {
  match graph.topo_sort(g) {
    Ok(_) => [],
    Err(e) => [{ rule: "dag-or-budgeted-cycle", message: e }],
  }
}

# Rule 5: every node whose role contains "demo" (case-insensitive) must be
# reachable from at least one node whose role contains "qa".
# This encodes: you cannot demo unverified work.
fn rule_qa_dominates_demo(g :: graph.SprintGraph) -> List[Violation] {
  let demo_nodes := list.fold(g.nodes, [], fn (acc :: List[graph.Node], n :: graph.Node) -> List[graph.Node] {
    if str_role_is(n.role, "demo") {
      list.concat(acc, [n])
    } else {
      acc
    }
  })
  let qa_nodes := list.fold(g.nodes, [], fn (acc :: List[graph.Node], n :: graph.Node) -> List[graph.Node] {
    if str_role_is(n.role, "qa") {
      list.concat(acc, [n])
    } else {
      if n.role == "py_qa" {
        list.concat(acc, [n])
      } else {
        if n.role == "ts_qa" {
          list.concat(acc, [n])
        } else {
          acc
        }
      }
    }
  })
  list.fold(demo_nodes, [], fn (acc :: List[Violation], demo :: graph.Node) -> List[Violation] {
    let has_qa_ancestor := list.fold(qa_nodes, false, fn (found :: Bool, qa :: graph.Node) -> Bool {
      if found {
        true
      } else {
        can_reach(g, qa.id, demo.id)
      }
    })
    if not has_qa_ancestor {
      list.concat(acc, [{ rule: "qa-dominates-demo", message: str.join(["demo node ", demo.id, " has no qa node ancestor (cannot demo unverified work)"], "") }])
    } else {
      acc
    }
  })
}

# Rule 6: graph must not be empty.
fn rule_non_empty(g :: graph.SprintGraph) -> List[Violation] {
  if list.is_empty(g.nodes) {
    [{ rule: "non-empty", message: "SprintGraph has no nodes" }]
  } else {
    []
  }
}

# ── Graph reachability helper (pure) ──────────────────────────────────────────
fn successors(g :: graph.SprintGraph, id :: Str) -> List[Str] {
  list.fold(g.edges, [], fn (acc :: List[Str], e :: graph.Edge) -> List[Str] {
    if e.from == id {
      list.concat(acc, [e.to])
    } else {
      acc
    }
  })
}

# BFS reachability — can we get from `from` to `to` following edges?
fn can_reach(g :: graph.SprintGraph, from :: Str, to :: Str) -> Bool {
  bfs(g, [from], to, [])
}

fn bfs(g :: graph.SprintGraph, frontier :: List[Str], target :: Str, visited :: List[Str]) -> Bool {
  match list.head(frontier) {
    None => false,
    Some(current) => if current == target {
      true
    } else {
      let next_visited := list.concat(visited, [current])
      let rest := graph.str_filter(frontier, fn (s :: Str) -> Bool {
        s != current
      })
      let nexts := list.fold(successors(g, current), rest, fn (acc :: List[Str], s :: Str) -> List[Str] {
        if if graph.str_contains(next_visited, s) {
          true
        } else {
          graph.str_contains(acc, s)
        } {
          acc
        } else {
          list.concat(acc, [s])
        }
      })
      bfs(g, nexts, target, next_visited)
    },
  }
}

fn str_role_is(role :: Str, keyword :: Str) -> Bool {
  str.starts_with(str.to_lower(role), keyword)
}

# ── Rule 7: every node role must resolve to a registered agent (#33) ──────────
# Hallucinated/typo'd roles (e.g. "builder", "implement") otherwise pass the
# metaspec and only fail at runtime with "unknown role" — after the design round
# is already spent. Catch them up front. Keep in sync with roles.for_role.
# Every role the Architect may put in a graph, taken from role_kinds -- the
# same list cast/roles resolve an agent from. This used to be a second,
# hand-maintained copy and it drifted: `cx` and `research` had real agents,
# were in the pack registry, and were advertised to the Architect in its own
# system prompt, but were absent here. The Architect followed its instructions,
# added a cx node, and metaspec rejected the entire graph -- three attempts,
# iteration dead at Design, never reaching a build node. Deriving it removes
# the class of bug rather than the instance.
fn known_roles() -> List[Str] {
  role_kinds.known_kinds()
}

fn role_is_known(role :: Str) -> Bool {
  list.fold(known_roles(), false, fn (found :: Bool, r :: Str) -> Bool {
    if found {
      true
    } else {
      r == role
    }
  })
}

# ── Rule 13: a QA node must speak the same language as the build it judges ───
#
# Found live (tzconvert reliability baseline): the Architect built a graph
# pairing `py_build-2` (role py_build, wrote Python via py_check) with a node
# of role `qa` -- the LEX judge. It then ran `lex check` sixty times against
# Python source, could never ground a verdict, and burned every attempt. The
# Architect's own prompt states the pattern (py_build -> py_qa, ts_build ->
# ts_qa), and py_qa exists, is in the always-staffed core pack, and has its
# own run_code tool -- nothing simply enforced the pairing, so a wrong pick
# was invisible until QA had already spent the sprint.
#
# The rule is deliberately narrow: it fires only when a graph contains builds
# of exactly one language and a QA node of a DIFFERENT one. A graph with no
# build, or with builds in several languages (the documented DUAL LAUNCH
# pattern), is left alone -- there the pairing is genuinely ambiguous and this
# check has no business guessing.
fn qa_kind_for_build(build_role :: Str) -> Str {
  if build_role == "py_build" {
    "py_qa"
  } else {
    if build_role == "ts_build" {
      "ts_qa"
    } else {
      "qa"
    }
  }
}

fn is_qa_role_kind(role :: Str) -> Bool {
  if role == "qa" {
    true
  } else {
    if role == "py_qa" {
      true
    } else {
      role == "ts_qa"
    }
  }
}

fn build_roles_in(g :: graph.SprintGraph) -> List[Str] {
  list.fold(g.nodes, [], fn (acc :: List[Str], n :: graph.Node) -> List[Str] {
    if n.role == "build" {
      if graph.str_contains(acc, n.role) {
        acc
      } else {
        list.concat(acc, [n.role])
      }
    } else {
      if n.role == "py_build" {
        if graph.str_contains(acc, n.role) {
          acc
        } else {
          list.concat(acc, [n.role])
        }
      } else {
        if n.role == "ts_build" {
          if graph.str_contains(acc, n.role) {
            acc
          } else {
            list.concat(acc, [n.role])
          }
        } else {
          acc
        }
      }
    }
  })
}

fn rule_qa_matches_build_language(g :: graph.SprintGraph) -> List[Violation] {
  let builds := build_roles_in(g)
  if list.len(builds) == 1 {
    match list.head(builds) {
      None => [],
      Some(b) => {
        let want := qa_kind_for_build(b)
        list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
          if is_qa_role_kind(n.role) {
            if n.role == want {
              acc
            } else {
              list.concat(acc, [{ rule: "qa-matches-build-language", message: str.join(["node ", n.id, " has role '", n.role, "' but this graph builds with '", b, "' -- use '", want, "', whose tools can actually read that code"], "") }])
            }
          } else {
            acc
          }
        })
      },
    }
  } else {
    []
  }
}

# ── Rule 14: tests must be authored independently of the implementation ──────
#
# A verdict grounded in "the tests pass" is worth exactly as much as the tests.
# Found live (tzconvert): the build node wrote the service AND its tests. The
# service was correct -- proper zoneinfo, proper email.utils formatting -- and
# two tests were wrong: one asserted an epoch an hour off, the other demanded
# the literal "GMT" where "+0000" is an equally valid RFC 2822 spelling. Every
# gate then worked perfectly and refused to seal, and the bounce told the
# builder its tests were failing. The rational response to that message is to
# change correct code until a wrong test passes.
#
# Independence is enforced topologically rather than by instruction: the test
# author must not have a build node as an ancestor, so it cannot have read the
# implementation it is testing. The DAG is what makes this checkable.
fn is_build_kind_role(role :: Str) -> Bool {
  if role == "build" {
    true
  } else {
    if role == "py_build" {
      true
    } else {
      role == "ts_build"
    }
  }
}

# Both test-author roles. They are split by language for the same reason
# build/py_build are: a Python task handed the Lex tools gets lex_guidelines,
# whose description tells the agent to call it FIRST before writing any Lex
# code -- measured, that is exactly what the model then did on a Python spec.
fn is_test_author_role(role :: Str) -> Bool {
  if role == "test_author" {
    true
  } else {
    if role == "py_test_author" {
      true
    } else {
      role == "ts_test_author"
    }
  }
}

# A test author must speak the language of the build it is writing tests for,
# for the same reason a QA node must: its tools are the language's tools.
fn test_author_kind_for_build(build_role :: Str) -> Str {
  if build_role == "py_build" {
    "py_test_author"
  } else {
    if build_role == "ts_build" {
      "ts_test_author"
    } else {
      "test_author"
    }
  }
}

fn rule_test_author_matches_build_language(g :: graph.SprintGraph) -> List[Violation] {
  let builds := build_roles_in(g)
  if list.len(builds) == 1 {
    match list.head(builds) {
      None => [],
      Some(b) => {
        let want := test_author_kind_for_build(b)
        list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
          if is_test_author_role(n.role) {
            if n.role == want {
              acc
            } else {
              list.concat(acc, [{ rule: "test-author-matches-build-language", message: str.join(["node ", n.id, " has role '", n.role, "' but this graph builds with '", b, "' -- use '", want, "', whose tools match that language"], "") }])
            }
          } else {
            acc
          }
        })
      },
    }
  } else {
    []
  }
}

fn rule_tests_authored_independently(g :: graph.SprintGraph) -> List[Violation] {
  let build_ids := list.fold(g.nodes, [], fn (acc :: List[Str], n :: graph.Node) -> List[Str] {
    if is_build_kind_role(n.role) {
      list.concat(acc, [n.id])
    } else {
      acc
    }
  })
  if list.is_empty(build_ids) {
    []
  } else {
    let downstream := graph.descendants(g, build_ids)
    list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
      if is_test_author_role(n.role) {
        if graph.str_contains(downstream, n.id) {
          list.concat(acc, [{ rule: "tests-authored-independently", message: str.join(["node ", n.id, " authors tests but runs downstream of the implementation, so it can read the code it is meant to judge -- give it an edge from the spec instead"], "") }])
        } else {
          acc
        }
      } else {
        acc
      }
    })
  }
}

# A graph that builds AND judges must have someone independent writing what it
# is judged against.
#
# tests-authored-independently only fires when a test author is PRESENT: it
# checks that the author is not downstream of the build. It says nothing about
# a graph with no test author at all. Found live (tzcontract): the Architect
# emitted three py_build nodes -- py-build-core, py-build-tests, py-build-app --
# and routed test-writing to the one it NAMED "py-build-tests". Role py_build.
# Every rule passed. The independent-test-author design, the language-matching
# rule and the role's deliverable contract were all bypassed by naming a build
# node after the job, and QA then judged an implementation against tests its own
# author wrote -- the exact failure that cost three iterations in the run that
# prompted building the test author in the first place.
#
# Language-parameterised: the required role comes from test_author_kind_for_build,
# whose totality over build kinds is guarded in tests/test_role_contracts.lex, so
# a new language inherits this rule rather than escaping it.
fn rule_tests_have_an_independent_author(g :: graph.SprintGraph) -> List[Violation] {
  if not graph.has_qa_node(g) {
    []
  } else {
    list.fold(build_roles_in(g), [], fn (acc :: List[Violation], b :: Str) -> List[Violation] {
      let want := test_author_kind_for_build(b)
      let present := list.fold(g.nodes, false, fn (found :: Bool, n :: graph.Node) -> Bool {
        if found {
          true
        } else {
          n.role == want
        }
      })
      if present {
        acc
      } else {
        list.concat(acc, [{ rule: "tests-have-an-independent-author", message: str.join(["this graph builds with '", b, "' and has a QA node, but no '", want, "' node -- QA would judge the implementation against tests written by whoever wrote it. Naming a build node 'build-tests' does not make its author independent: add a ", want, " node fed from the spec, in parallel with the build"], "") }])
      }
    })
  }
}

fn rule_roles_resolve(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
    if str.is_empty(n.role) {
      acc
    } else {
      if role_is_known(n.role) {
        acc
      } else {
        list.concat(acc, [{ rule: "roles-resolve", message: str.join(["node ", n.id, " has unknown role '", n.role, "' (no registered agent)"], "") }])
      }
    }
  })
}

# ── Rule 8: every gate must be a recognized expression (#32/#33) ──────────────
# An unrecognized gate silently falls back to the non-empty check in
# gates.evaluate — a silent-allow that defeats predictability. Reject up front.
fn rule_gates_well_formed(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
    if str.is_empty(n.gate) {
      acc
    } else {
      if gates.is_well_formed(n.gate) {
        acc
      } else {
        list.concat(acc, [{ rule: "gates-well-formed", message: str.join(["node ", n.id, " has unrecognized gate '", n.gate, "' (would silently fall back to non-empty)"], "") }])
      }
    }
  })
}

# ── Rule 9: expand nodes must use a gatable gate (#35) ───────────────────────
# An expand node runs a full child sprint; its gate is evaluated against the
# child sprint result JSON. It must use a real gate (not len-gt which is a
# vibe check) so the expansion is honestly auditable.
fn rule_expand_gates(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
    match n.expand {
      None => acc,
      Some(_) => if str.starts_with(n.gate, "spec len-gt") {
        list.concat(acc, [{ rule: "expand-gate", message: str.join(["expand node ", n.id, " uses weak gate '", n.gate, "' — use 'spec json' or stronger"], "") }])
      } else {
        acc
      },
    }
  })
}

# ── Rule 10: 'spec compiles' only means something for build/py_build (#21) ───
# `spec compiles` runs the real compiler against work_dir_for(role) — but only
# build/py_build ever write files there via a tool (lex_check/py_check). Every
# other role (ux_designer, docs, devops, ...) just returns prose in its final
# answer; nothing is ever persisted for the compiler to check, so the gate
# fails FOREVER, burning every retry with no informative error. Found live: an
# e2e sprint graph where the architect (a weaker local model) tagged a
# ux_designer spec node with 'spec compiles', bouncing the whole phase 4 times
# before the sprint failed. Catch this at graph-validation time — cheap — so
# the architect is told to fix the graph before any node ever runs.
fn rule_compiles_gate_matches_role(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
    if str.trim(n.gate) == "spec compiles" {
      if n.role == "build" {
        acc
      } else {
        if n.role == "py_build" {
          acc
        } else {
          if n.role == "ts_build" {
            acc
          } else {
            list.concat(acc, [{ rule: "compiles-gate-matches-role", message: str.join(["node ", n.id, " (role '", n.role, "') uses gate 'spec compiles', but only build/py_build/ts_build nodes write files a compiler can check — this role's output is never persisted, so the gate can never pass. Use 'spec judge \"...\"' or 'spec len-gt N' instead."], "") }])
          }
        }
      }
    } else {
      acc
    }
  })
}

# ── Rule 12: build/py_build MUST use 'spec compiles' (#pdfx2 follow-up) ──────
# The inverse of rule_compiles_gate_matches_role (rule 10): that rule stops
# OTHER roles from using 'spec compiles'; nothing stopped build/py_build from
# using something else. Found live: a real Architect run (kimi-k2.7-code)
# scoped a "build" node with gate 'spec sh "npm ci && npm run build"' —
# hallucinating an entire Node/TypeScript stack for a role whose only real
# tool is lex_check against Lex source, on a manifest whose stack.path is
# lex-x402-api. The gate ran for real, failed with a real npm error (no
# package-lock.json — there was never an npm project to begin with), and
# burned a full iteration's spend before the Strategist could react. build
# and py_build are the ONLY roles with a tool that persists files a real
# compiler can check (lex_check/py_check) — no other gate is meaningful for
# them, so require it structurally rather than trusting the model to notice.
# Expand nodes are exempt: they recurse into a whole child sprint instead of
# persisting a file a compiler can check, and rule 9 (expand-gate) already
# governs their gate ('spec json' or stronger).
fn rule_build_role_requires_compiles_gate(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
    let is_build_role := if n.role == "build" {
      true
    } else {
      if n.role == "py_build" {
        true
      } else {
        n.role == "ts_build"
      }
    }
    let applies := if is_build_role {
      match n.expand {
        None => true,
        Some(_) => false,
      }
    } else {
      false
    }
    if applies {
      if str.trim(n.gate) == "spec compiles" {
        acc
      } else {
        list.concat(acc, [{ rule: "build-role-requires-compiles-gate", message: str.join(["node ", n.id, " (role '", n.role, "') uses gate '", n.gate, "', but build/py_build/ts_build MUST use 'spec compiles' — these roles only have a tool (lex_check/py_check/ts_check) that persists files a real compiler can check; any other gate (including 'spec sh') has no real verifier behind it and can hallucinate an entirely different tech stack (e.g. npm/Node) with no actual project ever written."], "") }])
      }
    } else {
      acc
    }
  })
}

# ── Rule 11: monetization_handoff must never be self-certified (#89) ─────────
# The one node in the whole graph a model must never attest itself: it hands
# off creating a real payment/product integration to a human. A `spec judge`
# or any autonomous gate here would let the model decide monetization is
# "shipped" on its own say-so — exactly what this role exists to prevent.
# Enforced structurally, not just by prompt instruction, matching this
# codebase's own attestation-ladder philosophy (grounded > judge > human):
# if the model's prompt-following slips, the graph is rejected outright.
fn rule_monetization_handoff_is_human_gated(g :: graph.SprintGraph) -> List[Violation] {
  list.fold(g.nodes, [], fn (acc :: List[Violation], n :: graph.Node) -> List[Violation] {
    if n.role == "monetization_handoff" {
      if gates.is_judgeable(n.gate) {
        acc
      } else {
        list.concat(acc, [{ rule: "monetization-handoff-human-gated", message: str.join(["node ", n.id, " (role 'monetization_handoff') uses gate '", n.gate, "', but this role must NEVER be self-certified — its gate must be 'human <oracle>' (e.g. 'human founder')."], "") }])
      }
    } else {
      acc
    }
  })
}

# ── Public API ────────────────────────────────────────────────────────────────
fn check(g :: graph.SprintGraph) -> MetaspecResult
  examples {
    check({ id: "g0", phase: graph.Intake, nodes: [{ id: "n1", role: "docs", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [] }) => Valid,
    check({ id: "g1", phase: graph.Intake, nodes: [], edges: [] }) => Invalid([{ rule: "non-empty", message: "SprintGraph has no nodes" }]),
    check({ id: "g2", phase: graph.QA, nodes: [{ id: "d", role: "demo", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [] }) => Invalid([{ rule: "qa-dominates-demo", message: "demo node d has no qa node ancestor (cannot demo unverified work)" }]),
    check({ id: "g3", phase: graph.QA, nodes: [{ id: "q", role: "qa", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "d", role: "demo", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [{ from: "q", to: "d", handoff: "schema {}" }] }) => Valid,
    check({ id: "g4", phase: graph.Intake, nodes: [{ id: "a", role: "docs", gate: "spec non-empty", expand: None, activate_when: "" }, { id: "b", role: "qa", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [{ from: "a", to: "b", handoff: "schema {}" }, { from: "b", to: "a", handoff: "schema {}" }] }) => Invalid([{ rule: "dag-or-budgeted-cycle", message: "cycle detected in SprintGraph — add an iteration budget to allow bounded cycles" }]),
    check({ id: "g5", phase: graph.Intake, nodes: [{ id: "n1", role: "builder", gate: "spec non-empty", expand: None, activate_when: "" }], edges: [] }) => Invalid([{ rule: "roles-resolve", message: "node n1 has unknown role 'builder' (no registered agent)" }]),
    check({ id: "g6", phase: graph.Intake, nodes: [{ id: "n1", role: "docs", gate: "spec maybe-ok", expand: None, activate_when: "" }], edges: [] }) => Invalid([{ rule: "gates-well-formed", message: "node n1 has unrecognized gate 'spec maybe-ok' (would silently fall back to non-empty)" }]),
    check({ id: "g7", phase: graph.Intake, nodes: [{ id: "n1", role: "ux_designer", gate: "spec compiles", expand: None, activate_when: "" }], edges: [] }) => Invalid([{ rule: "compiles-gate-matches-role", message: "node n1 (role 'ux_designer') uses gate 'spec compiles', but only build/py_build/ts_build nodes write files a compiler can check — this role's output is never persisted, so the gate can never pass. Use 'spec judge \"...\"' or 'spec len-gt N' instead." }]),
    check({ id: "g8", phase: graph.Intake, nodes: [{ id: "n1", role: "monetization_handoff", gate: "spec judge \"looks good\"", expand: None, activate_when: "" }], edges: [] }) => Invalid([{ rule: "monetization-handoff-human-gated", message: "node n1 (role 'monetization_handoff') uses gate 'spec judge \"looks good\"', but this role must NEVER be self-certified — its gate must be 'human <oracle>' (e.g. 'human founder')." }]),
    check({ id: "g9", phase: graph.Intake, nodes: [{ id: "n1", role: "build", gate: "spec sh \"npm ci && npm run build\"", expand: None, activate_when: "" }], edges: [] }) => Invalid([{ rule: "build-role-requires-compiles-gate", message: "node n1 (role 'build') uses gate 'spec sh \"npm ci && npm run build\"', but build/py_build/ts_build MUST use 'spec compiles' — these roles only have a tool (lex_check/py_check/ts_check) that persists files a real compiler can check; any other gate (including 'spec sh') has no real verifier behind it and can hallucinate an entirely different tech stack (e.g. npm/Node) with no actual project ever written." }])
  }
{
  let violations := list.fold([rule_non_empty(g), rule_all_nodes_have_role(g), rule_all_nodes_gated(g), rule_all_edges_have_handoff(g), rule_dag(g), rule_qa_dominates_demo(g), rule_roles_resolve(g), rule_gates_well_formed(g), rule_expand_gates(g), rule_compiles_gate_matches_role(g), rule_build_role_requires_compiles_gate(g), rule_monetization_handoff_is_human_gated(g), rule_qa_matches_build_language(g), rule_tests_authored_independently(g), rule_test_author_matches_build_language(g), rule_tests_have_an_independent_author(g)], [], fn (acc :: List[Violation], vs :: List[Violation]) -> List[Violation] {
    list.concat(acc, vs)
  })
  if list.is_empty(violations) {
    Valid
  } else {
    Invalid(violations)
  }
}

