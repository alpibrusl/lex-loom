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

import "std.str" as str

import "std.list" as list

import "std.iter" as iter

import "std.http" as http

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-schema/schema" as s

import "lex-schema/error" as e

import "lex-llm/src/agent" as llm_agent

import "lex-llm/src/message" as llm_msg

import "lex-llm/src/delta" as d

import "lex-llm/src/tool" as t

import "lex-llm/src/provider" as prov

import "lex-llm/src/providers" as providers

import "./state_store" as state_store

import "./trace" as trace

import "./relationships" as rel

import "./registry" as reg

type AgentDef = { id :: Str, kind :: Str, system_prompt :: Str, model_name :: Str, provider :: prov.Provider, tools :: List[t.Tool] }

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

fn state_context(state_json :: Str) -> Str {
  str.concat("Your current state: ", state_json)
}

fn build_system_prompt(def :: AgentDef, state_json :: Str) -> Str {
  str.concat(def.system_prompt, str.concat("\n\n", state_context(state_json)))
}

fn step(db :: Db, def :: AgentDef, msg_json :: Str) -> [io, time, sql, concurrent, net, random, fs_read, fs_write, llm, proc, env] Str {
  let run_id := trace.new_run_id()
  let state := state_store.load(db, def.id)
  let _t1 := trace.record(db, run_id, def.id, "received", msg_json)
  let sys := build_system_prompt(def, state)
  let all_tools := def.tools
  let the_model := prov.make_model_ref(def.provider.name, def.model_name)
  let llm_def := { name: def.id, goal: sys, model: the_model, provider: def.provider, tools: all_tools, options: llm_agent.default_options(), permission_spec: None }
  let conv := [llm_msg.UserMsg(msg_json)]
  let _t2 := trace.record(db, run_id, def.id, "llm_start", "{}")
  let steps := iter.to_list(llm_agent.run_loop(llm_def, conv))
  let answer := extract_answer(steps)
  let _dbg := io.print(str.join(["[runner.step] agent=", def.id, " steps=", int.to_str(list.len(steps)), " answer_len=", int.to_str(str.len(answer)), " prompt_len=", int.to_str(str.len(msg_json))], ""))
  let _t3 := trace.record(db, run_id, def.id, "llm_done", jv.stringify(JStr(answer)))
  answer
}
