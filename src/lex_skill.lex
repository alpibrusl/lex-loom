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

# ── lex_guidelines ──────────────────────────────────────────────────────────
# Returns the prescriptive Lex idiom contract. The model should read this
# before writing any Lex, because Lex is not in its training data.
fn make_lex_guidelines_tool() -> t.Tool {
  let params := {
    title: "LexGuidelines",
    description: "Fetch the authoritative Lex language idiom rules",
    fields: [s.required_str("topic", [])]
  }
  t.define(
    "lex_guidelines",
    "Return the authoritative Lex idiom rules (effects, types, stdlib, pitfalls). Lex is NOT in your training data — call this FIRST, before writing any Lex code. Pass topic='all' for the full guide.",
    params,
    fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
      match proc.spawn("bash", ["-c", "${LEX:-lex} agent-guidelines 2>&1"]) {
        Err(msg) => Err(e.single("", "proc_error", str.concat("lex agent-guidelines failed: ", msg))),
        Ok(r) => Ok(JObj([("guidelines", JStr(str.concat(r.stdout, r.stderr)))])),
      }
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
