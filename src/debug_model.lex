# debug_model.lex — diagnose which Ollama models work with lex-llm's provider.
#
# Run: OLLAMA_MODEL=mistral-small:latest lex run --allow-effects env,io,net,llm,proc,approval src/debug_model.lex check_model

import "std.io" as io

import "std.str" as str

import "std.list" as list

import "std.env" as env

import "std.iter" as iter

import "lex-llm/src/providers" as providers

import "lex-llm/src/provider" as prov

import "lex-llm/src/agent" as agent

import "lex-llm/src/message" as msg

import "lex-llm/src/delta" as d

import "./defaults" as defaults

fn check_model() -> [env, io, net, llm, proc, approval] Unit {
  let model_name := match env.get("OLLAMA_MODEL") {
    Some(m) => m,
    None => defaults.model(),
  }
  let __p0 := io.print(str.concat("[debug] testing model: ", model_name))
  let provider := providers.ollama_local()
  let model := prov.ollama(model_name)
  let def := agent.make_agent("debug", "You are a helpful assistant.", model, provider, [], agent.default_options())
  let conv := [msg.UserMsg("Reply with exactly: OK")]
  let steps := iter.to_list(agent.run_loop(def, conv))
  let __p1 := io.print(str.concat("[debug] step count: ", int.to_str(list.len(steps))))
  let __p2 := list.map(steps, fn (s :: d.Step) -> [io] Unit {
    match s {
      StepDone(m) => io.print(str.concat("[debug] StepDone: '", str.concat(msg.content(m), "'"))),
      StepDelta(TextChunk(t)) => io.print(str.concat("[debug] TextChunk: '", str.concat(t, "'"))),
      StepDelta(FinishDelta(r)) => io.print(str.concat("[debug] Finish: ", r)),
      StepToolExec(name, _) => io.print(str.concat("[debug] ToolExec: ", name)),
      StepToolResult(id, ok) => io.print(str.concat("[debug] ToolResult: ", id)),
      StepDelta(_) => io.print("[debug] other delta"),
    }
  })
  ()
}

