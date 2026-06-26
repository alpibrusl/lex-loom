# runner.lex — LLM-driven step loop for loom agents.
#
# Each call to step():
#   1. Load agent state from SQL
#   2. Inject state + message into an LLM conversation
#   3. Run the lex-llm tool loop with agent domain tools
#   4. Save updated state
#   5. Write trace events
#
# AgentDef carries the agent's identity and its domain-specific tools.
# Two alternative executors are supported via AgentDef fields:
#
#   proc_cmd (non-empty) — spawn a shell command; full input is piped
#             via stdin; stdout becomes the node output.
#             Example: "proc_cmd: \"opencode chat -q\""
#             model_name convention: "proc:<cmd>"
#
#   a2a_url (non-empty) — send an A2A tasks/send JSON-RPC call to a
#             remote agent; extract the first text artifact as output.
#             model_name convention: "a2a:<url>"

import "std.str" as str

import "std.list" as list

import "std.iter" as iter

import "std.http" as http

import "std.bytes" as bytes

import "std.int" as int

import "std.process" as proc

import "std.io" as io

import "lex-schema/json_value" as jv

import "lex-schema/schema" as s

import "lex-schema/error" as e

import "lex-llm/src/agent" as llm_agent

import "lex-llm/src/message" as llm_msg

import "lex-llm/src/delta" as d

import "lex-llm/src/tool" as t

import "lex-llm/src/provider" as prov

import "lex-llm/src/providers" as providers

import "lex-agent/src/memory" as mem

import "lex-orm/src/connection" as conn

import "./trace" as trace

type AgentDef = { id :: Str, kind :: Str, system_prompt :: Str, model_name :: Str, provider :: prov.Provider, tools :: List[t.Tool], proc_cmd :: Str, a2a_url :: Str }

type PeerInfo = { id :: Str, kind :: Str, name :: Str, inbox_url :: Str, role :: Str }

fn extract_answer(steps :: List[d.Step]) -> Str {
  list.fold(steps, "", fn (acc :: Str, st :: d.Step) -> Str {
    match st {
      StepDone(m) => {
        let c := llm_msg.content(m)
        if str.is_empty(c) {
          acc
        } else {
          c
        }
      },
      _ => acc,
    }
  })
}

# ── build artifact recovery ────────────────────────────────────────────────
# A tool-calling model submits each file via the lex_check(filename, code) tool
# (which writes it to lex_skill's work_dir) and may finish WITHOUT restating the
# files as a fenced text block — so extract_answer returns "" and the node has
# no artifact. Recover the artifact from the work_dir in that case. Keep the
# path in sync with lex_skill.work_dir().
# Lex and Python builds run in parallel, so each gets its OWN work dir — they
# must never share, or recover_build_artifact would mix one language's files into
# the other's artifact. Keep the Lex path in sync with lex_skill.work_dir() and
# the Python path with lex_skill.py_work_dir().
fn build_work_dir() -> Str {
  "/tmp/loom-lex-work"
}

fn py_work_dir() -> Str {
  "/tmp/loom-py-work"
}

# Which work dir a build kind writes to (build → Lex, py_build → Python).
fn work_dir_for(kind :: Str) -> Str {
  if kind == "py_build" {
    py_work_dir()
  } else {
    build_work_dir()
  }
}

# True for any code-producing build node (Lex or Python).
fn is_build_kind(kind :: Str) -> Bool {
  if kind == "build" {
    true
  } else {
    kind == "py_build"
  }
}

fn has_fence(s :: Str) -> Bool {
  str.contains(s, "```")
}

# Start each build attempt from a clean work_dir so stale files don't leak in.
fn clear_work_dir(kind :: Str) -> [proc] Unit {
  let d := work_dir_for(kind)
  let __ := proc.run("bash", ["-c", str.join(["rm -rf ", d, "/* 2>/dev/null; mkdir -p ", d], "")])
  ()
}

# Emit every file written to the work_dir as a fenced block labelled with its
# filename — the format the QA agent extracts.
fn recover_build_artifact(kind :: Str) -> [proc] Str {
  let cmd := str.join(["cd ", work_dir_for(kind), " 2>/dev/null && for f in *; do [ -f \"$f\" ] && { echo '```'\"$f\"; cat \"$f\"; echo '```'; }; done"], "")
  match proc.run("bash", ["-c", cmd]) {
    Err(_) => "",
    Ok(r) => r.stdout,
  }
}

# Build gate: compile EVERY file the build agent wrote, not just the ones it
# bothered to check. Without this a build node can ship a correct server.lex
# alongside a test.lex that doesn't even parse — QA then fails and burns bounces.
# Compiles each file in the kind's work dir (lex check for .lex, py_compile for
# .py). Returns Ok(()) if all compile and at least one source file exists, else
# Err(<first failing file + compiler output>). Pure [proc] — runs the real
# compiler, same as the agent's own check tool.
fn verify_build_compiles(kind :: Str) -> [proc] Result[Unit, Str] {
  if is_build_kind(kind) {
    verify_compiles(kind)
  } else {
    Ok(())
  }
}

# Gate-driven compile check (#32, "spec compiles"). Unlike verify_build_compiles
# this runs regardless of role — the GATE, not the kind, decides it should run —
# so any code-producing node can declare `spec compiles` and have it enforced.
# Compiles every source file in the node's work dir; py_compile for py_build,
# `lex check` otherwise. Returns Ok(()) iff all compile and ≥1 source file exists.
fn verify_compiles(kind :: Str) -> [proc] Result[Unit, Str] {
  {
    let dir := work_dir_for(kind)
    let check := if kind == "py_build" {
      "python3 -m py_compile"
    } else {
      "${LEX:-lex} check"
    }
    let ext := if kind == "py_build" {
      "py"
    } else {
      "lex"
    }
    # Loop over *.<ext>; fail loud on the first that doesn't compile; also fail
    # if no source files were produced at all (prose-only output).
    let script := str.join(["cd ", dir, " 2>/dev/null || { echo 'NO_WORKDIR'; exit 3; }; n=0; for f in *.", ext, "; do [ -f \"$f\" ] || continue; n=$((n+1)); out=$(", check, " \"$f\" 2>&1); if [ $? -ne 0 ]; then echo \"COMPILE_FAIL $f\"; echo \"$out\"; exit 1; fi; done; if [ $n -eq 0 ]; then echo 'NO_SOURCE_FILES'; exit 2; fi; echo OK"], "")
    match proc.run("bash", ["-c", script]) {
      Err(msg) => Err(str.concat("compile check could not run: ", msg)),
      Ok(r) => {
        let combined := str.concat(r.stdout, r.stderr)
        if str.contains(combined, "OK") {
          Ok(())
        } else {
          if str.contains(combined, "NO_SOURCE_FILES") {
            Err(str.concat("build produced no ", str.concat(ext, " source files — output was prose, not code")))
          } else {
            if str.contains(combined, "NO_WORKDIR") {
              Err("build produced no files (work dir missing)")
            } else {
              Err(str.concat("a source file failed to compile:\n", combined))
            }
          }
        }
      },
    }
  }
}

fn build_system_prompt(def :: AgentDef, state_json :: Str, entries :: List[mem.MemoryEntry]) -> Str {
  let state_part := if state_json == "{}" {
    ""
  } else {
    str.concat("\n\nState: ", state_json)
  }
  let mem_part := mem.to_context(entries)
  str.join([def.system_prompt, state_part, mem_part], "")
}

# ── proc executor ──────────────────────────────────────────────────────────────
# Writes (system_prompt + "\n\n" + msg_json) to a temp file, pipes it via
# stdin to proc_cmd, returns stdout (or stderr if stdout is empty).
fn proc_step(def :: AgentDef, msg_json :: Str) -> [proc, io] Str {
  let full_input := str.join([def.system_prompt, "\n\n", msg_json], "")
  match proc.run("bash", ["-c", "mktemp /tmp/loom-proc.XXXXXXXX"]) {
    Err(msg) => str.concat("PROC_ERROR: mktemp failed: ", msg),
    Ok(mk) => {
      let path := str.trim(mk.stdout)
      let __w := io.write(path, full_input)
      let cmd := str.join([def.proc_cmd, " < ", path, "; echo '##PROC_EXIT:'$?"], "")
      match proc.run("bash", ["-c", cmd]) {
        Err(msg) => str.concat("PROC_ERROR: spawn failed: ", msg),
        Ok(r) => if str.contains(r.stdout, "##PROC_EXIT:0") {
          str.trim(str.replace(r.stdout, "##PROC_EXIT:0", ""))
        } else {
          str.join(["PROC_ERROR: exit non-zero. stderr: ", r.stderr], "")
        },
      }
    },
  }
}

# ── A2A executor ───────────────────────────────────────────────────────────────
# Sends the prompt to a remote agent via the A2A tasks/send JSON-RPC protocol.
# Returns the first text part of the first artifact in the response.
fn a2a_step(def :: AgentDef, msg_json :: Str, run_id :: Str) -> [net] Str {
  let text := str.join([def.system_prompt, "\n\n", msg_json], "")
  let body := str.join(["{\"jsonrpc\":\"2.0\",\"id\":\"", run_id, "\",\"method\":\"tasks/send\",\"params\":{\"id\":\"", run_id, "\",\"contextId\":\"ctx-loom\",\"message\":{\"messageId\":\"", run_id, "\",\"role\":\"user\",\"parts\":[{\"kind\":\"text\",\"text\":", jv.stringify(JStr(text)), "}]}}}"], "")
  match http.post(def.a2a_url, bytes.from_str(body), "application/json") {
    Err(_) => "A2A_ERROR: http call failed",
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => "A2A_ERROR: response body decode failed",
      Ok(s) => extract_a2a_text(s),
    },
  }
}

fn extract_a2a_text(body :: Str) -> Str {
  match jv.parse(body) {
    Err(_) => str.concat("A2A_PARSE_ERROR: ", body),
    Ok(j) => match jv.get_field(j, "error") {
      Some(ej) => str.concat("A2A_RPC_ERROR: ", jv.stringify(ej)),
      None => match jv.get_field(j, "result") {
        None => "A2A_ERROR: response has no result field",
        Some(result) => match jv.get_field(result, "artifacts") {
          None => extract_a2a_status_text(result),
          Some(JList(arts)) => match list.head(arts) {
            None => "A2A_ERROR: artifacts array is empty",
            Some(art) => match jv.get_field(art, "parts") {
              None => "A2A_ERROR: artifact has no parts",
              Some(JList(parts)) => extract_text_from_parts(parts),
              Some(_) => "A2A_ERROR: parts is not an array",
            },
          },
          Some(_) => "A2A_ERROR: artifacts is not an array",
        },
      },
    },
  }
}

fn extract_a2a_status_text(result :: jv.Json) -> Str {
  match jv.get_field(result, "status") {
    None => "A2A_ERROR: no artifacts and no status",
    Some(st) => match jv.get_field(st, "message") {
      None => "A2A_ERROR: task completed but no output artifact",
      Some(JStr(m)) => m,
      Some(v) => jv.stringify(v),
    },
  }
}

fn extract_text_from_parts(parts :: List[jv.Json]) -> Str {
  list.fold(parts, "", fn (acc :: Str, part :: jv.Json) -> Str {
    if str.is_empty(acc) {
      match jv.get_field(part, "text") {
        Some(JStr(t)) => t,
        _ => match jv.get_field(part, "data") {
          Some(d) => jv.stringify(d),
          None => acc,
        },
      }
    } else {
      acc
    }
  })
}

# ── conversation memory across QA bounces ─────────────────────────────────────
# A build node that is bounced back from QA receives a structured "bounce
# envelope" instead of a flat string. We rebuild it into a proper multi-turn
# conversation so the model sees its OWN previous attempt (AssistantMsg) and the
# QA critique (UserMsg) and edits its code, rather than re-deriving from scratch.
# Non-build kinds (or non-envelope input) keep the single-UserMsg behaviour.
fn jstr_field(j :: jv.Json, key :: Str, default :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => default,
  }
}

# Pull the Nth section of a delimiter-split list, or "" if absent.
fn nth_or_empty(parts :: List[Str], i :: Int) -> Str {
  match list.head(parts) {
    None => "",
    Some(h) => if i == 0 {
      h
    } else {
      nth_or_empty(list.tail(parts), i - 1)
    },
  }
}

fn conv_from_msg(kind :: Str, msg_json :: Str) -> List[llm_msg.Message] {
  let is_bounce := if is_build_kind(kind) {
    str.starts_with(msg_json, "<<<LOOM_BOUNCE>>>")
  } else {
    false
  }
  if is_bounce {
    # Linear split on the sentinel — no JSON parser (which is quadratic and
    # blows the VM step limit on multi-KB prior_code). Layout:
    # <<<LOOM_BOUNCE>>>task<<<LOOM_SEP>>>prior_code<<<LOOM_SEP>>>qa_feedback
    let body := str.slice(msg_json, 17, str.len(msg_json))
    let parts := str.split(body, "<<<LOOM_SEP>>>")
    let task := nth_or_empty(parts, 0)
    let prior := nth_or_empty(parts, 1)
    let feedback := nth_or_empty(parts, 2)
    let critique := str.join(["Your previous attempt above did NOT pass QA.", "", "Reason: ", feedback, "", "Fix YOUR code: keep what worked, change only what failed. Call lex_check and repair until ok='true', then output the corrected file."], "\n")
    [llm_msg.UserMsg(task), llm_msg.AssistantMsg(prior, []), llm_msg.UserMsg(critique)]
  } else {
    [llm_msg.UserMsg(msg_json)]
  }
}

# ── main step ─────────────────────────────────────────────────────────────────
fn step(db :: conn.ConnDb, def :: AgentDef, msg_json :: Str) -> [io, time, sql, concurrent, net, random, fs_read, fs_write, llm, proc, env] Str {
  let run_id := trace.new_run_id()
  let _t1 := trace.record(db, run_id, def.id, "received", msg_json)
  let answer := if str.len(def.a2a_url) > 0 {
    let _t2 := trace.record(db, run_id, def.id, "a2a_start", str.concat("{\"url\":\"", str.concat(def.a2a_url, "\"}")))
    let out := a2a_step(def, msg_json, run_id)
    let _t3 := trace.record(db, run_id, def.id, "a2a_done", jv.stringify(JStr(out)))
    out
  } else {
    if str.len(def.proc_cmd) > 0 {
      let _t2 := trace.record(db, run_id, def.id, "proc_start", str.concat("{\"cmd\":\"", str.concat(def.proc_cmd, "\"}")))
      let out := proc_step(def, msg_json)
      let _t3 := trace.record(db, run_id, def.id, "proc_done", jv.stringify(JStr(out)))
      out
    } else {
      let state := mem.load_state(db, def.id)
      let entries := mem.recall_all(db, def.id)
      let sys := build_system_prompt(def, state, entries)
      let all_tools := def.tools
      let the_model := prov.make_model_ref(def.provider.name, def.model_name)
      let llm_def := { name: def.id, goal: sys, model: the_model, provider: def.provider, tools: all_tools, options: llm_agent.default_options(), permission_spec: None }
      let conv := conv_from_msg(def.kind, msg_json)
      let __clear := if is_build_kind(def.kind) {
        clear_work_dir(def.kind)
      } else {
        ()
      }
      let _t2 := trace.record(db, run_id, def.id, "llm_start", "{}")
      let steps := iter.to_list(llm_agent.run_loop(llm_def, conv))
      let out0 := extract_answer(steps)
      let out := if is_build_kind(def.kind) {
        if has_fence(out0) {
          out0
        } else {
          let recovered := recover_build_artifact(def.kind)
          if str.is_empty(str.trim(recovered)) {
            out0
          } else {
            str.concat(out0, str.concat("\n\n", recovered))
          }
        }
      } else {
        out0
      }
      let _dbg := io.print(str.join(["[runner.step] agent=", def.id, " steps=", int.to_str(list.len(steps)), " answer_len=", int.to_str(str.len(out)), " prompt_len=", int.to_str(str.len(msg_json))], ""))
      let _t3 := trace.record(db, run_id, def.id, "llm_done", jv.stringify(JStr(out)))
      out
    }
  }
  answer
}

