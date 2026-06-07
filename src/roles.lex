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

import "./agent/runner" as runner

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

# Provider priority: Vertex AI > Anthropic > Ollama
# Vertex AI is selected when VERTEX_ACCESS_TOKEN and VERTEX_PROJECT are both set.
fn make_provider() -> [env] prov.Provider {
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

fn make_provider_no_vertex() -> [env] prov.Provider {
  match env.get("ANTHROPIC_API_KEY") {
    Some(k) => if str.is_empty(k) {
      make_ollama_provider()
    } else {
      providers.anthropic()
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
  { id: "loom-architect", kind: "architect", system_prompt: "You are a software design architect. Given a project request, produce a concise technical design specification in plain prose: describe the components, key functions or classes, their interfaces, and expected behaviour. Do not output JSON or sprint graphs. Write 2-4 paragraphs maximum.", model_name: model, provider: p, tools: [] }
}

fn architect_with_context(model :: Str, specs_context :: Str, sprint_id :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-architect", kind: "architect", system_prompt: str.concat("You are the Architect for a software sprint. Given a project request, output ONLY a JSON sprint graph -- no prose, no markdown fences. Each node needs an id, a role, and a gate. Each edge needs from, to, and a handoff. Shape: {\"id\":\"...\",\"phase\":\"Design\",\"nodes\":[{\"id\":\"...\",\"role\":\"...\",\"gate\":\"...\"}],\"edges\":[{\"from\":\"...\",\"to\":\"...\",\"handoff\":\"schema {}\"}]}", specs_context), model_name: model, provider: p, tools: [] }
}

fn qa(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-qa", kind: "qa", system_prompt: "You are the QA agent for a software sprint. Evaluate the implementation ONLY against the sprint goal in the user message.\n\nFORBIDDEN: Do NOT apply Lex language criteria (examples{} blocks, effect rows, match arm coverage) unless the goal explicitly asks for Lex code. Do NOT invent criteria absent from the goal.\n\nOutput ONLY a JSON object with exactly this shape — no prose, no markdown fences, no text before or after:\n{\"verdict\":\"PASS\",\"reason\":\"one paragraph explaining your verdict in terms of the sprint goal\"}\n\nUse \"PASS\" if the implementation satisfies the sprint goal, \"FAIL\" otherwise. The first character of your response must be '{'.", model_name: model, provider: p, tools: [] }
}

fn demo(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-demo", kind: "demo", system_prompt: "You are the Demo agent for a software sprint. Given the QA-attested implementation, produce a concise stakeholder-facing summary: what was built, how it works, and what the key outcomes are. Write for a non-technical audience.", model_name: model, provider: p, tools: [] }
}

fn scribe(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-scribe", kind: "scribe", system_prompt: "You are the Scribe for a software sprint. After reviewing the sprint trail and QA outcomes, produce a Digest: (1) lessons learned, (2) spec tightenings for next sprint, (3) a suggested starting graph topology for the next sprint. Be concrete and actionable.", model_name: model, provider: p, tools: [] }
}

fn build(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-build", kind: "build", system_prompt: "You are the Build agent for a software sprint. Given the design produced by the Architect, implement the requested software. Produce working, well-structured code with brief inline comments where the logic is non-obvious. Output only the implementation.", model_name: model, provider: p, tools: [] }
}

# Resolve a node role string to an AgentDef using a pre-computed Provider.
# Pure (no env effect) -- callers that have already resolved the provider use this.
fn for_role_with_provider(role :: Str, model :: Str, p :: prov.Provider) -> Option[runner.AgentDef] {
  let mk := fn (id :: Str, kind :: Str, system_prompt :: Str) -> runner.AgentDef {
    { id: id, kind: kind, system_prompt: system_prompt, model_name: model, provider: p, tools: [] }
  }
  if role == "architect" {
    Some(mk("loom-architect", "architect", "You are a software design architect. Given a project request, produce a concise technical design specification in plain prose: describe the components, key functions or classes, their interfaces, and expected behaviour. Do not output JSON or sprint graphs. Write 2-4 paragraphs maximum."))
  } else {
    if role == "build" {
      Some(mk("loom-build", "build", "You are the Build agent for a software sprint. Given the design produced by the Architect, implement the requested software. Produce working, well-structured code with brief inline comments where the logic is non-obvious. Output only the implementation."))
    } else {
      if role == "qa" {
        Some(mk("loom-qa", "qa", "You are the QA agent for a software sprint. Evaluate the implementation ONLY against the sprint goal in the user message.\n\nFORBIDDEN: Do NOT apply Lex language criteria (examples{} blocks, effect rows, match arm coverage) unless the goal explicitly asks for Lex code. Do NOT invent criteria absent from the goal.\n\nOutput ONLY a JSON object with exactly this shape — no prose, no markdown fences, no text before or after:\n{\"verdict\":\"PASS\",\"reason\":\"one paragraph explaining your verdict in terms of the sprint goal\"}\n\nUse \"PASS\" if the implementation satisfies the sprint goal, \"FAIL\" otherwise. The first character of your response must be '{'."))
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

