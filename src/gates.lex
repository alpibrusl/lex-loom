# gates.lex — Gate DSL: maps gate strings to real lex-spec evaluations.
#
# The Node.gate field is a Str that the Architect emits. This module
# parses a small DSL and evaluates it against node output using sp.Spec
# and ev.eval — replacing the M1–M5 stub that only checked non-empty.
#
# Supported gate expressions:
#   "spec non-empty"          output must not be empty string
#   "spec contains X"         output must contain literal X
#   "spec not-contains X"     output must not contain X
#   "spec starts-with X"      output must start with X
#   "spec json"               output must be valid JSON
#   "spec json-ok-true"       output must be JSON with an "ok" field equal to boolean true
#   "spec json-field K"       output must be JSON with field K present
#   "spec len-gt N"           output length must be > N chars
#
# Unknown gate strings fall back to the non-empty check (safe default).
# Inconclusive is treated as Deny (never a silent allow).

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "lex-spec/src/spec" as sp

import "lex-spec/src/eval" as ev

import "lex-schema/json_value" as jv

# ── Verification lane ─────────────────────────────────────────────────────────
#
# Formal     — deterministic predicate; self-seals with no human involvement.
# Testable   — example/property based; eligible for spot-check sampling.
# Judgeable  — only a named oracle (human) can attest; cannot auto-seal.
#
# Gate syntax for each lane:
#   Formal   : "spec <expr>"          (all existing spec predicates)
#   Grounded : "spec compiles"        (runs a real tool; verdict from tool result)
#   Judgeable: "human <oracle-name>"  (product, tech-lead, security, …)
#   Testable : anything else          (future: "test <suite>")
#
# Grounded gates (#32) are the predictability primitive: instead of asserting a
# property of the output STRING (length, substring), they execute a tool against
# the produced artifacts and take the verdict from ground truth. They require
# effects, so they are evaluated on a separate effectful path (evaluate_grounded
# below + the orchestrator), never in the pure `evaluate`.
type Lane = Formal | Testable | Judgeable(Str)

fn is_grounded(gate :: Str) -> Bool {
  str.trim(gate) == "spec compiles"
}

# `spec json-verdict-pass` is grounded too (#/py_qa self-attestation gap):
# the orchestrator additionally requires real run_code evidence agreeing
# with the claimed verdict (runner.verify_json_verdict_evidence), rather
# than trusting the agent's self-reported "verdict" string alone. That
# evidence check only compares a boolean pass/fail against the LAST
# run_code call, though, so it can't by itself catch a PASS claimed after
# a trivial, unrelated run_code call happened to pass. `evaluate` below
# closes the cheapest version of that gap in the pure layer: a PASS
# verdict whose own output text admits the roles.lex "[MISSING_DEPENDENCY]"
# sentinel is self-contradictory (found live: py_qa hit a real
# ModuleNotFoundError, then still emitted PASS reasoning the code "would
# pass in a [missing-package] environment") and is denied outright.
fn is_json_verdict_pass(gate :: Str) -> Bool {
  str.trim(gate) == "spec json-verdict-pass"
}

# True iff `gate` is a recognized gate expression — i.e. `evaluate` has a real
# rule for it and will NOT silently fall back to the non-empty default. The
# metaspec uses this (#33) to reject graphs whose gates would otherwise pass on
# a silent-allow. Keep in sync with the branches in `evaluate` below.
fn is_well_formed(gate :: Str) -> Bool {
  let g := str.trim(gate)
  if g == "spec non-empty" {
    true
  } else {
    if g == "spec compiles" {
      true
    } else {
      if g == "spec json" {
        true
      } else {
        if g == "spec json-ok-true" {
          true
        } else {
          if g == "spec json-verdict-pass" {
            true
          } else {
            let has_arg := fn (prefix :: Str) -> Bool {
              if str.starts_with(g, prefix) {
                str.len(str.trim(str.slice(g, str.len(prefix), str.len(g)))) > 0
              } else {
                false
              }
            }
            if has_arg("spec contains ") {
              true
            } else {
              if has_arg("spec not-contains ") {
                true
              } else {
                if has_arg("spec starts-with ") {
                  true
                } else {
                  if has_arg("spec json-field ") {
                    true
                  } else {
                    if has_arg("spec len-gt ") {
                      true
                    } else {
                      if has_arg("spec judge ") {
                        true
                      } else {
                        if has_arg("spec sh ") {
                          true
                        } else {
                          has_arg("human ")
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

fn classify(gate :: Str) -> Lane {
  let trimmed := str.trim(gate)
  if str.starts_with(trimmed, "spec ") {
    Formal
  } else {
    if str.starts_with(trimmed, "human ") {
      let rest := str.trim(str.slice(trimmed, 6, str.len(trimmed)))
      let oracle := match list.head(str.split(rest, " ")) {
        None => rest,
        Some(first) => first,
      }
      if str.is_empty(oracle) {
        Testable
      } else {
        Judgeable(oracle)
      }
    } else {
      Testable
    }
  }
}

# ── Blocking human gates (GOV1, lex-loom#221) ─────────────────────────────────
# `human <oracle>` stays advisory (attest immediately, seal later — unchanged).
# `human <oracle> blocking` PARKS the dependent subtree until the oracle
# resolves the attention item; downstream work waits, independent tracks
# continue. An optional trailing `<N>h` declares a timeout after which the
# scheduler escalates the still-pending gate (it never auto-approves):
#   human legal blocking        — block until resolved
#   human legal blocking 48h    — block; escalate if still pending after 48h
fn is_blocking(gate :: Str) -> Bool {
  let trimmed := str.trim(gate)
  if str.starts_with(trimmed, "human ") {
    let toks := list.filter(str.split(trimmed, " "), fn (t :: Str) -> Bool {
      not str.is_empty(str.trim(t))
    })
    match list.head(list.tail(list.tail(toks))) {
      Some(t) => t == "blocking",
      None => false,
    }
  } else {
    false
  }
}

# Declared escalation timeout in hours; 0 when none (or not a blocking gate).
fn blocking_timeout_hours(gate :: Str) -> Int {
  if is_blocking(gate) {
    let toks := list.filter(str.split(str.trim(gate), " "), fn (t :: Str) -> Bool {
      not str.is_empty(str.trim(t))
    })
    match list.head(list.tail(list.tail(list.tail(toks)))) {
      None => 0,
      Some(t) => match str.strip_suffix(t, "h") {
        None => 0,
        Some(n_str) => match str.to_int(n_str) {
          None => 0,
          Some(n) => if n > 0 {
            n
          } else {
            0
          },
        },
      },
    }
  } else {
    0
  }
}

fn is_judgeable(gate :: Str) -> Bool {
  match classify(gate) {
    Judgeable(_) => true,
    _ => false,
  }
}

fn oracle_of(gate :: Str) -> Str {
  match classify(gate) {
    Judgeable(oracle) => oracle,
    _ => "",
  }
}

# ── LLM-judge lane (attestation tier between formal checks and a human) ────────
# `spec judge <criteria>` runs an evaluator LLM against the artifact + criteria
# and takes the verdict from its structured PASS/FAIL — autonomous, scalable, and
# cheaper than a human. Use it for subjective deliverables (copy, design specs,
# legal prose) that have no executable oracle, instead of escalating straight to
# a human `human <oracle>` gate. The orchestrator handles this on the effectful
# path (it needs [llm]); `evaluate` never sees it.
fn is_llm_judge(gate :: Str) -> Bool {
  str.starts_with(str.trim(gate), "spec judge ")
}

fn judge_criteria(gate :: Str) -> Str {
  let g := str.trim(gate)
  if str.starts_with(g, "spec judge ") {
    str.trim(str.slice(g, 11, str.len(g)))
  } else {
    ""
  }
}

# ── Grounded TOOL gate: `spec sh "<command>"` ─────────────────────────────────
# The general grounding primitive — run any verifier against the node's produced
# files; pass iff it exits 0. Grounds every technical domain with one mechanism:
#   devops:    spec sh "docker build -t app ."
#   security:  spec sh "semgrep --error --quiet ." / spec sh "gitleaks detect --no-git"
#   ml:        spec sh "python eval.py --min-f1 0.85"
#   analytics: spec sh "dbt test"
# Evaluated on the effectful path (needs [proc]); `evaluate` never sees it.
fn is_shell_gate(gate :: Str) -> Bool {
  str.starts_with(str.trim(gate), "spec sh ")
}

# Extract the command, stripping one layer of surrounding double quotes.
fn shell_command(gate :: Str) -> Str {
  let g := str.trim(gate)
  if str.starts_with(g, "spec sh ") {
    let raw := str.trim(str.slice(g, 8, str.len(g)))
    if str.starts_with(raw, "\"") {
      if str.ends_with(raw, "\"") {
        str.slice(raw, 1, str.len(raw) - 1)
      } else {
        raw
      }
    } else {
      raw
    }
  } else {
    ""
  }
}

# ── Verdict type ──────────────────────────────────────────────────────────────
type GateVerdict = GateAllow | GateDeny(Str)

fn from_spec_verdict(v :: sp.Verdict) -> GateVerdict {
  match v {
    Allow => GateAllow,
    Deny(reason) => GateDeny(reason),
    Inconclusive(r) => GateDeny(str.concat("inconclusive (treated as deny): ", r)),
  }
}

# ── Built-in Spec values ──────────────────────────────────────────────────────
fn spec_non_empty() -> sp.Spec {
  { name: "non-empty", quantifiers: [sp.QStr("output")], predicate: sp.EBinop({ op: sp.op_neq(), lhs: sp.EVar("output"), rhs: sp.EConst(sp.VStr("")) }) }
}

fn spec_len_gt(n :: Int) -> sp.Spec {
  spec_non_empty()
}

# Linear extraction of the `verdict` string from a QA agent's JSON-ish output.
# We deliberately AVOID jv.parse here: lex-schema's parser is O(n²) and QA output
# embeds large lex_check/lex_run tool results, which blows the VM's 10M-step
# limit (par_map worker panic). str.split is linear. Returns the value of the
# first "verdict" field, or None.
#
# TODO(v0.9.13): lex-schema #19 makes jv.parse O(n) (via str.char_at, lex
# v0.9.13). Once loom's toolchain is on v0.9.13 + that lex-schema, this and the
# orchestrator's delimiter bounce envelope can revert to plain jv.parse.
# The verdict is compared case-insensitively. A model that answers "pass"
# instead of "PASS" is agreeing, not failing, and denying it forever over
# casing wastes a whole iteration -- observed live (tzlocal2 iter-2), where
# "verdict is 'pass', expected 'PASS'" sank an otherwise fine node.
fn extract_verdict(output :: Str) -> Option[Str] {
  let after_key := str.split(output, "\"verdict\"")
  match list.head(list.tail(after_key)) {
    None => None,
    Some(after) => {
      let segs := str.split(after, "\"")
      list.head(list.tail(segs))
    },
  }
}

# Models routinely wrap a correct JSON answer in prose or a ```json fence,
# and the raw-output parse then denies a node whose payload was fine. Found
# live: a launch node denied 4 attempts running with "trailing characters
# after JSON value" while emitting exactly the object its gate asked for.
# This narrows the output to its JSON body before parsing -- first a fenced
# block, else the span from the first '{' to the last '}'. It does not weaken
# any gate: whatever is recovered must still parse and still carry the
# required fields.
# A model that writes a tool call as TEXT did not call the tool. Observed live
# on a launch node: {"ok":true,...,"response":"","pid":""} followed by
# <function_calls><invoke name="run_server">... -- a claimed success, an empty
# response, and the call it claimed to have made sitting there unmade.
# Accepting that JSON manufactures a green launch out of a model narrating its
# intentions, so it is denied with the real reason rather than a parse error.
fn contains_text_tool_call(output :: Str) -> Bool {
  if str.contains(output, "<function_calls>") {
    true
  } else {
    str.contains(output, "<invoke")
  }
}

# The FIRST balanced JSON object. json_payload spans first "{" to last "}",
# which is right for one object in prose and wrong the moment a second object
# or a brace-bearing tool call follows: the span covers both and parses as
# neither. This walks the "}" boundaries and returns the first prefix that
# actually parses, so trailing junk is ignored rather than swallowed.
fn first_json_object(candidate :: Str) -> Str {
  let opened := str.split(candidate, "{")
  if list.len(opened) < 2 {
    ""
  } else {
    let body := str.concat("{", str.join(list.tail(opened), "{"))
    let parts := str.split(body, "}")
    list.fold(list.range(0, list.len(parts)), "", fn (found :: Str, i :: Int) -> Str {
      if str.is_empty(found) {
        let prefix := str.concat(str.join(take_n(parts, i + 1), "}"), "}")
        match jv.parse(prefix) {
          Ok(_) => prefix,
          Err(_) => found,
        }
      } else {
        found
      }
    })
  }
}

fn take_n(xs :: List[Str], n :: Int) -> List[Str] {
  match list.fold(xs, (0, []), fn (acc :: (Int, List[Str]), x :: Str) -> (Int, List[Str]) {
    match acc {
      (i, out) => if i < n {
        (i + 1, list.concat(out, [x]))
      } else {
        (i + 1, out)
      },
    }
  }) {
    (_, out) => out,
  }
}

fn json_payload(output :: Str) -> Str {
  let balanced := first_json_object(output)
  if not str.is_empty(balanced) {
    balanced
  } else {
    let fenced := str.split(output, "```")
    let candidate := if list.len(fenced) > 2 {
      match list.head(list.tail(fenced)) {
        None => output,
        Some(block) => {
          let nl := str.split(block, "\n")
          match list.head(nl) {
            None => block,
            Some(first) => if str.contains(first, "{") {
              block
            } else {
              str.join(list.tail(nl), "\n")
            },
          }
        },
      }
    } else {
      output
    }
    let opened := str.split(candidate, "{")
    if list.len(opened) < 2 {
      str.trim(candidate)
    } else {
      let body := str.join(list.tail(opened), "{")
      let closed := str.split(body, "}")
      if list.len(closed) < 2 {
        str.trim(candidate)
      } else {
        let inner := str.join(list.reverse(list.tail(list.reverse(closed))), "}")
        str.join(["{", inner, "}"], "")
      }
    }
  }
}

# ── Gate DSL parser + evaluator ───────────────────────────────────────────────
# Gates whose output is a machine-readable CLAIM about something the node did:
# a launch that started a server, a deploy that shipped, a QA verdict about a
# test run. For these a tool call written as text is decisive -- the claim is
# about an action, and the evidence the action happened is exactly what is
# missing.
#
# Prose gates are deliberately excluded. A docs or scribe node may legitimately
# write "<invoke" while explaining a tool, and denying that would be a false
# positive on the one kind of node whose job is to describe things.
fn is_structured_claim_gate(gate :: Str) -> Bool {
  let g := str.trim(gate)
  if g == "spec json" {
    true
  } else {
    if g == "spec json-ok-true" {
      true
    } else {
      if g == "spec json-verdict-pass" {
        true
      } else {
        str.starts_with(g, "spec json-field ")
      }
    }
  }
}

# Three models did this today, with three different tools: a local model wrote
# lex_check as a ```json block, another wrote a raw argument dict, and a hosted
# model wrote <invoke name="run_server">. It is not a quirk of one model, so it
# is checked once here rather than per gate.
fn evaluate(gate :: Str, output :: Str) -> GateVerdict {
  if is_structured_claim_gate(gate) and contains_text_tool_call(output) {
    GateDeny("output contains a tool call written as TEXT (<invoke ...>), so the tool was never actually called — call the tool, then report its real result")
  } else {
    evaluate_gate_body(gate, output)
  }
}

fn evaluate_gate_body(gate :: Str, output :: Str) -> GateVerdict {
  if str.is_empty(gate) {
    GateDeny("gate is empty — ungated output not allowed")
  } else {
    let trimmed := str.trim(gate)
    if trimmed == "spec non-empty" {
      from_spec_verdict(ev.eval(spec_non_empty(), [("output", sp.VStr(output))]))
    } else {
      if str.starts_with(trimmed, "spec contains ") {
        let needle := str.trim(str.slice(trimmed, 14, str.len(trimmed)))
        if str.contains(output, needle) {
          GateAllow
        } else {
          GateDeny(str.join(["output does not contain '", needle, "'"], ""))
        }
      } else {
        if str.starts_with(trimmed, "spec not-contains ") {
          let needle := str.trim(str.slice(trimmed, 18, str.len(trimmed)))
          if str.contains(output, needle) {
            GateDeny(str.join(["output must not contain '", needle, "'"], ""))
          } else {
            GateAllow
          }
        } else {
          if str.starts_with(trimmed, "spec starts-with ") {
            let prefix := str.trim(str.slice(trimmed, 17, str.len(trimmed)))
            if str.starts_with(output, prefix) {
              GateAllow
            } else {
              GateDeny(str.join(["output does not start with '", prefix, "'"], ""))
            }
          } else {
            if trimmed == "spec json" {
              match jv.parse(json_payload(output)) {
                Ok(_) => GateAllow,
                Err(e) => GateDeny(str.concat("output is not valid JSON: ", e.message)),
              }
            } else {
              if trimmed == "spec json-ok-true" {
                match jv.parse(json_payload(output)) {
                  Err(e) => GateDeny(str.concat("output is not valid JSON: ", e.message)),
                  Ok(j) => match jv.get_field(j, "ok") {
                    None => GateDeny("JSON output missing field 'ok'"),
                    Some(JBool(true)) => GateAllow,
                    Some(JBool(false)) => GateDeny("'ok' field is false"),
                    Some(_) => GateDeny("'ok' field is not a boolean"),
                  },
                }
              } else {
                if str.starts_with(trimmed, "spec json-field ") {
                  let field := str.trim(str.slice(trimmed, 16, str.len(trimmed)))
                  match jv.parse(json_payload(output)) {
                    Err(e) => GateDeny(str.concat("output is not valid JSON: ", e.message)),
                    Ok(j) => match jv.get_field(j, field) {
                      None => GateDeny(str.join(["JSON output missing field '", field, "'"], "")),
                      Some(_) => GateAllow,
                    },
                  }
                } else {
                  if str.starts_with(trimmed, "spec len-gt ") {
                    let rest := str.trim(str.slice(trimmed, 12, str.len(trimmed)))
                    let n_str := match list.head(str.split(rest, " ")) {
                      Some(tok) => tok,
                      None => rest,
                    }
                    match str.to_int(n_str) {
                      None => GateDeny(str.concat("invalid len-gt value: ", n_str)),
                      Some(n) => if str.len(output) > n {
                        GateAllow
                      } else {
                        GateDeny(str.join(["output length ", int.to_str(str.len(output)), " not > ", int.to_str(n)], ""))
                      },
                    }
                  } else {
                    if trimmed == "spec json-verdict-pass" {
                      match extract_verdict(output) {
                        None => GateDeny("output missing 'verdict' field"),
                        Some(v) => if str.to_upper(str.trim(v)) == "PASS" {
                          if str.contains(output, "[MISSING_DEPENDENCY]") {
                            GateDeny("verdict is 'PASS' but the output admits [MISSING_DEPENDENCY] — a run that never exercised the real dependency cannot ground a pass")
                          } else {
                            GateAllow
                          }
                        } else {
                          GateDeny(str.join(["verdict is '", v, "', expected 'PASS'"], ""))
                        },
                      }
                    } else {
                      from_spec_verdict(ev.eval(spec_non_empty(), [("output", sp.VStr(output))]))
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}


# Tests live in tests/test_gates.lex
