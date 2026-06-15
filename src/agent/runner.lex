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

import "std.proc" as proc

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
fn build_work_dir() -> Str {
  "/tmp/loom-lex-work"
}

fn has_fence(s :: Str) -> Bool {
  str.contains(s, "```")
}

# Start each build attempt from a clean work_dir so stale files don't leak in.
fn clear_work_dir() -> [proc] Unit {
  let __ := proc.spawn("bash", ["-c", str.join(["rm -rf ", build_work_dir(), "/* 2>/dev/null; mkdir -p ", build_work_dir()], "")])
  ()
}

# Emit every file written to the work_dir as a fenced block labelled with its
# filename — the format the QA agent extracts.
fn recover_build_artifact() -> [proc] Str {
  let cmd := str.join(["cd ", build_work_dir(), " 2>/dev/null && for f in *; do [ -f \"$f\" ] && { echo '```'\"$f\"; cat \"$f\"; echo '```'; }; done"], "")
  match proc.spawn("bash", ["-c", cmd]) {
    Err(_) => "",
    Ok(r) => r.stdout,
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
  match proc.spawn("bash", ["-c", "mktemp /tmp/loom-proc.XXXXXXXX"]) {
    Err(msg) => str.concat("PROC_ERROR: mktemp failed: ", msg),
    Ok(mk) => {
      let path := str.trim(mk.stdout)
      let __w := io.write(path, full_input)
      let cmd := str.join([def.proc_cmd, " < ", path, "; echo '##PROC_EXIT:'$?"], "")
      match proc.spawn("bash", ["-c", cmd]) {
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
      let conv := [llm_msg.UserMsg(msg_json)]
      let __clear := if def.kind == "build" {
        clear_work_dir()
      } else {
        ()
      }
      let _t2 := trace.record(db, run_id, def.id, "llm_start", "{}")
      let steps := iter.to_list(llm_agent.run_loop(llm_def, conv))
      let out0 := extract_answer(steps)
      let out := if def.kind == "build" {
        if has_fence(out0) {
          out0
        } else {
          let recovered := recover_build_artifact()
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

