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
      let oracle := str.trim(str.slice(trimmed, 6, str.len(trimmed)))
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

# ── Gate DSL parser + evaluator ───────────────────────────────────────────────
fn evaluate(gate :: Str, output :: Str) -> GateVerdict {
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
              match jv.parse(output) {
                Ok(_) => GateAllow,
                Err(e) => GateDeny(str.concat("output is not valid JSON: ", e.message)),
              }
            } else {
              if trimmed == "spec json-ok-true" {
                match jv.parse(output) {
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
                  match jv.parse(output) {
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
                        Some(v) => if v == "PASS" {
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
