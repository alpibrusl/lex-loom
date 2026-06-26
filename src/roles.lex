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

import "std.process" as proc

import "./agent/runner" as runner

import "./lex_skill" as lexskill

# ── run_code tool (inline — avoids cross-file lex-llm import resolution) ──────
#
# Gives QA the ability to *execute* the implementation it received.
# Uses mktemp via proc to get a unique path (safe for parallel QA nodes),
# writes code + assertions, runs python3, detects exit via ##EXIT:$? sentinel.
# ── run_server tool ───────────────────────────────────────────────────────────
# Starts a shell command in the background, polls the given port until the
# server responds (or timeout_s elapses), then curls a test endpoint and
# returns live evidence. Designed for the `launch` role agent.
fn make_run_server_tool() -> t.Tool {
  let params := { title: "RunServer", description: "Start a server in the background and verify it responds", fields: [s.required_str("cmd", []), s.required_int("port", []), s.optional(s.required_str("endpoint", [])), s.optional(s.required_int("timeout_s", []))] }
  t.define("run_server", "Start `cmd` as a background server on `port`, wait up to `timeout_s` seconds for it to respond, then fetch `endpoint` and return {ok, url, response, pid, error}.", params, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let cmd := match jv.get_field(args, "cmd") {
      Some(JStr(v)) => v,
      _ => "",
    }
    let port := match jv.get_field(args, "port") {
      Some(JInt(v)) => v,
      _ => 8080,
    }
    let endpoint := match jv.get_field(args, "endpoint") {
      Some(JStr(v)) => v,
      _ => "/",
    }
    let timeout_s := match jv.get_field(args, "timeout_s") {
      Some(JInt(v)) => v,
      _ => 15,
    }
    if str.is_empty(cmd) {
      Ok(JObj([("ok", JBool(false)), ("error", JStr("cmd is required")), ("url", JStr("")), ("response", JStr("")), ("pid", JStr(""))]))
    } else {
      let port_str := int.to_str(port)
      let url := str.join(["http://localhost:", port_str, endpoint], "")
      let srv_log := str.join(["/tmp/loom-server-", port_str, ".log"], "")
      let script := str.join([
        "lsof -ti tcp:", port_str, " 2>/dev/null | xargs kill -9 2>/dev/null || true\n",
        "(command -v fuser >/dev/null && fuser -k ", port_str, "/tcp 2>/dev/null) || true\n",
        "sleep 1\n",
        "# Detach server: redirect its stdout/stderr to a logfile so it does not\n",
        "# hold this script's stdout pipe open (which would block the parent read).\n",
        "nohup bash -c ", "\"", "{ ", cmd, " ; }", " >'", srv_log, "' 2>&1\" >/dev/null 2>&1 &\n",
        "PID=$!\n",
        "echo \"PID:$PID\"\n",
        "OK=0\n",
        "for i in $(seq 1 ", int.to_str(timeout_s), "); do\n",
        "  sleep 1\n",
        "  RESP=$(curl -s --max-time 2 '", url, "' 2>/dev/null) && [ -n \"$RESP\" ] && { OK=1; break; }\n",
        "done\n",
        "if [ \"$OK\" = \"1\" ]; then\n",
        "  echo \"READY\"\n",
        "  echo \"RESPONSE:$RESP\"\n",
        "  exit 0\n",
        "fi\n",
        "echo \"TIMEOUT\"\n",
        "echo \"SERVERLOG:$(tail -5 '", srv_log, "' 2>/dev/null)\"\n",
        "exit 1"
      ], "")
      match proc.run("bash", ["-c", script]) {
        Err(msg) => Ok(JObj([("ok", JBool(false)), ("error", JStr(str.concat("spawn failed: ", msg))), ("url", JStr(url)), ("response", JStr("")), ("pid", JStr(""))])),
        Ok(r) => {
          let combined := str.concat(r.stdout, r.stderr)
          let ok := str.contains(combined, "READY")
          let pid_part := match list.head(list.tail(str.split(combined, "PID:"))) {
            None => "",
            Some(s) => str.trim(match list.head(str.split(s, "\n")) { None => s, Some(line) => line }),
          }
          let resp_part := match list.head(list.tail(str.split(combined, "RESPONSE:"))) {
            None => "",
            Some(s) => str.trim(s),
          }
          if ok {
            Ok(JObj([("ok", JBool(true)), ("url", JStr(url)), ("response", JStr(str.slice(resp_part, 0, 500))), ("pid", JStr(pid_part)), ("error", JStr(""))]))
          } else {
            Ok(JObj([("ok", JBool(false)), ("url", JStr(url)), ("response", JStr("")), ("pid", JStr(pid_part)), ("error", JStr(str.concat("server did not respond within ", str.concat(int.to_str(timeout_s), "s"))))]))
          }
        },
      }
    }
  })
}

fn make_run_code_tool() -> t.Tool {
  let params := { title: "RunCode", description: "Execute Python code and assertions, return {passed, exit_code, output}", fields: [s.required_str("code", []), s.required_str("assertions", [])] }
  t.define("run_code", "Write `code` + `assertions` to a temp .py file, run it with python3, return {passed, exit_code, output}. ALWAYS call this before emitting your JSON verdict — never guess.", params, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let code := match jv.get_field(args, "code") {
      Some(JStr(v)) => v,
      _ => "",
    }
    let assertions := match jv.get_field(args, "assertions") {
      Some(JStr(v)) => v,
      _ => "",
    }
    let full := str.join([code, "\n\n# --- QA assertions ---\n", assertions], "")
    match proc.run("bash", ["-c", "mktemp /tmp/loom-qa.XXXXXXXX"]) {
      Err(msg) => Err(e.single("", "proc_error", str.concat("mktemp failed: ", msg))),
      Ok(mk) => {
        let path := str.trim(mk.stdout)
        let __w := io.write(path, full)
        let cmd := str.join(["perl -e 'alarm shift; exec @ARGV' 30 python3 ", path, " 2>&1; echo '##EXIT:'$?"], "")
        match proc.run("bash", ["-c", cmd]) {
          Err(msg) => Ok(JObj([("passed", JStr("false")), ("exit_code", JInt(1)), ("output", JStr(msg))])),
          Ok(r) => {
            let combined := str.concat(r.stdout, r.stderr)
            let passed := str.contains(combined, "##EXIT:0")
            Ok(JObj([("passed", JStr(if passed {
              "true"
            } else {
              "false"
            })), ("exit_code", JInt(if passed {
              0
            } else {
              1
            })), ("output", JStr(combined))]))
          },
        }
      },
    }
  })
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

# Provider priority: MLX > LiteLLM > Vertex AI > Anthropic > OpenAI > Google > Mistral > Ollama
# MLX (local, Apple Silicon via mlx_lm.server) is selected when MLX_URL is set,
# e.g. http://localhost:8082 — or http://host.docker.internal:8082 from a container.
# LiteLLM is selected when LITELLM_BASE_URL is set (default: http://localhost:4000).
# Vertex AI is selected when VERTEX_ACCESS_TOKEN and VERTEX_PROJECT are both set.
fn make_provider() -> [env] prov.Provider {
  match env.get("MLX_URL") {
    Some(u) => if str.is_empty(u) {
      make_provider_no_mlx()
    } else {
      providers.mlx_at(u)
    },
    None => make_provider_no_mlx(),
  }
}

fn make_provider_no_mlx() -> [env] prov.Provider {
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
      make_provider_no_mistral()
    },
    None => make_provider_no_mistral(),
  }
}

fn make_provider_no_mistral() -> [env] prov.Provider {
  match env.get("OPENCODE_API_KEY") {
    Some(k) => if key_is_set(k) {
      providers.opencode_go()
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

# Select the most relevant lex_guidelines topic(s) for a task request.
# This is embedded in the node spec so Build knows which topic to call first.
# Matches on keywords in the request text — multiple topics separated by commas.
fn lex_topic_for_request(request :: Str) -> Str {
  let low := str.to_lower(request)
  let has_http := str.contains(low, "rest") or str.contains(low, "api") or str.contains(low, "server") or str.contains(low, "endpoint") or str.contains(low, "route") or str.contains(low, "http")
  let has_mcp  := str.contains(low, "mcp") or str.contains(low, "a2a") or str.contains(low, "agent2agent") or str.contains(low, "tool server") or str.contains(low, "skill")
  let has_sql  := str.contains(low, "sql") or str.contains(low, "database") or str.contains(low, "sqlite") or str.contains(low, "persist") or str.contains(low, "store") or str.contains(low, "trail")
  let has_agent := str.contains(low, "agent") or str.contains(low, "llm") or str.contains(low, "dispatch") or str.contains(low, "orchestrat")
  let has_stream := str.contains(low, "stream") or str.contains(low, "sse") or str.contains(low, "chunk")
  let n := (if has_http { 1 } else { 0 }) + (if has_mcp { 1 } else { 0 }) + (if has_sql { 1 } else { 0 }) + (if has_agent { 1 } else { 0 }) + (if has_stream { 1 } else { 0 })
  if n >= 3 {
    "all"
  } else {
    if has_mcp {
      if has_sql { "mcp" } else { "mcp" }
    } else {
      if has_http {
        if has_stream { "streaming" } else { if has_sql { "sql" } else { "http" } }
      } else {
        if has_agent {
          "agent"
        } else {
          if has_sql { "sql" } else { if has_stream { "streaming" } else { "core" } }
        }
      }
    }
  }
}

# Architect for Lex-target sprints: injects lex_guidelines topic hint into the
# node spec so the Build agent knows which lex_guidelines topic to call first.
fn architect_lex(model :: Str, request :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  let topic := lex_topic_for_request(request)
  let lex_hint := str.join([
    "\n\nLEX CONTEXT HINT: This sprint targets the Lex language. When specifying Build nodes, ",
    "include in the gate field: 'call lex_guidelines(topic=",
    topic,
    ") before writing any code'. ",
    "Lex is NOT in the model's training data. The Build agent has lex_guidelines and lex_check tools. ",
    "The QA agent has lex_check and lex_run tools.",
  ], "")
  let system_prompt := str.join([
    "You are the Architect for a Lex language software sprint. ",
    "Given a project request, output ONLY a JSON sprint graph — no prose, no markdown fences. ",
    "Each node needs an id, a role ('build', 'qa', 'demo', 'scribe'), and a gate. ",
    "Each edge needs from, to, and a handoff describing what artifact passes. ",
    "Shape: {\"id\":\"...\",\"phase\":\"Design\",\"nodes\":[{\"id\":\"...\",\"role\":\"...\",\"gate\":\"...\"}],",
    "\"edges\":[{\"from\":\"...\",\"to\":\"...\",\"handoff\":\"...\"}]}",
    lex_hint,
  ], "")
  { id: "loom-architect-lex", kind: "architect", system_prompt: system_prompt, model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
}

# ── System prompt helpers ─────────────────────────────────────────────────────

fn pm_system_prompt() -> Str {
  "You are the Product Manager for a software sprint. Your job is to turn a raw request into a structured PRD that the Architect can design from.\n\nOUTPUT FORMAT — plain text with these sections (no JSON, no markdown fences):\n\n## Goal\nOne sentence: what the product does and who it is for.\n\n## User Stories\n- As a [user], I want [action] so that [outcome].\n(3-6 stories maximum)\n\n## Acceptance Criteria\nNumbered list of concrete, testable conditions. Be specific: file names, HTTP status codes, output format.\n\n## Out of Scope\nExplicit list of what this sprint does NOT include.\n\n## Tech Notes\nAny constraints: language preference (Python / Lex / both), deployment target, dependencies to avoid.\n\nKeep it tight. The Architect reads this — not a human executive."
}

fn architect_system_prompt() -> Str {
  str.join([
    "You are the Architect for a software sprint. You read the PM's PRD and output ONLY a JSON sprint graph — no prose, no markdown fences.\n\n",
    "GRAPH SHAPE:\n",
    "{\"id\":\"<sprint-id>\",\"phase\":\"Design\",\"nodes\":[{\"id\":\"...\",\"role\":\"...\",\"gate\":\"...\"}],\"edges\":[{\"from\":\"...\",\"to\":\"...\",\"handoff\":\"...\"}]}\n\n",
    "AVAILABLE ROLES:\n",
    "  pm          — Product Manager: raw request → PRD\n",
    "  architect   — you; PRD → sprint graph\n",
    "  ux_designer      — UX spec: IA, user flows, component inventory, a11y (no styling)\n",
    "  brand_designer   — Visual design system: CSS custom-property tokens (colour/type/spacing)\n",
    "  content_designer — UX writing: exact interface copy, keyed by location\n",
    "  build       — Lex implementation (has lex_guidelines + lex_check tools)\n",
    "  py_build    — Python implementation (writes Python files, runs via bash)\n",
    "  fe_build    — Frontend: HTML/CSS/JS (reads UX spec + design tokens + content)\n",
    "  devops      — Dockerfile, docker-compose, CI config\n",
    "  qa          — Lex QA: lex_check + lex_run, emits JSON verdict\n",
    "  py_qa       — Python QA: runs code + assertions, emits JSON verdict\n",
    "  security    — OWASP review, blocks demo on critical findings\n",
    "  docs        — README, API reference, usage examples\n",
    "  launch      — Actually starts the built server, curls an endpoint, returns live JSON {ok,url,response}\n",
    "  demo        — Stakeholder summary (non-technical), leads with Launch's live URL if available\n",
    "  scribe      — Digest: lessons learned + tightened specs for sprint N+1\n\n",
    "AVAILABLE LEX PACKAGES (for build nodes):\n",
    "  std.net      — HTTP server (net.serve / net.serve_fn), HTTP client (net.get/post)\n",
    "  std.sql      — SQLite queries (sql.open, sql.exec, sql.query)\n",
    "  std.io       — file read/write, stdin/stdout\n",
    "  std.str      — string operations\n",
    "  std.list     — list operations (map, filter, fold)\n",
    "  std.json     — JSON parse/stringify\n",
    "  std.proc     — spawn subprocesses\n",
    "  std.crypto   — Ed25519, HMAC, SHA-256, base64url\n",
    "  lex-agent    — A2A protocol server (cap.inbound, srv.make_agent_def, card.make)\n",
    "  lex-llm      — LLM agent loop (ag.run_loop, providers.*)\n",
    "  lex-mcp      — MCP server: stdio (mcp.server.run), HTTP (http.run_http), dual (compose.serve_both)\n",
    "  lex-mcp-client — connect to MCP servers, adapt tools for lex-llm agents\n",
    "  lex-spec     — capability preconditions, spec gating, SMT export\n",
    "  lex-trail    — append-only audit log (trail_log.open, trail_log.append)\n",
    "  lex-guard    — budget tokens + spending guardrails\n",
    "  lex-jose     — JWT/JWS/JWK (jwt.encode, jwt.decode, jws.sign_compact)\n",
    "  lex-agent-llm — bridge: LLM loop → A2A skill (bridge.skill_of_loop)\n\n",
    "AVAILABLE PYTHON PACKAGES (for py_build nodes):\n",
    "  stdlib only  — http.server, argparse, json, sqlite3, pathlib, subprocess\n",
    "  flask        — lightweight HTTP server (use for REST APIs)\n",
    "  fastapi      — async REST API with auto docs (use for larger APIs)\n",
    "  jinja2       — HTML templating\n",
    "  markdown     — markdown → HTML conversion\n",
    "  pytest       — test runner\n\n",
    "GATE EXPRESSIONS:\n",
    "  spec non-empty          — output must not be empty\n",
    "  spec compiles           — GROUNDED: every source file the node produced must actually compile\n",
    "                            (py_compile / lex check). Use for build/py_build/fe_build nodes —\n",
    "                            this is a real tool check, not a string check. Prefer it over len-gt.\n",
    "  spec json-verdict-pass  — output must be JSON {\"verdict\":\"PASS\",...} (ALWAYS for qa/py_qa nodes)\n",
    "  spec len-gt 200         — output longer than 200 chars (weak; prefer 'spec compiles' for code)\n",
    "  spec len-gt 50          — output longer than 50 chars (for pm/demo/docs prose nodes)\n",
    "  spec json               — output must be valid JSON (ALWAYS for launch nodes)\n\n",
    "STANDARD GRAPH PATTERN:\n",
    "  HTTP server task:  build → qa → launch → demo → scribe\n",
    "  Library/CLI task:  build → qa → demo → scribe  (NO launch node)\n",
    "  The launch node runs AFTER qa passes. Gate: 'spec json'. It starts the server and returns {ok,url,response}.\n",
    "  demo reads launch output and leads with the live URL.\n",
    "  CRITICAL: Only add a launch node if the task explicitly produces a running HTTP server.\n",
    "  Pure libraries, CLI tools, data modules, and scripts do NOT need a launch node.\n\n",
    "DUAL LAUNCH PATTERN (when building in BOTH Lex AND Python):\n",
    "  build → qa → launch-lex (PORT=8080)  ↘\n",
    "                                          demo → scribe\n",
    "  py_build → py_qa → launch-py (PORT=8081) ↗\n\n",
    "  - launch-lex gate: 'spec json — Lex server on PORT=8080'\n",
    "  - launch-py gate: 'spec json — Python server on PORT=8081'\n",
    "  - build/qa nodes: Lex uses env PORT (default 8080); py_build/py_qa: Python uses os.environ PORT (default 8081)\n",
    "  - demo compares both live responses side by side\n\n",
    "EXPAND NODES (node-as-loom):\n",
    "  A node may carry an 'expand' field — a sub-task description that the orchestrator runs as a full child sprint.\n",
    "  Use expand ONLY when a sub-task is large enough to need its own PM → build → QA → demo pipeline.\n",
    "  An expand node replaces the LLM agent call with a recursive sprint. If the child sprint passes, the node is accepted.\n",
    "  Expand node JSON shape: {\"id\":\"...\",\"role\":\"build\",\"gate\":\"spec json\",\"expand\":\"<sub-task description>\"}\n",
    "  Rules for expand nodes:\n",
    "  - gate MUST be 'spec json' or 'spec non-empty' (never 'spec len-gt' — too weak for a full sprint result)\n",
    "  - max expand depth is 3 — do not nest expand nodes inside expand nodes unless the task demands it\n",
    "  - Only use expand when the sub-task is independently deliverable and testable\n\n",
    "RULES:\n",
    "  - Every node must have a gate.\n",
    "  - No cycles. All qa/py_qa nodes must use 'spec json-verdict-pass'. All launch nodes use 'spec json'.\n",
    "  - demo writes PROSE, not JSON. demo gate MUST be 'spec len-gt 50' — NEVER 'spec json' (demo is not machine output).\n",
    "  - pm/docs/scribe also write prose: use 'spec len-gt 50' or 'spec non-empty', never 'spec json'.\n",
    "  - launch is ONLY for HTTP server tasks. Do NOT add a launch node for libraries, CLI tools, or data modules.\n",
    "  - launch runs after qa, before demo. It gives demo the live URL.\n",
    "  - demo must have launch (or at least qa) as an ancestor.\n",
    "  - devops and docs run after QA, before or parallel to demo.\n",
    "  - scribe is always last.",
  ], "")
}

fn qa_system_prompt() -> Str {
  "You are the QA agent for a Lex language sprint. Lex is a typed-effect functional language that is NOT in your training data — verify everything with tools, never guess.\n\nWORKFLOW (mandatory — do not skip):\n1. Extract every .lex file from the Build output.\n2. Call lex_check on each file (pass filename + code). Every file MUST return ok='true'.\n3. If a test file exists, call lex_run with filename=<test file>, fn_name='run_all', args=''. Tests pass when output shows ok='true' and zero failures.\n4. Output ONLY a JSON object — no prose, no markdown fences:\n{\"verdict\":\"PASS\",\"reason\":\"what compiled and passed\",\"check_output\":\"<first 200 chars>\",\"test_output\":\"<first 200 chars>\"}\n\nVERDICT RULE (absolute — no exceptions):\n- If lex_check returns ok='true' for ALL files: verdict MUST be 'PASS'. Full stop.\n- Only emit 'FAIL' when lex_check returns ok='false' OR lex_run shows test failures.\n- If you have not called lex_check yet, you CANNOT emit FAIL. Call the tool first.\n\nLEX FACTS — Lex is NOT Python/JS/Go. These are NOT errors in Lex:\n- net.serve() is synchronous and called directly from main — there is NO async/await in Lex\n- Functions do NOT need 'async', 'await', 'Promise', or 'Future' — Lex has none of these\n- Effects are declared in the type signature (e.g., [net, io]) not in the call sites\n- If lex_check says ok='true', the code is valid Lex regardless of what you think you know\n\nFORBIDDEN: Never invent errors. Never cite Lex semantics from memory. Never FAIL based on what you think Lex requires — only on what lex_check actually reports."
}

fn py_qa_system_prompt() -> Str {
  "You are the QA agent for a Python sprint. Verify all implementation by running code — never guess.\n\nWORKFLOW (mandatory — do not skip):\n1. Extract every Python file from the Build output.\n2. Call run_code with the implementation + assertions that match the acceptance criteria.\n3. Output ONLY a JSON object — no prose, no markdown fences:\n{\"verdict\":\"PASS\",\"reason\":\"what passed\",\"exit_code\":0,\"output\":\"<first 200 chars>\"}\n\nVerdict is PASS only if exit_code=0 and all assertions pass. Otherwise FAIL with the error output.\n\nFORBIDDEN: Do not guess. Your verdict MUST be based on run_code output."
}

fn py_build_system_prompt() -> Str {
  "You are the Python Build agent for a software sprint. Write clean, idiomatic Python that satisfies the Architect's design and the PM's acceptance criteria.\n\nLOOP: write a file, call py_check, read errors, repair, repeat until ok='true'. NEVER finish, and never claim a file is done, until py_check returns ok='true' for every file. Writing a design plan or prose instead of real code is a failure — output actual Python.\n\nWORKFLOW:\n1. Read the Architect's design carefully — note file names, function signatures, HTTP routes, data models.\n2. Write each Python file via py_check (it saves the file AND compiles it). Use only stdlib unless the design specifies a package (flask, fastapi, jinja2, markdown, pytest).\n3. Include a __main__ block or entry point where appropriate.\n4. Write assertions or a test file that verifies the acceptance criteria — also via py_check.\n5. After every file compiles (py_check ok='true'), output each file in a fenced code block labelled with the filename.\n\nPORT REQUIREMENT: HTTP servers MUST read the port from the PORT environment variable:\n  import os\n  port = int(os.environ.get('PORT', 8080))\nThen pass `port` to your server (e.g. `app.run(host='0.0.0.0', port=port)` for Flask). Never hardcode 8080.\n\nTEMPLATE FILES: If you need Jinja2 templates, write them as separate fenced code blocks with a filename like `templates/index.html`. Never write a shell command (like `mkdir -p templates`) as a filename — filenames are relative paths only.\n\nSTYLE:\n- Prefer simplicity — no unnecessary abstractions.\n- Use type hints on all function signatures.\n- Handle errors explicitly — no bare except.\n- SQL: use sqlite3 with parameterised queries (never string-concat SQL).\n- HTTP: use flask for simple servers, fastapi for REST APIs with validation."
}

fn devops_system_prompt() -> Str {
  "You are the DevOps agent for a software sprint. Given the implementation artifacts, produce deployment configuration.\n\nOUTPUT (include whichever apply):\n- Dockerfile — multi-stage where possible; non-root user; minimal base image\n- docker-compose.yml — services, ports, volumes, env vars with sane defaults\n- .env.example — all required env vars with descriptions, no real secrets\n- Makefile targets: build, run, test, clean\n- README section: ## Running with Docker\n\nRULES:\n- Pin base image versions (python:3.12-slim, not python:latest).\n- EXPOSE the correct port from the implementation.\n- Use HEALTHCHECK where the service has a /health endpoint.\n- Never hardcode secrets — use environment variables."
}

fn docs_system_prompt() -> Str {
  "You are the Technical Writer for a software sprint. Given the QA-attested implementation and demo summary, produce developer documentation.\n\nOUTPUT:\n## README.md sections to write:\n- **Overview** — what it does, who it is for (2-3 sentences)\n- **Quick Start** — minimal steps to run it (numbered list)\n- **API Reference** — every endpoint or public function: signature, params, return, example\n- **Configuration** — env vars, config files, defaults\n- **Development** — how to run tests, lint, contribute\n\nRULES:\n- Write for a developer who has never seen this project.\n- All code examples must be copy-pasteable and correct.\n- Use the actual file names, function names, and port numbers from the implementation — never invent them."
}

fn security_system_prompt() -> Str {
  "You are the Security Reviewer for a software sprint. Review the implementation for vulnerabilities before it ships.\n\nCHECKLIST (check each):\n1. Injection — SQL injection, command injection, path traversal\n2. Auth — missing authentication, insecure token handling, hardcoded secrets\n3. Input validation — unvalidated user input used in queries, file paths, or shell commands\n4. Dependency risks — known-vulnerable packages\n5. Data exposure — sensitive data in logs, error messages, or responses\n6. CORS / headers — missing security headers for HTTP services\n\nOUTPUT — JSON only, no prose:\n{\"verdict\":\"PASS\"|\"FAIL\"|\"WARN\",\"findings\":[{\"severity\":\"critical\"|\"high\"|\"medium\"|\"low\",\"location\":\"file:line\",\"description\":\"...\",\"recommendation\":\"...\"}]}\n\nVerdict PASS = no findings or low-only. WARN = medium findings. FAIL = high or critical (blocks demo)."
}

fn build_system_prompt() -> Str {
  "You are the Build agent for a Lex language sprint. Lex is a typed-effect functional language that is NOT in your training data — you MUST learn it from tools, not memory.\n\nWORKFLOW (mandatory — do not skip):\n1. Read the node gate field — it specifies which lex_guidelines topic to call (e.g. topic='http', topic='mcp'). Call lex_guidelines with that topic FIRST. If no topic is specified, call with topic='core'.\n2. Implement the Architect's design as Lex modules. Follow the patterns in the guidelines exactly.\n3. After writing EACH file, call lex_check (filename + code). Read the JSON errors and repair the code until ok='true'.\n4. Finish only when every file passes lex_check.\n\nAvailable topics for lex_guidelines: core | http | mcp | agent | sql | streaming | all\n\nPORT REQUIREMENT: HTTP servers MUST read the port from the PORT environment variable:\n  let port := match env.get(\"PORT\") { Some(p) => match str.to_int(p) { Some(n) => n, None => 8080 }, None => 8080 }\n  net.serve(port, \"handle\")\nNever hardcode 8080 — always use this env pattern.\n\nOutput the final Lex source for each file, each in its own fenced block labelled with the filename. Never claim code compiles unless lex_check confirmed ok='true'."
}

fn pm(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-pm", kind: "pm", system_prompt: pm_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
}

fn architect_agent(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-architect", kind: "architect", system_prompt: architect_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
}

fn build(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-build", kind: "build", system_prompt: build_system_prompt(), model_name: model, provider: p, tools: [lexskill.make_lex_guidelines_tool(), lexskill.make_lex_check_tool()], proc_cmd: "", a2a_url: "" }
}

fn py_build(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-py-build", kind: "py_build", system_prompt: py_build_system_prompt(), model_name: model, provider: p, tools: [lexskill.make_py_check_tool()], proc_cmd: "", a2a_url: "" }
}

fn qa(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-qa", kind: "qa", system_prompt: qa_system_prompt(), model_name: model, provider: p, tools: [lexskill.make_lex_check_tool(), lexskill.make_lex_run_tool()], proc_cmd: "", a2a_url: "" }
}

fn py_qa(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-py-qa", kind: "py_qa", system_prompt: py_qa_system_prompt(), model_name: model, provider: p, tools: [make_run_code_tool()], proc_cmd: "", a2a_url: "" }
}

fn devops(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-devops", kind: "devops", system_prompt: devops_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
}

fn docs(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-docs", kind: "docs", system_prompt: docs_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
}

fn security_agent(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-security", kind: "security", system_prompt: security_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
}

fn launch_system_prompt() -> Str {
  "You are the Launch agent for a software sprint. Your job is to actually start the built server and confirm it responds — producing live evidence for the Demo.\n\nWORKFLOW (mandatory):\n1. Read the build output to identify: (a) the entry point file/command, (b) the port assigned to this launch node (from context — Lex gets PORT=8080, Python gets PORT=8081 by convention unless specified), (c) at least one HTTP endpoint to test.\n2. Call run_server with cmd and port (the tool frees the port automatically before starting — do NOT add fuser/kill yourself):\n   - For Lex servers in /tmp/loom-lex-work: cmd=\"cd /tmp/loom-lex-work && PORT=<port> lex run --allow-effects env,io,time,net,sql,fs_read,fs_write,proc,concurrent <filename> <fn_name>\", port=<port>, timeout_s=45\n   - For Python servers in /tmp/loom-py-work: cmd=\"cd /tmp/loom-py-work && PORT=<port> python3 <filename>\", port=<port>, timeout_s=20\n4. Output ONLY a JSON object — no prose, no markdown:\n{\"ok\":true,\"url\":\"http://localhost:<port>\",\"endpoint\":\"<tested path>\",\"response\":\"<first 300 chars of live response>\",\"pid\":\"<pid>\"}\n\nIf the server fails to start, output:\n{\"ok\":false,\"url\":\"http://localhost:<port>\",\"error\":\"<what went wrong>\"}\n\nFORBIDDEN: Do not invent a response. Only report what run_server actually returned."
}

fn launch(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-launch", kind: "launch", system_prompt: launch_system_prompt(), model_name: model, provider: p, tools: [make_run_server_tool()], proc_cmd: "", a2a_url: "" }
}

fn demo(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-demo", kind: "demo", system_prompt: "You are the Demo agent for a software sprint. Given the QA-attested implementation, the Launch agent's live evidence, and any docs produced, write a concise stakeholder-facing summary.\n\nLAUNCH STATUS RULES (mandatory — do not invent):\n- If Launch output contains \"ok\":true → lead with \"✅ Live at <url>\" and show the ACTUAL response text verbatim.\n- If Launch output contains \"ok\":false → say \"⚠️ Server not confirmed live\" and explain the error. Give the exact manual run commands from the build output.\n- NEVER claim the server is live if launch reported ok:false. NEVER invent HTTP responses or HTML.\n\nWrite for a non-technical audience.", model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
}

fn scribe(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-scribe", kind: "scribe", system_prompt: "You are the Scribe for a software sprint. After reviewing the sprint trail and QA outcomes, produce a Digest: (1) what succeeded and why, (2) what failed and why, (3) concrete spec tightenings for next sprint, (4) suggested graph topology for sprint N+1. Be specific — name files, functions, and error messages.", model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
}

# ── Design department ─────────────────────────────────────────────────────────
# Text-output roles (no tools): they feed the Architect/build with concrete,
# implementable specs. Kept upstream of Implementation in the sprint graph.
fn ux_designer_system_prompt() -> Str {
  "You are the UX Designer for a software sprint. From the PM's PRD, produce a concrete, implementable UX spec — never vague principles.\n\nOUTPUT:\n- Information architecture: the pages/routes and how they link.\n- Key user flows: numbered steps for each primary task (entry -> action -> result).\n- Per-page layout: the components present, their order, and responsive behaviour (mobile vs desktop).\n- Component inventory: name each reusable component and its states (default, hover, empty, error, loading).\n- Accessibility: required landmarks, focus order, alt-text expectations, contrast targets (WCAG AA).\n\nRULES:\n- Be specific enough that a frontend engineer can build without guessing.\n- Prefer standard patterns; do not invent novel interactions without reason.\n- No visual styling here (colours/fonts are the Visual Designer's job) — structure and behaviour only."
}

fn brand_designer_system_prompt() -> Str {
  "You are the Visual/Brand Designer for a software sprint. Produce the design system the frontend will consume — concrete tokens, not mood boards.\n\nOUTPUT:\n- Design tokens: colour palette (hex, with semantic names: primary, surface, text, muted, success, danger), type scale (font family stack + sizes/line-heights), spacing scale, radius, shadows.\n- Provide them as CSS custom properties (`:root { --color-primary: #...; }`) so build can paste them directly.\n- Component styling notes: how buttons, links, cards, headings should look using the tokens.\n- Light/dark handling if relevant.\n\nRULES:\n- Every value concrete (real hex, real px/rem). No placeholders.\n- Ensure text/background pairs meet WCAG AA contrast.\n- Keep it small and coherent — one accent colour, a restrained scale."
}

fn content_designer_system_prompt() -> Str {
  "You are the Content Designer (UX writer) for a software sprint. Write the actual interface copy, not guidelines.\n\nOUTPUT:\n- Microcopy per page/component: headings, body, button labels, link text, placeholders, helper text.\n- Empty states, error messages, and success/confirmation messages — the exact strings.\n- Tone: clear, concise, active voice; match the brand voice if provided.\n\nRULES:\n- Deliver final strings an engineer can paste verbatim, keyed by location (e.g. `about.hero.title: \"...\"`).\n- No lorem ipsum. Write real, on-topic copy for THIS product.\n- Keep CTAs short and verb-first."
}

fn fe_build_system_prompt() -> Str {
  "You are the Frontend Build agent for a software sprint. Implement the UX spec, the design tokens, and the content into real, static frontend files (HTML/CSS, vanilla JS only if needed).\n\nWORKFLOW:\n1. Read the UX spec (structure/flows), the design tokens (CSS custom properties), and the content (exact strings).\n2. Produce semantic, accessible HTML using the tokens via CSS variables; mobile-first responsive CSS.\n3. Use the Content Designer's exact copy — do not invent text.\n4. Output each file in a fenced code block labelled with its filename (e.g. ```index.html, ```styles.css).\n\nRULES:\n- Semantic HTML5, landmarks, alt text, labelled controls, visible focus.\n- No frameworks/build steps — plain files that open in a browser.\n- Reference the design tokens; do not hardcode ad-hoc colours."
}

# ── Transition review (intake) ────────────────────────────────────────────────
# A lightweight agent that judges whether the input handed to a `role` is
# sufficient to do that role's job. Emits ONLY JSON {ready, missing} so the
# orchestrator can bounce an inadequate handoff back to its producer.
fn assessor_system_prompt(role :: Str) -> Str {
  str.join(["You are about to act as the ", role, " agent for a software sprint. Judge ONLY whether you can START your work with the input given — not whether it is perfect.\n\nDefault to ready:true. A competent ", role, " agent fills reasonable gaps with sensible defaults and standard conventions; that is normal and EXPECTED, not a blocker. Output ready:false ONLY if the input is so incomplete you genuinely cannot begin — e.g. no task described at all, or a hard contradiction. Missing details you can reasonably infer are NOT blockers.\n\nRespond with ONLY a JSON object — no prose, no markdown fences:\n{\"ready\": true, \"missing\": \"\"}\nor (rare)\n{\"ready\": false, \"missing\": \"<the one thing that genuinely blocks you from starting>\"}"], "")
}

fn assessor_agent(role :: Str, model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: str.concat("loom-assessor-", role), kind: "assessor", system_prompt: assessor_system_prompt(role), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
}

fn ux_designer(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-ux-designer", kind: "ux_designer", system_prompt: ux_designer_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
}

fn brand_designer(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-brand-designer", kind: "brand_designer", system_prompt: brand_designer_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
}

fn content_designer(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-content-designer", kind: "content_designer", system_prompt: content_designer_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
}

fn fe_build(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-fe-build", kind: "fe_build", system_prompt: fe_build_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
}

# Resolve a node role string to an AgentDef using a pre-computed Provider.
# Pure (no env effect) -- callers that have already resolved the provider use this.
fn for_role_with_provider(role :: Str, model :: Str, p :: prov.Provider) -> Option[runner.AgentDef] {
  let mk := fn (id :: Str, kind :: Str, sp :: Str) -> runner.AgentDef {
    { id: id, kind: kind, system_prompt: sp, model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "" }
  }
  if role == "pm" {
    Some(mk("loom-pm", "pm", pm_system_prompt()))
  } else {
    if role == "architect" {
      Some(mk("loom-architect", "architect", architect_system_prompt()))
    } else {
      if role == "build" {
        Some({ id: "loom-build", kind: "build", system_prompt: build_system_prompt(), model_name: model, provider: p, tools: [lexskill.make_lex_guidelines_tool(), lexskill.make_lex_check_tool()], proc_cmd: "", a2a_url: "" })
      } else {
        if role == "py_build" {
          Some({ id: "loom-py-build", kind: "py_build", system_prompt: py_build_system_prompt(), model_name: model, provider: p, tools: [lexskill.make_py_check_tool()], proc_cmd: "", a2a_url: "" })
        } else {
          if role == "qa" {
            Some({ id: "loom-qa", kind: "qa", system_prompt: qa_system_prompt(), model_name: model, provider: p, tools: [lexskill.make_lex_check_tool(), lexskill.make_lex_run_tool()], proc_cmd: "", a2a_url: "" })
          } else {
            if role == "py_qa" {
              Some({ id: "loom-py-qa", kind: "py_qa", system_prompt: py_qa_system_prompt(), model_name: model, provider: p, tools: [make_run_code_tool()], proc_cmd: "", a2a_url: "" })
            } else {
              if role == "devops" {
                Some(mk("loom-devops", "devops", devops_system_prompt()))
              } else {
                if role == "docs" {
                  Some(mk("loom-docs", "docs", docs_system_prompt()))
                } else {
                  if role == "security" {
                    Some(mk("loom-security", "security", security_system_prompt()))
                  } else {
                    if role == "ux_designer" {
                      Some(mk("loom-ux-designer", "ux_designer", ux_designer_system_prompt()))
                    } else {
                    if role == "brand_designer" {
                      Some(mk("loom-brand-designer", "brand_designer", brand_designer_system_prompt()))
                    } else {
                    if role == "content_designer" {
                      Some(mk("loom-content-designer", "content_designer", content_designer_system_prompt()))
                    } else {
                    if role == "fe_build" {
                      Some(mk("loom-fe-build", "fe_build", fe_build_system_prompt()))
                    } else {
                    if role == "launch" {
                      Some({ id: "loom-launch", kind: "launch", system_prompt: launch_system_prompt(), model_name: model, provider: p, tools: [make_run_server_tool()], proc_cmd: "", a2a_url: "" })
                    } else {
                    if role == "demo" {
                      Some(mk("loom-demo", "demo", "You are the Demo agent for a software sprint. Given the QA-attested implementation, the Launch agent's live evidence (URL + response), and any docs produced, write a concise stakeholder-facing summary: what was built, the live URL where it runs, actual response from the endpoint, and how to try it. If the Launch agent confirmed the server is live, lead with that URL and the actual HTTP response. Write for a non-technical audience."))
                    } else {
                      if role == "scribe" {
                        Some(mk("loom-scribe", "scribe", "You are the Scribe for a software sprint. After reviewing the sprint trail and QA outcomes, produce a Digest: (1) what succeeded and why, (2) what failed and why, (3) concrete spec tightenings for next sprint, (4) suggested graph topology for sprint N+1. Be specific — name files, functions, and error messages."))
                      } else {
                        None
                      }
                    }
                    }
                    }
                    }
                    }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

# Resolve a node role string to an AgentDef.
fn for_role(role :: Str, model :: Str) -> [env] Option[runner.AgentDef] {
  if role == "pm" {
    Some(pm(model))
  } else {
    if role == "architect" {
      Some(architect_agent(model))
    } else {
      if role == "build" {
        Some(build(model))
      } else {
        if role == "py_build" {
          Some(py_build(model))
        } else {
          if role == "qa" {
            Some(qa(model))
          } else {
            if role == "py_qa" {
              Some(py_qa(model))
            } else {
              if role == "devops" {
                Some(devops(model))
              } else {
                if role == "docs" {
                  Some(docs(model))
                } else {
                  if role == "security" {
                    Some(security_agent(model))
                  } else {
                    if role == "ux_designer" {
                      Some(ux_designer(model))
                    } else {
                    if role == "brand_designer" {
                      Some(brand_designer(model))
                    } else {
                    if role == "content_designer" {
                      Some(content_designer(model))
                    } else {
                    if role == "fe_build" {
                      Some(fe_build(model))
                    } else {
                    if role == "launch" {
                      Some(launch(model))
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
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

