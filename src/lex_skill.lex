# lex_skill.lex — Lex language skill: tools that give agents ground-truth
# knowledge of Lex, a language that is NOT in any model's training data.
#
# Three tools:
#   lex_guidelines — fetch the authoritative idiom rules (`lex agent-guidelines`)
#   lex_check      — compile a .lex file, return structured type errors
#   lex_run        — execute a function (or run_all tests) in a .lex file
#
# The lex binary is resolved by bash as ${LEX:-lex}, so the tools stay pure
# (no env effect) and work in both the role constructors and the pure resolver.
# All files are written to a shared work dir so multi-file projects (a module
# plus its test that imports it) resolve imports across calls.

import "std.str" as str

import "std.io" as io

import "lex-llm/src/tool" as t

import "lex-schema/schema" as s

import "lex-schema/json_value" as jv

import "lex-schema/error" as e

import "std.proc" as proc

fn work_dir() -> Str {
  "/tmp/loom-lex-work"
}

# Concise Lex essentials — the must-knows for a model that has never seen Lex.
# Kept small on purpose: it stays in the agent's conversation and is
# re-serialized every turn, so a 20KB dump (full `lex agent-guidelines`) would
# blow the orchestrator worker's step budget over a multi-turn tool loop.
fn lex_essentials() -> Str {
  str.join([
    "LEX LANGUAGE ESSENTIALS (you have NOT seen Lex before — follow exactly).",
    "",
    "LOOP: write a file, call lex_check, read errors, repair, repeat until ok='true'.",
    "",
    "SYNTAX:",
    "- Comments use # not //.",
    "- Booleans are true/false (lowercase), never True/False.",
    "- Unit value is (), never `unit`. Unit type is Unit.",
    "- let bindings are immutable; there is no `mut`, no reassignment, no `var`.",
    "- No `return`; a function's last expression is its value.",
    "- Function body is always wrapped in { }, even a single match.",
    "",
    "CONTROL FLOW:",
    "- No `else if`. Nest: if a { x } else { if b { y } else { z } }.",
    "- No && or ||. AND: if a { b } else { false }. OR: if a { true } else { b }.",
    "- No `not`/`!`. Negate: if x { false } else { true }.",
    "- No while/for loops. Use recursion or list.fold / list.map.",
    "",
    "TYPES:",
    "- ADT: type T = A | B(Str) | C(Int, Bool)   (NO leading |).",
    "- Record: type R = { field :: Str, n :: Int }.",
    "- Generics: Option[A], List[A], Result[A, B].",
    "- Pattern match must be exhaustive; add `_ => ...` if needed.",
    "- No tuple field access (pair.0); destructure: match pair { (a, b) => a }.",
    "",
    "FUNCTIONS & EFFECTS:",
    "- fn name(x :: Str, n :: Int) -> RetType { ... }",
    "- Effects go before the return type: fn f(p :: Str) -> [sql, net] Result[Str, Str].",
    "- Effect labels: io, fs_read, fs_write, sql, net, time, random, crypto, env, proc, concurrent, llm.",
    "",
    "IMPORTS (nothing is auto-available):",
    "- import \"std.list\" as list  /  \"std.str\" as str  /  \"std.int\" as int  /  \"std.io\" as io",
    "",
    "STDLIB (only these exist — do not invent functions):",
    "- str: len, slice(s,a,b), split, concat, join(list,sep), contains, starts_with, ends_with, to_lower, to_upper, trim, replace. NO index_of, NO to_chars, NO char_at.",
    "- list: map, filter, fold, len, is_empty, head (-> Option), tail, reverse, concat, cons, range. NO list.find (use filter then head).",
    "- int: to_str, to_float. NO int.from_str.",
    "- String concat: str.concat(a, b) or a + b.",
    "",
    "TESTS:",
    "- A test is `fn test_x() -> Result[Unit, Str]` returning Ok(()) or Err(\"msg\").",
    "- Entry point `fn run_all() -> Int` returns the number of FAILING tests (0 = all pass).",
    "- There is no `test \"...\"` syntax.",
    "",
    "PURE FUNCTIONS: add an examples { f(x) => y, ... } block — it runs at check time.",
    "",
    "After writing each file, ALWAYS call lex_check and fix every reported error.",
  ], "\n")
}

# ── lex_guidelines ──────────────────────────────────────────────────────────
# Returns a concise Lex essentials guide. The model should read this before
# writing any Lex, because Lex is not in its training data.
fn make_lex_guidelines_tool() -> t.Tool {
  let params := {
    title: "LexGuidelines",
    description: "Fetch the essential Lex language rules",
    fields: [s.required_str("topic", [])]
  }
  t.define(
    "lex_guidelines",
    "Return the essential Lex syntax, effect, type, and stdlib rules. Lex is NOT in your training data — call this FIRST, before writing any Lex code.",
    params,
    fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
      Ok(JObj([("guidelines", JStr(lex_essentials()))]))
    }
  )
}

# ── lex_check ───────────────────────────────────────────────────────────────
# Writes `code` to work_dir/<filename> and type-checks it. Returns structured
# errors so the model can repair. Files accumulate so imports resolve.
fn make_lex_check_tool() -> t.Tool {
  let dir := work_dir()
  let params := {
    title: "LexCheck",
    description: "Type-check a .lex file, return {ok, output}",
    fields: [s.required_str("filename", []), s.required_str("code", [])]
  }
  t.define(
    "lex_check",
    "Write `code` to <filename> and run `lex check`. Returns {ok:'true'|'false', output:<json errors or 'ok'>}. ALWAYS call this after writing each .lex file and repair until ok='true' before finishing. Never claim code compiles without calling this.",
    params,
    fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
      let filename := match jv.get_field(args, "filename") { Some(JStr(v)) => v, _ => "main.lex" }
      let code := match jv.get_field(args, "code") { Some(JStr(v)) => v, _ => "" }
      let path := str.join([dir, "/", filename], "")
      match proc.spawn("bash", ["-c", str.concat("mkdir -p ", dir)]) {
        Err(msg) => Err(e.single("", "proc_error", str.concat("mkdir failed: ", msg))),
        Ok(_) => {
          let __w := io.write(path, code)
          let cmd := str.join(["${LEX:-lex} check ", path, " 2>&1; echo '##EXIT:'$?"], "")
          match proc.spawn("bash", ["-c", cmd]) {
            Err(msg) => Ok(JObj([("ok", JStr("false")), ("output", JStr(msg))])),
            Ok(r) => {
              let combined := str.concat(r.stdout, r.stderr)
              let ok := str.contains(combined, "##EXIT:0")
              Ok(JObj([("ok", JStr(if ok { "true" } else { "false" })), ("output", JStr(combined))]))
            },
          }
        },
      }
    }
  )
}

# ── lex_run ─────────────────────────────────────────────────────────────────
# Executes a function in a previously-checked file. For tests, use
# fn_name='run_all'. The file must already exist in the work dir (write it
# with lex_check first).
fn make_lex_run_tool() -> t.Tool {
  let dir := work_dir()
  let params := {
    title: "LexRun",
    description: "Run a function in a .lex file, return {ok, output}",
    fields: [s.required_str("filename", []), s.required_str("fn_name", []), s.required_str("args", [])]
  }
  t.define(
    "lex_run",
    "Run `lex run <filename> <fn_name> <args>` on a file already written via lex_check. For tests use fn_name='run_all' and args=''. args are space-separated JSON values. Returns {ok, output}. Base your verdict on this output — never guess.",
    params,
    fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
      let filename := match jv.get_field(args, "filename") { Some(JStr(v)) => v, _ => "main.lex" }
      let fn_name := match jv.get_field(args, "fn_name") { Some(JStr(v)) => v, _ => "main" }
      let extra := match jv.get_field(args, "args") { Some(JStr(v)) => v, _ => "" }
      let path := str.join([dir, "/", filename], "")
      let cmd := str.join(["${LEX:-lex} run --allow-effects io,fs_read,fs_write,time,random,crypto,net ", path, " ", fn_name, " ", extra, " 2>&1; echo '##EXIT:'$?"], "")
      match proc.spawn("bash", ["-c", cmd]) {
        Err(msg) => Ok(JObj([("ok", JStr("false")), ("output", JStr(msg))])),
        Ok(r) => {
          let combined := str.concat(r.stdout, r.stderr)
          let ok := str.contains(combined, "##EXIT:0")
          Ok(JObj([("ok", JStr(if ok { "true" } else { "false" })), ("output", JStr(combined))]))
        },
      }
    }
  )
}
