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
#   Formal   : "spec <expr>"          (all existing spec gates)
#   Judgeable: "human <oracle-name>"  (product, tech-lead, security, …)
#   Testable : anything else          (future: "test <suite>")
type Lane = Formal | Testable | Judgeable(Str)

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
                  let n_str := str.trim(str.slice(trimmed, 12, str.len(trimmed)))
                  match str.to_int(n_str) {
                    None => GateDeny(str.concat("invalid len-gt value: ", n_str)),
                    Some(n) => if str.len(output) > n {
                      GateAllow
                    } else {
                      GateDeny(str.join(["output length ", int.to_str(str.len(output)), " not > ", int.to_str(n)], ""))
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


# Tests live in tests/test_gates.lex
