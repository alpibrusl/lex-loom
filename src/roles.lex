# roles.lex — AgentConfig definitions for the four loom orchestration roles.
#
# Architect  derives and refines the SprintGraph.
# QA         evaluates work and produces an attestation.
# Demo       summarises completed work for stakeholders.
# Scribe     produces the Digest: tightened specs + seed graph.
#
# M2: system prompts are minimal; tools list is empty (LLM text output only).
# M3: Architect gains graph-emit tool; roles gain lex-code worker tools.

import "std.str"  as str
import "std.env"  as env
import "std.io"   as io
import "std.list" as list

import "lex-llm/src/provider"  as prov
import "lex-llm/src/providers" as providers
import "lex-llm/src/tool"      as t
import "lex-schema/schema"      as s
import "lex-schema/json_value"  as jv
import "lex-schema/error"       as e

import "lex-soft/src/runner" as runner

# Use OLLAMA if ANTHROPIC_API_KEY is absent; Anthropic otherwise.
fn make_provider() -> [env] prov.Provider {
  match env.get("ANTHROPIC_API_KEY") {
    Some(k) => if str.is_empty(k) { providers.ollama_local() } else { providers.anthropic() },
    None    => providers.ollama_local(),
  }
}

# Temp file path where the emit_graph tool writes the graph JSON.
# The orchestrator reads from this path after the handler returns.
fn graph_tmp_path(sprint_id :: Str) -> Str {
  str.join(["/tmp/loom-graph-", sprint_id, ".json"], "")
}

# The emit_graph tool — the Architect calls this instead of printing JSON.
# Writes the validated graph JSON to a temp file so the orchestrator can
# read it back after the LLM turn, bypassing the text extraction heuristic.
fn make_emit_graph_tool(sprint_id :: Str) -> t.Tool {
  let node_schema := { title: "Node", description: "A sprint graph node", fields: [
    s.required_str("id",   []),
    s.required_str("role", []),
    s.required_str("gate", []),
  ]}
  let edge_schema := { title: "Edge", description: "A sprint graph edge", fields: [
    s.required_str("from",    []),
    s.required_str("to",      []),
    s.required_str("handoff", []),
  ]}
  let params := { title: "EmitGraph", description: "Emit the sprint graph", fields: [
    s.required_str("id",    []),
    s.required_str("phase", []),
    s.required_array("nodes", s.KObject(node_schema), []),
    s.required_array("edges", s.KObject(edge_schema), []),
  ]}
  t.define(
    "emit_graph",
    "Emit the sprint graph. Call this ONCE with the complete graph JSON. Do not print JSON in your reply — call this tool instead.",
    params,
    fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
      let graph_json := jv.stringify(args)
      let path := graph_tmp_path(sprint_id)
      match io.write(path, graph_json) {
        Err(err) => Ok(JObj([("error", JStr(err))])),
        Ok(_)    => Ok(JObj([("status", JStr("graph_written")), ("path", JStr(path))])),
      }
    },
  )
}

fn architect(model :: Str) -> [env] runner.AgentConfig {
  architect_with_context(model, "", "")
}

# Architect variant carrying tightened-spec context from a prior Digest.
fn architect_with_context(model :: Str, specs_context :: Str, sprint_id :: Str) -> [env] runner.AgentConfig {
  let tool := if str.is_empty(sprint_id) { [] } else { [make_emit_graph_tool(sprint_id)] }
  {
    id:            "loom-architect",
    kind:          "architect",
    system_prompt: str.concat(
      "You are the Architect for a software sprint. Given a project request, call the emit_graph tool ONCE with the complete sprint graph. Do NOT output JSON in your reply — use the tool. Each node needs an id, a role, and a gate. Each edge needs from, to, and a handoff.",
      specs_context,
    ),
    model_name:    model,
    provider:      make_provider(),
    tools:         tool,
  }
}

fn qa(model :: Str) -> [env] runner.AgentConfig {
  { id: "loom-qa", kind: "qa", system_prompt: "You are the QA agent for a software sprint. Review the implementation output provided. Decide whether it satisfies the sprint goal. Reply with a structured verdict: PASS or FAIL, followed by a one-paragraph rationale. Be specific about what passes or fails.", model_name: model, provider: make_provider(), tools: [] }
}

fn demo(model :: Str) -> [env] runner.AgentConfig {
  { id: "loom-demo", kind: "demo", system_prompt: "You are the Demo agent for a software sprint. Given the QA-attested implementation, produce a concise stakeholder-facing summary: what was built, how it works, and what the key outcomes are. Write for a non-technical audience.", model_name: model, provider: make_provider(), tools: [] }
}

fn scribe(model :: Str) -> [env] runner.AgentConfig {
  { id: "loom-scribe", kind: "scribe", system_prompt: "You are the Scribe for a software sprint. After reviewing the sprint trail and QA outcomes, produce a Digest: (1) lessons learned, (2) spec tightenings for next sprint, (3) a suggested starting graph topology for the next sprint. Be concrete and actionable.", model_name: model, provider: make_provider(), tools: [] }
}

# Resolve a node role string to an AgentConfig.
# Returns None for unknown roles so the orchestrator can surface the error.
fn build(model :: Str) -> [env] runner.AgentConfig {
  { id: "loom-build", kind: "build", system_prompt: "You are the Build agent for a software sprint. Given the design produced by the Architect, implement the requested software. Produce working, well-structured code with brief inline comments where the logic is non-obvious. Output only the implementation.", model_name: model, provider: make_provider(), tools: [] }
}

# Resolve a node role string to an AgentConfig using a pre-computed provider.
# Pure (no env effect) — callers that have already resolved the provider use this.
fn for_role_with_provider(role :: Str, model :: Str, provider :: prov.Provider) -> Option[runner.AgentConfig] {
  let mk := fn (id :: Str, kind :: Str, system_prompt :: Str) -> runner.AgentConfig {
    { id: id, kind: kind, system_prompt: system_prompt, model_name: model, provider: provider, tools: [] }
  }
  if role == "architect" {
    Some(mk("loom-architect", "architect", "You are the Architect for a software sprint. Given a project request, produce a JSON sprint graph describing the agent nodes and edges needed to complete the work. Each node needs an id, a role, and a gate (a predicate the output must satisfy). Each edge needs from, to, and a handoff schema. Keep the graph minimal and executable."))
  } else {
    if role == "build" {
      Some(mk("loom-build", "build", "You are the Build agent for a software sprint. Given the design produced by the Architect, implement the requested software. Produce working, well-structured code with brief inline comments where the logic is non-obvious. Output only the implementation."))
    } else {
      if role == "qa" {
        Some(mk("loom-qa", "qa", "You are the QA agent for a software sprint. Review the implementation output provided. Decide whether it satisfies the sprint goal. Reply with a structured verdict: PASS or FAIL, followed by a one-paragraph rationale. Be specific about what passes or fails."))
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

# Resolve a node role string to an AgentConfig.
# Returns None for unknown roles so the orchestrator can surface the error.
fn for_role(role :: Str, model :: Str) -> [env] Option[runner.AgentConfig] {
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

