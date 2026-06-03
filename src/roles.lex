# roles.lex — AgentConfig definitions for the four loom orchestration roles.
#
# Architect  derives and refines the SprintGraph.
# QA         evaluates work and produces an attestation.
# Demo       summarises completed work for stakeholders.
# Scribe     produces the Digest: tightened specs + seed graph.
#
# M2: system prompts are minimal; tools list is empty (LLM text output only).
# M3: Architect gains graph-emit tool; roles gain lex-code worker tools.

import "lex-llm/src/provider" as prov
import "lex-llm/src/tool"     as t
import "lex-soft/src/runner"  as runner

fn make_provider() -> prov.Provider {
  prov.from_env()
}

fn architect(model :: Str) -> runner.AgentConfig {
  {
    id:           "loom-architect",
    kind:         "architect",
    system_prompt: "You are the Architect for a software sprint. Given a project request, produce a JSON sprint graph describing the agent nodes and edges needed to complete the work. Each node needs an id, a role, and a gate (a predicate the output must satisfy). Each edge needs from, to, and a handoff schema. Keep the graph minimal and executable.",
    model_name:   model,
    provider:     make_provider(),
    tools:        [],
  }
}

fn qa(model :: Str) -> runner.AgentConfig {
  {
    id:           "loom-qa",
    kind:         "qa",
    system_prompt: "You are the QA agent for a software sprint. Review the implementation output provided. Decide whether it satisfies the sprint goal. Reply with a structured verdict: PASS or FAIL, followed by a one-paragraph rationale. Be specific about what passes or fails.",
    model_name:   model,
    provider:     make_provider(),
    tools:        [],
  }
}

fn demo(model :: Str) -> runner.AgentConfig {
  {
    id:           "loom-demo",
    kind:         "demo",
    system_prompt: "You are the Demo agent for a software sprint. Given the QA-attested implementation, produce a concise stakeholder-facing summary: what was built, how it works, and what the key outcomes are. Write for a non-technical audience.",
    model_name:   model,
    provider:     make_provider(),
    tools:        [],
  }
}

fn scribe(model :: Str) -> runner.AgentConfig {
  {
    id:           "loom-scribe",
    kind:         "scribe",
    system_prompt: "You are the Scribe for a software sprint. After reviewing the sprint trail and QA outcomes, produce a Digest: (1) lessons learned, (2) spec tightenings for next sprint, (3) a suggested starting graph topology for the next sprint. Be concrete and actionable.",
    model_name:   model,
    provider:     make_provider(),
    tools:        [],
  }
}

# Resolve a node role string to an AgentConfig.
# Returns None for unknown roles so the orchestrator can surface the error.
fn build(model :: Str) -> runner.AgentConfig {
  {
    id:           "loom-build",
    kind:         "build",
    system_prompt: "You are the Build agent for a software sprint. Given the design produced by the Architect, implement the requested software. Produce working, well-structured code with brief inline comments where the logic is non-obvious. Output only the implementation.",
    model_name:   model,
    provider:     make_provider(),
    tools:        [],
  }
}

# Resolve a node role string to an AgentConfig.
# Returns None for unknown roles so the orchestrator can surface the error.
fn for_role(role :: Str, model :: Str) -> Option[runner.AgentConfig] {
  if role == "architect" {
    Some(architect(model))
  } else if role == "build" {
    Some(build(model))
  } else if role == "qa" {
    Some(qa(model))
  } else if role == "demo" {
    Some(demo(model))
  } else if role == "scribe" {
    Some(scribe(model))
  } else {
    None
  }
}
