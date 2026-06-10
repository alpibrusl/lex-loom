# roles.lex -- AgentDef constructors for the four loom orchestration roles.
#
# Architect  derives and refines the SprintGraph.
# QA         evaluates work and produces an attestation.
# Demo       summarises completed work for stakeholders.
# Scribe     produces the Digest: tightened specs + seed graph.
#
# M2: system prompts are minimal; tools list is empty (LLM text output only).
# M3: Architect gains graph-emit tool; roles gain lex-code worker tools.

import "std.str" as str

import "std.env" as env

import "std.io" as io

import "std.list" as list

import "lex-llm/src/tool" as t

import "lex-llm/src/provider" as prov

import "lex-llm/src/providers" as providers

import "lex-llm/src/providers/vertex" as vtx

import "lex-schema/schema" as s

import "lex-schema/json_value" as jv

import "lex-schema/error" as e

import "std.proc" as proc

import "./agent/runner" as runner

import "./lex_skill" as lexskill

# ── run_code tool (inline — avoids cross-file lex-llm import resolution) ──────
#
# Gives QA the ability to *execute* the implementation it received.
# Uses mktemp via proc to get a unique path (safe for parallel QA nodes),
# writes code + assertions, runs python3, detects exit via ##EXIT:$? sentinel.
fn make_run_code_tool() -> t.Tool {
  let params := {
    title: "RunCode",
    description: "Execute Python code and assertions, return {passed, exit_code, output}",
    fields: [s.required_str("code", []), s.required_str("assertions", [])]
  }
  t.define(
    "run_code",
    "Write `code` + `assertions` to a temp .py file, run it with python3, return {passed, exit_code, output}. ALWAYS call this before emitting your JSON verdict — never guess.",
    params,
    fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
      let code := match jv.get_field(args, "code") { Some(JStr(v)) => v, _ => "" }
      let assertions := match jv.get_field(args, "assertions") { Some(JStr(v)) => v, _ => "" }
      let full := str.join([code, "\n\n# --- QA assertions ---\n", assertions], "")
      match proc.spawn("bash", ["-c", "mktemp /tmp/loom-qa.XXXXXXXX"]) {
        Err(msg) => Err(e.single("", "proc_error", str.concat("mktemp failed: ", msg))),
        Ok(mk) => {
          let path := str.trim(mk.stdout)
          let __w  := io.write(path, full)
          let cmd  := str.join(["timeout 30 python3 ", path, " 2>&1; echo '##EXIT:'$?"], "")
          match proc.spawn("bash", ["-c", cmd]) {
            Err(msg) => Ok(JObj([("passed", JStr("false")), ("exit_code", JInt(1)), ("output", JStr(msg))])),
            Ok(r) => {
              let combined := str.concat(r.stdout, r.stderr)
              let passed   := str.contains(combined, "##EXIT:0")
              Ok(JObj([("passed", JStr(if passed { "true" } else { "false" })), ("exit_code", JInt(if passed { 0 } else { 1 })), ("output", JStr(combined))]))
            },
          }
        },
      }
    }
  )
}

# ── Provider helpers ──────────────────────────────────────────────────────────
fn make_ollama_provider() -> [env] prov.Provider {
  let base := match env.get("OLLAMA_URL") {
    Some(u) => if str.is_empty(u) {
      "http://localhost:11434"
    } else {
      u
    },
    None => "http://localhost:11434",
  }
  providers.ollama_at(base)
}

fn make_vertex_provider() -> [env] prov.Provider {
  let api_key := match env.get("VERTEX_ACCESS_TOKEN") {
    Some(k) => k,
    None => "",
  }
  let project := match env.get("VERTEX_PROJECT") {
    Some(p) => p,
    None => "",
  }
  let location := match env.get("VERTEX_LOCATION") {
    Some(l) => if str.is_empty(l) {
      "eu"
    } else {
      l
    },
    None => "eu",
  }
  vtx.make_provider(vtx.config_at(api_key, project, location))
}

# Provider priority: LiteLLM > Vertex AI > Anthropic > OpenAI > Google > Mistral > Ollama
# LiteLLM is selected when LITELLM_BASE_URL is set (default: http://localhost:4000).
# Vertex AI is selected when VERTEX_ACCESS_TOKEN and VERTEX_PROJECT are both set.
fn make_provider() -> [env] prov.Provider {
  match env.get("LITELLM_BASE_URL") {
    Some(url) => if str.is_empty(url) {
      make_provider_no_litellm()
    } else {
      providers.litellm()
    },
    None => make_provider_no_litellm(),
  }
}

fn make_provider_no_litellm() -> [env] prov.Provider {
  match env.get("VERTEX_ACCESS_TOKEN") {
    Some(k) => if str.is_empty(k) {
      make_provider_no_vertex()
    } else {
      match env.get("VERTEX_PROJECT") {
        Some(p) => if str.is_empty(p) {
          make_provider_no_vertex()
        } else {
          make_vertex_provider()
        },
        None => make_provider_no_vertex(),
      }
    },
    None => make_provider_no_vertex(),
  }
}

fn make_openai_provider() -> [env] prov.Provider {
  providers.openai()
}

fn make_google_provider() -> [env] prov.Provider {
  providers.google()
}

fn make_mistral_provider() -> [env] prov.Provider {
  providers.mistral()
}

fn key_is_set(k :: Str) -> Bool {
  str.len(k) > 0
}

fn make_provider_no_vertex() -> [env] prov.Provider {
  match env.get("ANTHROPIC_API_KEY") {
    Some(k) => if key_is_set(k) {
      providers.anthropic()
    } else {
      make_provider_no_anthropic()
    },
    None => make_provider_no_anthropic(),
  }
}

fn make_provider_no_anthropic() -> [env] prov.Provider {
  match env.get("OPENAI_API_KEY") {
    Some(k) => if key_is_set(k) {
      make_openai_provider()
    } else {
      make_provider_no_openai()
    },
    None => make_provider_no_openai(),
  }
}

fn make_provider_no_openai() -> [env] prov.Provider {
  match env.get("GOOGLE_API_KEY") {
    Some(k) => if key_is_set(k) {
      make_google_provider()
    } else {
      make_provider_no_google()
    },
    None => make_provider_no_google(),
  }
}

fn make_provider_no_google() -> [env] prov.Provider {
  match env.get("MISTRAL_API_KEY") {
    Some(k) => if key_is_set(k) {
      make_mistral_provider()
    } else {
      make_ollama_provider()
    },
    None => make_ollama_provider(),
  }
}

# Temp file path where the emit_graph tool writes the graph JSON.
fn graph_tmp_path(sprint_id :: Str) -> Str {
  str.join(["/tmp/loom-graph-", sprint_id, ".json"], "")
}

# The emit_graph tool -- the Architect calls this instead of printing JSON.
fn make_emit_graph_tool(sprint_id :: Str) -> t.Tool {
  let node_schema := { title: "Node", description: "A sprint graph node", fields: [s.required_str("id", []), s.required_str("role", []), s.required_str("gate", [])] }
  let edge_schema := { title: "Edge", description: "A sprint graph edge", fields: [s.required_str("from", []), s.required_str("to", []), s.required_str("handoff", [])] }
  let params := { title: "EmitGraph", description: "Emit the sprint graph", fields: [s.required_str("id", []), s.required_str("phase", []), s.required_array("nodes", s.KObject(node_schema), []), s.required_array("edges", s.KObject(edge_schema), [])] }
  t.define("emit_graph", "Emit the sprint graph. Call this ONCE with the complete graph JSON. Do not print JSON in your reply -- call this tool instead.", params, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let graph_json := jv.stringify(args)
    let path := graph_tmp_path(sprint_id)
    match io.write(path, graph_json) {
      Err(err) => Ok(JObj([("error", JStr(err))])),
      Ok(_) => Ok(JObj([("status", JStr("graph_written")), ("path", JStr(path))])),
    }
  })
}

fn architect(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-architect", kind: "architect", system_prompt: "You are a software design architect. Given a project request, produce a concise technical design specification in plain prose: describe the components, key functions or classes, their interfaces, and expected behaviour. Do not output JSON or sprint graphs. Write 2-4 paragraphs maximum.", model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
}

fn architect_with_context(model :: Str, specs_context :: Str, sprint_id :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-architect", kind: "architect", system_prompt: str.concat("You are the Architect for a software sprint. Given a project request, output ONLY a JSON sprint graph -- no prose, no markdown fences. Each node needs an id, a role, and a gate. Each edge needs from, to, and a handoff. Shape: {\"id\":\"...\",\"phase\":\"Design\",\"nodes\":[{\"id\":\"...\",\"role\":\"...\",\"gate\":\"...\"}],\"edges\":[{\"from\":\"...\",\"to\":\"...\",\"handoff\":\"schema {}\"}]}", specs_context), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
}

fn qa_system_prompt() -> Str {
  "You are the QA agent for a Lex language sprint. Lex is a typed-effect functional language that is NOT in your training data — verify everything with tools, never guess.\n\nWORKFLOW (mandatory — do not skip):\n1. Extract every .lex file from the Build output.\n2. Call lex_check on each file (pass filename + code). Every file MUST return ok='true'.\n3. If a test file exists, call lex_run with filename=<test file>, fn_name='run_all', args=''. Tests pass when output shows ok='true' and zero failures.\n4. Output ONLY a JSON object — no prose, no markdown fences:\n{\"verdict\":\"PASS\",\"reason\":\"what compiled and passed\",\"check_output\":\"<first 200 chars>\",\"test_output\":\"<first 200 chars>\"}\n\nVerdict is PASS only if lex_check is ok='true' for ALL files AND tests pass. Otherwise FAIL and list the errors.\n\nFORBIDDEN: Do not guess or speculate. Your verdict MUST be based on lex_check / lex_run output."
}

fn build_system_prompt() -> Str {
  "You are the Build agent for a Lex language sprint. Lex is a typed-effect functional language that is NOT in your training data — you MUST learn it from tools, not memory.\n\nWORKFLOW (mandatory — do not skip):\n1. Call lex_guidelines (topic='all') FIRST to learn Lex syntax, effects, types, and the stdlib surface. Do this before writing any code.\n2. Implement the Architect's design as Lex modules.\n3. After writing EACH file, call lex_check (filename + code). Read the JSON errors and repair the code until ok='true'.\n4. Finish only when every file passes lex_check.\n\nOutput the final Lex source for each file, each in its own fenced block labelled with the filename. Never claim code compiles unless lex_check confirmed ok='true'."
}

fn qa(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-qa", kind: "qa", system_prompt: qa_system_prompt(), model_name: model, provider: p, tools: [lexskill.make_lex_check_tool(), lexskill.make_lex_run_tool()], proc_cmd: "", a2a_url: "" }
}

fn demo(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-demo", kind: "demo", system_prompt: "You are the Demo agent for a software sprint. Given the QA-attested implementation, produce a concise stakeholder-facing summary: what was built, how it works, and what the key outcomes are. Write for a non-technical audience.", model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
}

fn scribe(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-scribe", kind: "scribe", system_prompt: "You are the Scribe for a software sprint. After reviewing the sprint trail and QA outcomes, produce a Digest: (1) lessons learned, (2) spec tightenings for next sprint, (3) a suggested starting graph topology for the next sprint. Be concrete and actionable.", model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
}

fn build(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-build", kind: "build", system_prompt: build_system_prompt(), model_name: model, provider: p, tools: [lexskill.make_lex_guidelines_tool(), lexskill.make_lex_check_tool()], proc_cmd: "", a2a_url: "" }
}

# Resolve a node role string to an AgentDef using a pre-computed Provider.
# Pure (no env effect) -- callers that have already resolved the provider use this.
fn for_role_with_provider(role :: Str, model :: Str, p :: prov.Provider) -> Option[runner.AgentDef] {
  let mk := fn (id :: Str, kind :: Str, system_prompt :: Str) -> runner.AgentDef {
    { id: id, kind: kind, system_prompt: system_prompt, model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
  }
  if role == "architect" {
    Some(mk("loom-architect", "architect", "You are a software design architect. Given a project request, produce a concise technical design specification in plain prose: describe the components, key functions or classes, their interfaces, and expected behaviour. Do not output JSON or sprint graphs. Write 2-4 paragraphs maximum."))
  } else {
    if role == "build" {
      Some({ id: "loom-build", kind: "build", system_prompt: build_system_prompt(), model_name: model, provider: p, tools: [lexskill.make_lex_guidelines_tool(), lexskill.make_lex_check_tool()], proc_cmd: "", a2a_url: "" })
    } else {
      if role == "qa" {
        Some({ id: "loom-qa", kind: "qa", system_prompt: qa_system_prompt(), model_name: model, provider: p, tools: [lexskill.make_lex_check_tool(), lexskill.make_lex_run_tool()], proc_cmd: "", a2a_url: "" })
      } else {
        if role == "demo" {
          Some(mk("loom-demo", "demo", "You are the Demo agent for a software sprint. Given the QA-attested implementation, produce a concise stakeholder-facing summary: what was built, how it works, and what the key outcomes are. Write for a non-technical audience."))
        } else {
          if role == "scribe" {
            Some(mk("loom-scribe", "scribe", "You are the Scribe for a software sprint. After reviewing the sprint trail and QA outcomes, produce a Digest: (1) lessons learned, (2) spec tightenings for next sprint, (3) a suggested starting graph topology for the next sprint. Be concrete and actionable."))
          } else {
            None
          }
        }
      }
    }
  }
}

# Resolve a node role string to an AgentDef.
fn for_role(role :: Str, model :: Str) -> [env] Option[runner.AgentDef] {
  if role == "architect" {
    Some(architect(model))
  } else {
    if role == "build" {
      Some(build(model))
    } else {
      if role == "qa" {
        Some(qa(model))
      } else {
        if role == "demo" {
          Some(demo(model))
        } else {
          if role == "scribe" {
            Some(scribe(model))
          } else {
            None
          }
        }
      }
    }
  }
}

