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

import "./role_tools" as rt

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
      let script := str.join(["lsof -ti tcp:", port_str, " 2>/dev/null | xargs kill -9 2>/dev/null || true\n", "(command -v fuser >/dev/null && fuser -k ", port_str, "/tcp 2>/dev/null) || true\n", "sleep 1\n", "# Detach server: redirect its stdout/stderr to a logfile so it does not\n", "# hold this script's stdout pipe open (which would block the parent read).\n", "nohup bash -c ", "\"", "{ ", cmd, " ; }", " >'", srv_log, "' 2>&1\" >/dev/null 2>&1 &\n", "PID=$!\n", "echo \"PID:$PID\"\n", "OK=0\n", "for i in $(seq 1 ", int.to_str(timeout_s), "); do\n", "  sleep 1\n", "  RESP=$(curl -s --max-time 2 '", url, "' 2>/dev/null) && [ -n \"$RESP\" ] && { OK=1; break; }\n", "done\n", "if [ \"$OK\" = \"1\" ]; then\n", "  echo \"READY\"\n", "  echo \"RESPONSE:$RESP\"\n", "  exit 0\n", "fi\n", "echo \"TIMEOUT\"\n", "echo \"SERVERLOG:$(tail -5 '", srv_log, "' 2>/dev/null)\"\n", "exit 1"], "")
      match proc.run("bash", ["-c", script]) {
        Err(msg) => Ok(JObj([("ok", JBool(false)), ("error", JStr(str.concat("spawn failed: ", msg))), ("url", JStr(url)), ("response", JStr("")), ("pid", JStr(""))])),
        Ok(r) => {
          let combined := str.concat(r.stdout, r.stderr)
          let ok := str.contains(combined, "READY")
          let pid_part := match list.head(list.tail(str.split(combined, "PID:"))) {
            None => "",
            Some(s) => str.trim(match list.head(str.split(s, "\n")) {
              None => s,
              Some(line) => line,
            }),
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

# `evidence_path` is where every real invocation's outcome is recorded —
# {"ran":true,"passed":true|false} — independent of whatever the agent's
# final text claims. The `spec json-verdict-pass` gate (orchestrator.lex)
# checks this file rather than trusting the agent's self-reported
# "verdict" field, so a verdict that was never actually run (or that
# contradicts what really ran) gets denied instead of silently accepted.
# ── deploy_hetzner tool ────────────────────────────────────────────────────────
# Actually deploys the built project to a real, already-provisioned Hetzner
# server -- never a string check, never a claim the agent invents. Kept
# deliberately simple for v1 (#101): rsync the work dir over, build+run the
# container directly on the box (restart policy so it survives a reboot),
# then curl the real public host:port for /health. No Caddy/TLS/domain yet --
# that's a natural next step once this loop is proven, not a blocker for it.
#
# Reads server details from the environment (never hardcoded, never invented
# by the model):
#   HETZNER_HOST       -- server IP or hostname (required)
#   HETZNER_USER        -- SSH user (default "root")
#   HETZNER_SSH_KEY     -- path to the private key (default ~/.ssh/id_rsa)
#   HETZNER_REMOTE_DIR  -- where the project lands on the server
#                          (default /opt/loom-deploys/<service_name>)
# Server config is read HERE, at tool-construction time -- not inside the
# execute closure, whose effect row is fixed by the Tool record type to
# exactly [net, io, proc] (no [env]). Reading once and closing over the
# values is also more honest: the deploy target can't drift mid-sprint if
# something re-exports the env var between tool calls.
fn make_deploy_hetzner_tool() -> [env] t.Tool {
  let host := match env.get("HETZNER_HOST") {
    Some(v) => v,
    None => "",
  }
  let ssh_user := match env.get("HETZNER_USER") {
    Some(v) => v,
    None => "root",
  }
  let ssh_key := match env.get("HETZNER_SSH_KEY") {
    Some(v) => v,
    None => "~/.ssh/id_rsa",
  }
  let remote_dir_override := match env.get("HETZNER_REMOTE_DIR") {
    Some(v) => v,
    None => "",
  }
  let params := { title: "DeployHetzner", description: "rsync + build + run the project on a real Hetzner server, then health-check it", fields: [s.required_str("work_dir", []), s.required_str("service_name", []), s.required_int("port", []), s.optional(s.required_str("endpoint", [])), s.optional(s.required_int("timeout_s", []))] }
  t.define("deploy_hetzner", "Deploy `work_dir` (an already-built project directory with a Dockerfile) to the Hetzner server named by HETZNER_HOST. Builds and runs the container for real, waits for it to respond, then fetches `endpoint`. Returns {ok, url, response, error}.", params, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let work_dir := match jv.get_field(args, "work_dir") {
      Some(JStr(v)) => v,
      _ => "",
    }
    let service_name := match jv.get_field(args, "service_name") {
      Some(JStr(v)) => v,
      _ => "loom-app",
    }
    let port := match jv.get_field(args, "port") {
      Some(JInt(v)) => v,
      _ => 8080,
    }
    let endpoint := match jv.get_field(args, "endpoint") {
      Some(JStr(v)) => v,
      _ => "/health",
    }
    let timeout_s := match jv.get_field(args, "timeout_s") {
      Some(JInt(v)) => v,
      _ => 30,
    }
    if str.is_empty(work_dir) {
      Ok(JObj([("ok", JBool(false)), ("error", JStr("work_dir is required")), ("url", JStr("")), ("response", JStr(""))]))
    } else {
      if str.is_empty(host) {
        Ok(JObj([("ok", JBool(false)), ("error", JStr("HETZNER_HOST is not set -- a human must provision a server and set this env var first")), ("url", JStr("")), ("response", JStr(""))]))
      } else {
        let remote_dir := if str.is_empty(remote_dir_override) {
          str.join(["/opt/loom-deploys/", service_name], "")
        } else {
          remote_dir_override
        }
        let port_str := int.to_str(port)
        let url := str.join(["http://", host, ":", port_str, endpoint], "")
        let ssh_opts := str.join(["-i ", ssh_key, " -o StrictHostKeyChecking=accept-new"], "")
        let script := str.join(["set -e\n", "ssh ", ssh_opts, " ", ssh_user, "@", host, " 'mkdir -p ", remote_dir, "'\n", "rsync -az --delete -e \"ssh ", ssh_opts, "\" '", work_dir, "/' '", ssh_user, "@", host, ":", remote_dir, "/'\n", "ssh ", ssh_opts, " ", ssh_user, "@", host, " '", "cd ", remote_dir, " && ", "docker build -t ", service_name, " . && ", "docker rm -f ", service_name, " >/dev/null 2>&1 || true; ", "docker run -d --name ", service_name, " --restart unless-stopped -p ", port_str, ":", port_str, " ", service_name, "'\n", "OK=0\n", "for i in $(seq 1 ", int.to_str(timeout_s), "); do\n", "  sleep 1\n", "  RESP=$(curl -s --max-time 2 '", url, "' 2>/dev/null) && [ -n \"$RESP\" ] && { OK=1; break; }\n", "done\n", "if [ \"$OK\" = \"1\" ]; then\n", "  echo \"READY\"\n", "  echo \"RESPONSE:$RESP\"\n", "  exit 0\n", "fi\n", "echo \"TIMEOUT\"\n", "exit 1"], "")
        match proc.run("bash", ["-c", script]) {
          Err(msg) => Ok(JObj([("ok", JBool(false)), ("error", JStr(str.concat("deploy failed to run: ", msg))), ("url", JStr(url)), ("response", JStr(""))])),
          Ok(r) => {
            let combined := str.concat(r.stdout, r.stderr)
            let ok := str.contains(combined, "READY")
            let resp_part := match list.head(list.tail(str.split(combined, "RESPONSE:"))) {
              None => "",
              Some(s) => str.trim(s),
            }
            if ok {
              Ok(JObj([("ok", JBool(true)), ("url", JStr(url)), ("response", JStr(str.slice(resp_part, 0, 500))), ("error", JStr("")), ("service_name", JStr(service_name))]))
            } else {
              Ok(JObj([("ok", JBool(false)), ("url", JStr(url)), ("response", JStr("")), ("error", JStr(str.join(["deploy ran but the server did not respond within ", int.to_str(timeout_s), "s: ", str.slice(combined, 0, 800)], "")))]))
            }
          },
        }
      }
    }
  })
}

# Found live (pdfx company run this session): a real py_build node imported
# `pdfplumber` for several iterations (it passed py_check's compile-only gate
# every time, since py_compile never actually resolves/executes the import),
# then a later run_code call hit a genuine ModuleNotFoundError, and py_build
# silently rewrote around it with a hand-rolled parser -- no error, no note,
# no trace of why anywhere in the artifacts. The sandbox has no pip/install
# step at all (see the Architect's "AVAILABLE PYTHON PACKAGES" list in
# architect_system_prompt), so this failure mode is not a one-off; anything
# not in {stdlib, flask, fastapi, jinja2, markdown, pytest} will always fail
# this way. Give the retry loop a distinct, explicit signal so an agent is
# told to drop the package rather than silently reinventing its own version
# of it.
fn annotate_missing_dependency(combined :: Str) -> Str {
  let hit := if str.contains(combined, "ModuleNotFoundError") {
    true
  } else {
    str.contains(combined, "ImportError")
  }
  if hit {
    str.join(["[MISSING_DEPENDENCY] This sandbox has NO pip/install step -- only stdlib, flask, fastapi, jinja2, markdown, and pytest are ever available. Do not attempt to import any other third-party package (including retrying the same one) or silently swap in an unrelated implementation without saying so; rewrite the failing import out using only the allowed packages, and if the mission text asked for a specific unavailable package, say so plainly in your output.\n\n", combined], "")
  } else {
    combined
  }
}

fn make_run_code_tool(evidence_path :: Str) -> t.Tool {
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
          Err(msg) => {
            let __ev := if str.is_empty(evidence_path) {
              Ok(())
            } else {
              io.write(evidence_path, "{\"ran\":true,\"passed\":false}")
            }
            Ok(JObj([("passed", JStr("false")), ("exit_code", JInt(1)), ("output", JStr(msg))]))
          },
          Ok(r) => {
            let raw := str.concat(r.stdout, r.stderr)
            let passed := str.contains(raw, "##EXIT:0")
            let combined := if passed {
              raw
            } else {
              annotate_missing_dependency(raw)
            }
            let __ev := if str.is_empty(evidence_path) {
              Ok(())
            } else {
              io.write(evidence_path, str.join(["{\"ran\":true,\"passed\":", if passed {
                "true"
              } else {
                "false"
              }, "}"], ""))
            }
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

# Construct a tool from its canonical name. The inverse of `tool.name`; the only
# place a role-policy name (role_tools.tools_for) is bound to its implementation.
# `evidence_path` only matters to `run_code` (see make_run_code_tool); every
# other tool ignores it. `sprint_id` scopes lex_check/lex_run/py_check/
# security_scan's shared work dir (see lex_skill.work_dir) so a build node's
# files can never be clobbered by an unrelated sprint (#156).
fn tool_by_name(name :: Str, evidence_path :: Str, sprint_id :: Str) -> [env] Option[t.Tool] {
  if name == "lex_guidelines" {
    Some(lexskill.make_lex_guidelines_tool())
  } else {
    if name == "lex_check" {
      Some(lexskill.make_lex_check_tool(evidence_path, sprint_id))
    } else {
      if name == "lex_run" {
        Some(lexskill.make_lex_run_tool(evidence_path, sprint_id))
      } else {
        if name == "py_check" {
          Some(lexskill.make_py_check_tool(sprint_id))
        } else {
          if name == "run_code" {
            Some(make_run_code_tool(evidence_path))
          } else {
            if name == "run_server" {
              Some(make_run_server_tool())
            } else {
              if name == "deploy_hetzner" {
                Some(make_deploy_hetzner_tool())
              } else {
                if name == "security_scan" {
                  Some(lexskill.make_security_scan_tool(sprint_id))
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

# An agent's tool set, derived from its role's canonical policy — so the tools a
# node is granted at runtime are exactly the tools the verifier checks against.
# `evidence_path` is forwarded to `run_code` (see make_run_code_tool); pass ""
# for roles/callers that don't need grounded json-verdict evidence. `sprint_id`
# is forwarded to tool_by_name; pass "" for roles/callers that never touch the
# shared work dir.
fn tools_of_role(role :: Str, evidence_path :: Str, sprint_id :: Str) -> [env] List[t.Tool] {
  list.fold(rt.tools_for(role), [], fn (acc :: List[t.Tool], name :: Str) -> [env] List[t.Tool] {
    match tool_by_name(name, evidence_path, sprint_id) {
      Some(tool) => list.concat(acc, [tool]),
      None => acc,
    }
  })
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
  { id: "loom-architect", kind: "architect", system_prompt: "You are a software design architect. Given a project request, produce a concise technical design specification in plain prose: describe the components, key functions or classes, their interfaces, and expected behaviour. Do not output JSON or sprint graphs. Write 2-4 paragraphs maximum.", model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

fn architect_with_context(model :: Str, specs_context :: Str, sprint_id :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-architect", kind: "architect", system_prompt: str.concat("You are the Architect for a software sprint. Given a project request, output ONLY a JSON sprint graph -- no prose, no markdown fences. Each node needs an id, a role, and a gate. Each edge needs from, to, and a handoff. Shape: {\"id\":\"...\",\"phase\":\"Design\",\"nodes\":[{\"id\":\"...\",\"role\":\"...\",\"gate\":\"...\"}],\"edges\":[{\"from\":\"...\",\"to\":\"...\",\"handoff\":\"schema {}\"}]}", specs_context), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

# Select the most relevant lex_guidelines topic(s) for a task request.
# This is embedded in the node spec so Build knows which topic to call first.
# Matches on keywords in the request text — multiple topics separated by commas.
fn lex_topic_for_request(request :: Str) -> Str {
  let low := str.to_lower(request)
  let has_http := str.contains(low, "rest") or str.contains(low, "api") or str.contains(low, "server") or str.contains(low, "endpoint") or str.contains(low, "route") or str.contains(low, "http")
  let has_mcp := str.contains(low, "mcp") or str.contains(low, "a2a") or str.contains(low, "agent2agent") or str.contains(low, "tool server") or str.contains(low, "skill")
  let has_sql := str.contains(low, "sql") or str.contains(low, "database") or str.contains(low, "sqlite") or str.contains(low, "persist") or str.contains(low, "store") or str.contains(low, "trail")
  let has_agent := str.contains(low, "agent") or str.contains(low, "llm") or str.contains(low, "dispatch") or str.contains(low, "orchestrat")
  let has_stream := str.contains(low, "stream") or str.contains(low, "sse") or str.contains(low, "chunk")
  let n := if has_http {
    1
  } else {
    0
  } + if has_mcp {
    1
  } else {
    0
  } + if has_sql {
    1
  } else {
    0
  } + if has_agent {
    1
  } else {
    0
  } + if has_stream {
    1
  } else {
    0
  }
  if n >= 3 {
    "all"
  } else {
    if has_mcp {
      if has_sql {
        "mcp"
      } else {
        "mcp"
      }
    } else {
      if has_http {
        if has_stream {
          "streaming"
        } else {
          if has_sql {
            "sql"
          } else {
            "http"
          }
        }
      } else {
        if has_agent {
          "agent"
        } else {
          if has_sql {
            "sql"
          } else {
            if has_stream {
              "streaming"
            } else {
              "core"
            }
          }
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
  let lex_hint := str.join(["\n\nLEX CONTEXT HINT: This sprint targets the Lex language. When specifying Build nodes, ", "include in the gate field: 'call lex_guidelines(topic=", topic, ") before writing any code'. ", "Lex is NOT in the model's training data. The Build agent has lex_guidelines and lex_check tools. ", "The QA agent has lex_check and lex_run tools."], "")
  let system_prompt := str.join(["You are the Architect for a Lex language software sprint. ", "Given a project request, output ONLY a JSON sprint graph — no prose, no markdown fences. ", "Each node needs an id, a role ('build', 'qa', 'demo', 'scribe'), and a gate. ", "Each edge needs from, to, and a handoff describing what artifact passes. ", "Shape: {\"id\":\"...\",\"phase\":\"Design\",\"nodes\":[{\"id\":\"...\",\"role\":\"...\",\"gate\":\"...\"}],", "\"edges\":[{\"from\":\"...\",\"to\":\"...\",\"handoff\":\"...\"}]}", lex_hint], "")
  { id: "loom-architect-lex", kind: "architect", system_prompt: system_prompt, model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

# ── System prompt helpers ─────────────────────────────────────────────────────
fn pm_system_prompt() -> Str {
  "You are the Product Manager for a software sprint. Your job is to turn a raw request into a structured PRD that the Architect can design from.\n\nOUTPUT FORMAT — plain text with these sections (no JSON, no markdown fences):\n\n## Goal\nOne sentence: what the product does and who it is for.\n\n## User Stories\n- As a [user], I want [action] so that [outcome].\n(3-6 stories maximum)\n\n## Acceptance Criteria\nNumbered list of concrete, testable conditions. Be specific: file names, HTTP status codes, output format.\n\n## Out of Scope\nExplicit list of what this sprint does NOT include.\n\n## Tech Notes\nAny constraints: language preference (Python / Lex / both), deployment target, dependencies to avoid.\n\nKeep it tight. The Architect reads this — not a human executive."
}

fn architect_system_prompt() -> Str {
  str.join(["You are the Architect for a software sprint. You read the PM's PRD and output ONLY a JSON sprint graph — no prose, no markdown fences.\n\n", "GRAPH SHAPE:\n", "{\"id\":\"<sprint-id>\",\"phase\":\"Design\",\"nodes\":[{\"id\":\"...\",\"role\":\"...\",\"gate\":\"...\"}],\"edges\":[{\"from\":\"...\",\"to\":\"...\",\"handoff\":\"...\"}]}\n\n", "AVAILABLE ROLES:\n", "  pm          — Product Manager: raw request → PRD\n", "  architect   — you; PRD → sprint graph\n", "  ux_designer      — UX spec: IA, user flows, component inventory, a11y (no styling)\n", "  brand_designer   — Visual design system: CSS custom-property tokens (colour/type/spacing)\n", "  content_designer — UX writing: exact interface copy, keyed by location\n", "  build       — Lex implementation (has lex_guidelines + lex_check tools)\n", "  py_build    — Python implementation (writes Python files, runs via bash)\n", "  fe_build    — Frontend: HTML/CSS/JS (reads UX spec + design tokens + content)\n", "  devops      — Dockerfile, docker-compose, CI config\n", "  deploy      — Actually deploys to the real, already-provisioned Hetzner server (deploy_hetzner tool), returns live JSON {ok,url,response}. Only add when the mission asks to ship/run the product for real users, not for a local demo only.\n", "  qa          — Lex QA: lex_check + lex_run, emits JSON verdict\n", "  py_qa       — Python QA: runs code + assertions, emits JSON verdict\n", "  security    — OWASP review, blocks demo on critical findings\n", "  docs        — README, API reference, usage examples\n", "  launch      — Actually starts the built server, curls an endpoint, returns live JSON {ok,url,response}\n", "  demo        — Stakeholder summary (non-technical), leads with Launch's live URL if available\n", "  brand_strategist — Positioning statement, core message, voice/tone (words, not visuals)\n", "  copywriter       — Landing page copy, one ad variant, one outreach email\n", "  content_creator  — Launch blog post, a short tutorial, a case-study outline (never fabricated)\n", "  seo_specialist   — Keyword list, meta title/description, heading structure, internal links\n", "  finance          — Pricing tiers, unit economics sketch, budget status (grounded — flags assumptions vs real numbers)\n", "  legal            — Draft ToS/Privacy Policy/license header, ALWAYS marked as a human-review-required draft\n", "  monetization_handoff — Human-facing checklist for creating a real Gumroad/Stripe product; NEVER autonomous, gate MUST be 'human <oracle>'\n", "  scribe      — Digest: lessons learned + tightened specs for sprint N+1\n\n", "AVAILABLE LEX PACKAGES (for build nodes):\n", "  std.net      — HTTP server (net.serve / net.serve_fn), HTTP client (net.get/post)\n", "  std.sql      — SQLite queries (sql.open, sql.exec, sql.query)\n", "  std.io       — file read/write, stdin/stdout\n", "  std.str      — string operations\n", "  std.list     — list operations (map, filter, fold)\n", "  std.json     — JSON parse/stringify\n", "  std.proc     — spawn subprocesses\n", "  std.crypto   — Ed25519, HMAC, SHA-256, base64url\n", "  lex-agent    — A2A protocol server (cap.inbound, srv.make_agent_def, card.make)\n", "  lex-llm      — LLM agent loop (ag.run_loop, providers.*)\n", "  lex-mcp      — MCP server: stdio (mcp.server.run), HTTP (http.run_http), dual (compose.serve_both)\n", "  lex-mcp-client — connect to MCP servers, adapt tools for lex-llm agents\n", "  lex-spec     — capability preconditions, spec gating, SMT export\n", "  lex-trail    — append-only audit log (trail_log.open, trail_log.append)\n", "  lex-guard    — budget tokens + spending guardrails\n", "  lex-x402     — x402 micropayments (client.pay to spend, server.gate to CHARGE for a priced endpoint — use for a metered/paid API, the stack path `lex-x402-api` pre-wires this as ./payments.lex)\n", "  lex-jose     — JWT/JWS/JWK (jwt.encode, jwt.decode, jws.sign_compact)\n", "  lex-agent-llm — bridge: LLM loop → A2A skill (bridge.skill_of_loop)\n\n", "AVAILABLE PYTHON PACKAGES (for py_build nodes):\n", "  stdlib only  — http.server, argparse, json, sqlite3, pathlib, subprocess\n", "  flask        — lightweight HTTP server (use for REST APIs)\n", "  fastapi      — async REST API with auto docs (use for larger APIs)\n", "  jinja2       — HTML templating\n", "  markdown     — markdown → HTML conversion\n", "  pytest       — test runner\n\n", "GATE EXPRESSIONS:\n", "  spec non-empty          — output must not be empty\n", "  spec compiles           — GROUNDED: every source file the node produced must actually compile\n", "                            (py_compile / lex check). ONLY valid for build and py_build nodes —\n", "                            they are the only roles with a tool (lex_check/py_check) that persists\n", "                            files anywhere a compiler can see them. NEVER use it for fe_build,\n", "                            devops, ux_designer, or any other role — their output is prose/code in\n", "                            the final answer only, nothing is written to disk, so the gate can\n", "                            NEVER pass and the node will exhaust every retry for no reason.\n", "  spec json-verdict-pass  — output must be JSON {\"verdict\":\"PASS\",...} (ALWAYS for qa/py_qa nodes)\n", "  spec len-gt 200         — output longer than 200 chars (weak; prefer 'spec compiles' for code)\n", "  spec len-gt 50          — output longer than 50 chars (weak; a presence check, NOT quality)\n", "  spec json               — output must be valid JSON (use for expand nodes; NOT for launch/deploy)\n", "  spec json-ok-true       — output must be JSON with an \"ok\" field equal to true (ALWAYS for launch AND deploy nodes — 'spec json' alone accepts a well-formed {\"ok\":false,\"error\":\"...\"} just as happily as a real success)\n", "  spec judge \"<criteria>\" — an LLM evaluator grades the output against YOUR criteria and\n", "                            returns PASS/FAIL. Autonomous (no human). Use for SUBJECTIVE\n", "                            deliverables with no compile/test check — marketing copy, design\n", "                            specs, legal/ToS prose, brand voice, docs quality. Write concrete,\n", "                            checkable criteria, e.g.:\n", "                            spec judge \"names the product, states 2+ concrete benefits, has one clear CTA, <120 words, no placeholder text\"\n", "  spec sh \"<command>\"     — GROUNDED tool gate: runs <command> against the files the node produced;\n", "                            passes iff it exits 0. The general grounding primitive for technical\n", "                            domains — wrap any real verifier:\n", "                              devops:    spec sh \"docker build -t app .\"\n", "                              security:  spec sh \"semgrep --error --quiet .\"  /  spec sh \"gitleaks detect --no-git\"\n", "                              ml:        spec sh \"python eval.py --min-f1 0.85\"\n", "                              analytics: spec sh \"dbt test\"\n", "                            Use it (not 'spec judge', not 'human') whenever a tool can decide.\n", "  human <oracle>          — routes to a PERSON to attest (e.g. human legal-counsel). Last resort.\n\n", "ATTESTATION LADDER — pick the STRONGEST gate each node can support; MINIMIZE human gates:\n", "  1. GROUNDED (best): spec compiles / spec json-verdict-pass / spec json-ok-true — a real tool decides; cannot be faked.\n", "  2. LLM-JUDGE:        spec judge \"<criteria>\" — for subjective work; an evaluator decides, no human.\n", "  3. HUMAN (rare):     human <oracle> — only for high-stakes sign-off a model must not self-certify.\n", "  Prefer spec judge over spec len-gt for any prose where QUALITY matters; prefer it over human wherever a model can judge.\n\n", "STANDARD GRAPH PATTERN:\n", "  HTTP server task (local demo only):  build → qa → launch → demo → scribe\n", "  HTTP server task (real deploy):      build → qa → devops → deploy → launch → demo → scribe\n", "  Library/CLI task:  build → qa → demo → scribe  (NO launch or deploy node)\n", "  The launch node runs AFTER qa passes (or after deploy, if present). Gate: 'spec json-ok-true'. It starts the server (locally, or reads the deploy node's live URL if deploy ran) and returns {ok,url,response}.\n", "  The deploy node (if present) runs AFTER devops, BEFORE launch. Gate: 'spec json-ok-true'. It actually deploys to the real Hetzner server and returns {ok,url,response} — ONLY add it when the mission is about shipping the product for real users, not a local proof-of-concept.\n", "  demo reads launch (and deploy, if present) output and leads with the REAL live URL when one exists.\n", "  CRITICAL: Only add a launch node if the task explicitly produces a running HTTP server. Only add a deploy node if the mission explicitly asks to ship/run it for real users.\n", "  Pure libraries, CLI tools, data modules, and scripts do NOT need a launch or deploy node.\n\n", "DUAL LAUNCH PATTERN (when building in BOTH Lex AND Python):\n", "  build → qa → launch-lex (PORT=8080)  ↘\n", "                                          demo → scribe\n", "  py_build → py_qa → launch-py (PORT=8081) ↗\n\n", "  - launch-lex gate: 'spec json-ok-true — Lex server on PORT=8080'\n", "  - launch-py gate: 'spec json-ok-true — Python server on PORT=8081'\n", "  - build/qa nodes: Lex uses env PORT (default 8080); py_build/py_qa: Python uses os.environ PORT (default 8081)\n", "  - demo compares both live responses side by side\n\n", "DISTRIBUTION PHASE (optional — only when the task explicitly asks for launch/marketing material, not on every sprint):\n", "  demo → brand_strategist → copywriter → content_creator → seo_specialist → scribe\n\n", "  - Runs AFTER demo, BEFORE scribe — these roles read the demo summary (what got built) plus each other's output in sequence.\n", "  - Every distribution node's gate is 'spec judge \"<concrete, checkable criteria>\"' — there is no compiler for positioning copy, so an LLM judge is the strongest available gate (never 'spec len-gt', never 'spec json').\n", "  - Only add this phase when the request is actually about shipping/marketing a product to real users — do NOT add it to every internal tool or library sprint.\n\n", "BUSINESS-OPS NODES (finance / legal — optional, tech-agnostic, add independently of the distribution phase):\n", "  - finance: add when the task involves pricing a product or the mission mentions monetization/budget. Gate: 'spec judge \"labels every non-tracked-spend figure as ASSUMPTION, no invented competitor/market data, states a concrete price\"'.\n", "  - legal: add when the task involves a product that will accept real users/data. Gate: 'spec judge \"every document begins with the DRAFT/human-review disclaimer verbatim, describes only data collection the actual implementation performs\"'.\n", "  - Both are independent of each other and of the distribution phase — a CLI tool might need legal (a license header) but not finance; a paid API needs both.\n\n", "MONETIZATION HANDOFF (add ONLY when the mission explicitly asks to sell/charge for the product, and finance has already produced real pricing):\n", "  - Add monetization_handoff as the LAST node before scribe, downstream of finance (and copywriter if present).\n", "  - Its gate MUST be 'human <oracle>' (e.g. 'human founder') — NEVER 'spec judge', NEVER 'spec compiles', NEVER any autonomous gate. This is the one node in the whole graph a model must never self-certify: it hands off to a real person to actually create the Gumroad/Stripe product, and the sprint must not claim monetization is \"shipped\" until that person attests.\n", "  - Do not add this node speculatively — only when the mission is genuinely about a paid product, not an internal tool or a free CLI.\n\n", "EXPAND NODES (node-as-loom):\n", "  A node may carry an 'expand' field — a sub-task description that the orchestrator runs as a full child sprint.\n", "  Use expand ONLY when a sub-task is large enough to need its own PM → build → QA → demo pipeline.\n", "  An expand node replaces the LLM agent call with a recursive sprint. If the child sprint passes, the node is accepted.\n", "  Expand node JSON shape: {\"id\":\"...\",\"role\":\"build\",\"gate\":\"spec json\",\"expand\":\"<sub-task description>\"}\n", "  Rules for expand nodes:\n", "  - gate MUST be 'spec json' or 'spec non-empty' (never 'spec len-gt' — too weak for a full sprint result)\n", "  - max expand depth is 3 — do not nest expand nodes inside expand nodes unless the task demands it\n", "  - Only use expand when the sub-task is independently deliverable and testable\n\n", "BUILD TASK SIZE (found live, real evidence): a single build/py_build node asked to do too much at once (e.g. add a new route AND wire a payment gate AND integrate a subprocess call, all in one prompt) reliably returns EMPTY output -- not a compile error, nothing at all -- across repeated real attempts, even though the SAME model handles one piece at a time reliably. If a build/py_build task combines more than about two substantial pieces of new work, split it: either into SEQUENTIAL build nodes in this same graph (build-1 → qa-1 → build-2 → qa-2 → ...), each adding ONE piece on top of the last accepted one, or into an expand node if the sub-task is independently deliverable. Do not ask one build node to do everything the mission needs in a single shot just because the goal text lists several requirements together.\n\n", "DYNAMIC EXTENSION (after Implementation):\n", "  You may be asked to EXTEND a graph after seeing the implemented artifact. If the work fully satisfies the request, return the graph UNCHANGED.\n", "  Only if a genuine sub-task was surfaced by the work, return the FULL graph: every existing node (same ids) PLUS new gated nodes and their edges.\n", "  The extended graph is re-checked against ALL rules before running — same gate/role/DAG constraints apply. Keep the total node count small.\n\n", "RULES:\n", "  - Every node must have a gate.\n", "  - 'spec compiles' is ONLY valid on build/py_build nodes. Every other role (ux_designer,\n", "    brand_designer, content_designer, fe_build, devops, docs, security, finance, legal, ...)\n", "    writes prose/code into its final answer only — never to a compilable location — so this\n", "    gate can never pass for them. Use 'spec judge \"...\"' for their quality gate instead.\n", "  - No cycles. All qa/py_qa nodes must use 'spec json-verdict-pass'. All launch and deploy nodes use 'spec json-ok-true'.\n", "  - demo writes PROSE, not JSON. demo gate MUST be 'spec len-gt 50' — NEVER 'spec json' (demo is not machine output).\n", "  - pm/docs/scribe write prose: 'spec len-gt 50'/'spec non-empty' for mere presence, or 'spec judge \"...\"' when quality matters. Never 'spec json' for prose.\n", "  - launch is ONLY for HTTP server tasks. Do NOT add a launch node for libraries, CLI tools, or data modules.\n", "  - deploy is ONLY for HTTP server tasks the mission explicitly wants shipped to real users — never add it for a local-only demo or a library/CLI task.\n", "  - deploy (if present) runs after devops, before launch. launch runs after deploy if present, else after qa, before demo. It gives demo the live URL.\n", "  - demo must have launch (or at least qa) as an ancestor.\n", "  - devops and docs run after QA, before or parallel to demo. deploy runs after devops.\n", "  - Distribution nodes (brand_strategist/copywriter/content_creator/seo_specialist) run after demo, before scribe, each gated 'spec judge \"...\"'.\n", "  - finance/legal nodes (if used) also run after demo, before scribe, each gated 'spec judge \"...\"' — never 'human' directly (the model drafts; a human reviews the OUTPUT later, outside this sprint).\n", "  - monetization_handoff (if used) is the ONE exception to 'minimize human gates' — its gate MUST be 'human <oracle>', never 'spec judge', since it hands off a real-world action (creating a paid product) no model may self-certify.\n", "  - scribe is always last."], "")
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

# Deployment targets: loom has no automated cloud-push (#92/#93 gap, still
# unclosed) -- a human runs ONE command from this output to actually put the
# service on the internet. Google Cloud Run (serverless, pay-per-request,
# near-zero idle cost -- fits a cheap x402-metered API) and Hetzner
# (persistent VPS, fixed monthly cost, full control) are the two real,
# concrete options; producing config for both means whichever a human
# picks, the deploy step is copy-paste, not a from-scratch decision.
fn devops_system_prompt() -> Str {
  "You are the DevOps agent for a software sprint. Given the implementation artifacts, produce deployment configuration for TWO deployment targets — loom does not push to the cloud itself, so a human deploys manually from exactly this output; give them a real copy-pasteable path for either choice.\n\nOUTPUT (all sections required, in this order):\n\n## Dockerfile\nMulti-stage where possible; non-root user; minimal pinned base image (e.g. python:3.12-slim, never python:latest); EXPOSE the correct port from the implementation; HEALTHCHECK if the service has a /health endpoint.\n\n## .env.example\nEvery required env var with a description, no real secrets.\n\n## Deploy to Google Cloud Run\nServerless, scales to zero, pay-per-request — the cheaper default for a low-traffic metered API.\n- The exact `gcloud run deploy` command: service name, `--source .` or `--image`, `--region`, `--port` matching the Dockerfile's EXPOSE, `--allow-unauthenticated` (or note why not), and `--set-env-vars`/`--set-secrets` referencing the .env.example vars (secrets via Secret Manager, e.g. `--set-secrets=API_KEY=api-key:latest`, never inlined).\n- One sentence on cost shape: free tier covers low request volume; billed per request beyond it.\n\n## Deploy to Hetzner\nPersistent small VPS (e.g. CX22) — fixed monthly cost, full control, no cold starts.\n- `docker-compose.yml`: the service, restart policy `unless-stopped`, ports, env file reference.\n- `Caddyfile`: reverse proxy from the public domain to the container port, with automatic HTTPS (Caddy handles Let's Encrypt itself — do not hand-roll certbot).\n- The exact deploy commands: `rsync`/`scp` the project to the server, then `docker compose up -d`.\n\n## Makefile\ntargets: build, run, test, clean.\n\n## README section: ## Running with Docker\nLocal `docker build` + `docker run` for development, separate from the two deploy sections above.\n\nRULES:\n- Never hardcode secrets in either deploy path — env vars locally, Secret Manager on Cloud Run, an untracked .env file on Hetzner.\n- Both deploy sections must be immediately runnable by a human copy-pasting the commands — no placeholders like <your-project-id> without saying explicitly what to replace it with and where to find it."
}

fn docs_system_prompt() -> Str {
  "You are the Technical Writer for a software sprint. Given the QA-attested implementation and demo summary, produce developer documentation.\n\nOUTPUT:\n## README.md sections to write:\n- **Overview** — what it does, who it is for (2-3 sentences)\n- **Quick Start** — minimal steps to run it (numbered list)\n- **API Reference** — every endpoint or public function: signature, params, return, example\n- **Configuration** — env vars, config files, defaults\n- **Development** — how to run tests, lint, contribute\n\nRULES:\n- Write for a developer who has never seen this project.\n- All code examples must be copy-pasteable and correct.\n- Use the actual file names, function names, and port numbers from the implementation — never invent them."
}

fn security_system_prompt() -> Str {
  "You are the Security Reviewer for a software sprint. Review the implementation for vulnerabilities before it ships.\n\nWORKFLOW (mandatory):\n1. ALWAYS call security_scan FIRST, before writing anything. It greps the actual build files for known-dangerous patterns (hardcoded secrets, shell/eval injection, string-built SQL, debug-mode-on) and returns real findings — a GROUNDED check, not your own read of the code.\n2. Treat every security_scan finding as REAL — you must not omit it, downgrade its severity, or report PASS if any critical/high finding was returned. You MAY add additional findings security_scan cannot detect (see CHECKLIST below), but never invent a finding that contradicts what security_scan reported, and never claim it found nothing if it returned findings.\n3. Also manually check what a grep-based scan cannot catch:\n   - Auth — missing authentication, insecure token handling\n   - Input validation — unvalidated user input reaching queries/file paths/shell commands beyond the patterns already caught\n   - Dependency risks — known-vulnerable packages\n   - Data exposure — sensitive data in logs, error messages, or responses\n   - CORS / headers — missing security headers for HTTP services\n\nOUTPUT — JSON only, no prose:\n{\"verdict\":\"PASS\"|\"FAIL\"|\"WARN\",\"findings\":[{\"severity\":\"critical\"|\"high\"|\"medium\"|\"low\",\"location\":\"file:line\",\"description\":\"...\",\"recommendation\":\"...\"}]}\n\nVerdict PASS = no findings or low-only. WARN = medium findings only. FAIL = any high or critical finding — from security_scan or your own review (blocks demo)."
}

fn build_system_prompt() -> Str {
  "You are the Build agent for a Lex language sprint. Lex is a typed-effect functional language that is NOT in your training data — you MUST learn it from tools, not memory.\n\nWORKFLOW (mandatory — do not skip):\n1. Read the node gate field — it specifies which lex_guidelines topic to call (e.g. topic='http', topic='mcp'). Call lex_guidelines with that topic FIRST. If no topic is specified, call with topic='core'.\n2. Implement the Architect's design as Lex modules. Follow the patterns in the guidelines exactly.\n3. After writing EACH file, call lex_check (filename + code). Read the JSON errors and repair the code until ok='true'.\n4. Finish only when every file passes lex_check.\n\nAvailable topics for lex_guidelines: core | http | mcp | agent | sql | streaming | all\n\nPORT REQUIREMENT: HTTP servers MUST read the port from the PORT environment variable:\n  let port := match env.get(\"PORT\") { Some(p) => match str.to_int(p) { Some(n) => n, None => 8080 }, None => 8080 }\n  net.serve(port, \"handle\")\nNever hardcode 8080 — always use this env pattern.\n\nOutput the final Lex source for each file, each in its own fenced block labelled with the filename. Never claim code compiles unless lex_check confirmed ok='true'."
}

fn pm(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-pm", kind: "pm", system_prompt: pm_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

fn architect_agent(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-architect", kind: "architect", system_prompt: architect_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

# ── LLM-as-judge evaluator (the `spec judge "<criteria>"` gate) ────────────────
# A strict, impartial evaluator for subjective artifacts that have no executable
# oracle (copy, design specs, legal prose). Verdict is autonomous PASS/FAIL — no
# human in the loop — so it is the tier loom uses BEFORE escalating to a human
# `human <oracle>` gate. The criteria come from the gate string.
fn judge_system_prompt(criteria :: Str) -> Str {
  str.join(["You are a STRICT, impartial evaluator (LLM-as-judge). You receive an ARTIFACT produced by another agent and explicit CRITERIA it must satisfy.\n\n", "CRITERIA:\n", criteria, "\n\nRULES:\n", "- Judge ONLY against the criteria above — not your own taste.\n", "- Be demanding: if ANY criterion is unmet, ambiguous, or only partially satisfied, the verdict is FAIL.\n", "- Do not be charitable; do not credit merit the artifact does not actually contain.\n\n", "Output ONLY a JSON object — no prose, no markdown fences:\n", "{\"verdict\":\"PASS\",\"reason\":\"<which criteria are satisfied>\"}\n", "or\n", "{\"verdict\":\"FAIL\",\"reason\":\"<which criteria are unmet, and the specific fix>\"}\n\n", "The reason MUST be specific and actionable so the producing agent can repair the artifact."], "")
}

fn judge_agent(model :: Str, criteria :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-judge", kind: "judge", system_prompt: judge_system_prompt(criteria), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

# Strategist — the agent-first "board" (company C8, #62). Between iterations it
# reviews the mission, the current goal, and the last iteration's grounded result
# (verifier verdict + digest summary), then steers: keep going, revise the goal
# (a pivot), or stop (mission achieved or a dead end). Every decision is trail-
# recorded, so the company's direction changes are auditable, not silent.
fn strategist_agent(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-strategist", kind: "strategist", system_prompt: strategist_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

fn strategist_system_prompt() -> Str {
  str.join(["You are the STRATEGIST for an autonomous software company that pursues a persistent MISSION by running a series of build sprints (iterations). After each iteration you decide the company's next move.\n\n", "You receive:\n", "- MISSION: the enduring goal that does not change.\n", "- SHIPPED SO FAR: every feature the company has ALREADY successfully built, oldest first.\n", "- BOARD NOTES: advisory guidance from a human board member.\n", "- OPERATE SIGNALS: real observations from OUTSIDE the build sandbox — this is the ONLY signal in your context that isn't produced by the same build/QA/digest loop judging its own work. Includes a liveness check (is a launched/deployed server actually still responding), a scan of the last 5 minutes of the live container's own logs for errors/exceptions/tracebacks (a service can be technically 'up' while its logs show it's throwing errors on every request, which liveness alone would miss), any open incidents the operate controller has recorded, and CONTROLLER METRICS — a summarised rollup, never raw incident text: open incident count, incidents resolved vs. escalated, the verified-action hit rate and its trend, average evidence cost per closed incident, and company spend so far.\n", "- PRODUCT SIGNALS: free text the product reports ABOUT ITSELF, from its own /loom/usage endpoint — real usage counts, notable trends, whatever ITS domain considers meaningful (a feedback tool reports feedback volume/sentiment; a different product reports something else entirely). This is the ONLY signal that reflects what the product is actually being used for, not merely whether it's running. It is self-reported by the product's own code, not independently verified — weigh it as informative context alongside OPERATE SIGNALS and LAST RESULT, not as verified fact.\n", "- LEX BUILD STATUS: ground truth (from the actual sprint graphs run, not a self-report) on whether the MOST RECENT iteration's graph accepted a Lex ('build' role) node — NOT lifetime history. If MISSION describes a Lex server, an x402/payment gate, or any other Lex-side integration point: (a) if this says no Lex build node has EVER shipped, that integration is unbuilt regardless of Python-side progress — 'revise' or 'add' a goal that actually builds/wires the Lex side; (b) if this says the MOST RECENT iteration dropped Lex even though one shipped earlier, that is a REGRESSION, not progress — do not describe the mission as satisfied by whatever the last iteration built (e.g. do not call a plain Python/Flask server \"the Lex server\" just because the goal text said 'Lex') — 'revise' to bring the current direction back to actually using Lex.\n", "- CURRENT GOAL: what the last iteration actually attempted.\n", "- LAST RESULT: the four-layer verifier verdict (passed/failed) and the digest summary of what was built and learned.\n\n", "Decide ONE of:\n", "- \"continue\": the current goal is right and not yet met — run it again to improve.\n", "- \"revise\": the CURRENT goal should change now — a pivot, a narrower scope. Provide the new goal; it replaces the current one immediately.\n", "- \"add\": the current goal is fine as-is, but you see a DIFFERENT feature the mission needs later. Provide that feature as a goal — it is QUEUED to a backlog and worked on only once the current goal is later stopped, without interrupting what's in progress now.\n", "- \"stop\": the current goal is fully achieved. If a feature is queued in the backlog, the company automatically moves on to it next; if the backlog is empty, the company halts (the mission itself is complete or a dead end has been reached). Explain which.\n\n", "RULES:\n", "- Ground your decision in the LAST RESULT, not optimism. A failed verdict is evidence the goal is too big or mis-specified — prefer revise (narrower) over continue.\n", "- A QA-passed feature that OPERATE SIGNALS show is actually down/broken in the real world — including a production error-log scan showing real exceptions, even if the liveness check itself is still 'up' — is EVIDENCE AGAINST treating it as shipped, regardless of what the last QA verdict said. QA proves the code works in a sandbox, not that it's still working now. Prefer \"revise\" (fix what's actually broken — name the specific error from the log scan in the new goal) over moving on to new work when this happens.\n", "- Sustained incident/cost load on a shipped feature — an escalated-incident count that keeps growing, a declining verified-action hit rate, or evidence cost climbing without incidents actually closing — is EVIDENCE AGAINST 'continue' on that feature, independent of the last QA verdict; QA proves the code once, the controller metrics show whether it keeps working in production. Prefer 'revise' to address the specific pattern the metrics show.\n", "- If PRODUCT SIGNALS shows real usage suggesting a specific gap or opportunity (e.g. actual feedback naming a problem, or a domain metric trending the wrong way), prefer a 'revise' or 'add' goal that responds to it over inventing a feature from the mission text alone — the mission describes the destination, PRODUCT SIGNALS describes where users actually are today. If it still reads \"no usage data yet\" or is unreachable, that's not evidence of anything — decide on the other signals as usual.\n", "- NEVER revise/add a goal that duplicates or substantially overlaps something already in SHIPPED SO FAR — check that list first. If everything you can think of is already shipped, prefer \"stop\" over inventing a repeat.\n", "- A revise/add goal MUST be a concrete, buildable request in one or two sentences, advancing the MISSION, and must be a genuinely NEW capability not already shipped.\n", "- Use \"add\" to grow the feature set over time (e.g. after a core function seals, add the next related capability) rather than only ever revising the one thing in front of you.\n", "- Only \"stop\" when the CURRENT goal's evidence genuinely supports it — stopping is not risky if a backlog item is queued, since the company just moves on.\n", "- \"add\" deliberately leaves the CURRENT goal running one more iteration (it does not interrupt in-progress work) — so if the CURRENT goal is actually FULLY, ROBUSTLY done (not just \"good enough for now\"), prefer \"stop\" over \"add\" even when you also see a future feature worth queuing: queue it with \"add\" only once, on THIS decision, if the current goal genuinely still benefits from another iteration; otherwise choose \"stop\" directly so the company advances immediately instead of needlessly re-verifying an already-complete goal.\n\n", "Output ONLY a JSON object — no prose, no markdown fences:\n", "{\"decision\":\"continue|revise|add|stop\",\"goal\":\"<new/queued goal, required iff revise or add, else empty>\",\"reason\":\"<one sentence grounded in the result>\"}"], "")
}

fn build(model :: Str, sprint_id :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-build", kind: "build", system_prompt: build_system_prompt(), model_name: model, provider: p, tools: tools_of_role("build", "", sprint_id), proc_cmd: "", a2a_url: "", sprint_id: sprint_id }
}

fn py_build(model :: Str, sprint_id :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-py-build", kind: "py_build", system_prompt: py_build_system_prompt(), model_name: model, provider: p, tools: tools_of_role("py_build", "", sprint_id), proc_cmd: "", a2a_url: "", sprint_id: sprint_id }
}

# evidence_path grounds `spec json-verdict-pass` for this role the same way
# py_qa's does (#110) -- found live: this used to hardcode "" here, silently
# defeating the lex_check/lex_run evidence fix even after it was wired
# through tool_by_name, because THIS constructor never passed the real path.
fn qa(model :: Str, evidence_path :: Str, sprint_id :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-qa", kind: "qa", system_prompt: qa_system_prompt(), model_name: model, provider: p, tools: tools_of_role("qa", evidence_path, sprint_id), proc_cmd: "", a2a_url: "", sprint_id: sprint_id }
}

# `evidence_path` grounds `spec json-verdict-pass` (see make_run_code_tool) —
# the caller derives it per sprint+node (runner.qa_evidence_path) so a
# verdict can be checked against real run_code evidence instead of trusted
# blind.
fn py_qa(model :: Str, evidence_path :: Str, sprint_id :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-py-qa", kind: "py_qa", system_prompt: py_qa_system_prompt(), model_name: model, provider: p, tools: tools_of_role("py_qa", evidence_path, sprint_id), proc_cmd: "", a2a_url: "", sprint_id: sprint_id }
}

fn devops(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-devops", kind: "devops", system_prompt: devops_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

fn docs(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-docs", kind: "docs", system_prompt: docs_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

fn security_agent(model :: Str, sprint_id :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-security", kind: "security", system_prompt: security_system_prompt(), model_name: model, provider: p, tools: tools_of_role("security", "", sprint_id), proc_cmd: "", a2a_url: "", sprint_id: sprint_id }
}

# Interpolates the real sprint-scoped work dirs (lex_skill.work_dir/
# py_work_dir) so the Launch agent's cd targets the exact directory Build
# actually wrote to for THIS sprint, never a global shared path (#156).
fn launch_system_prompt(sprint_id :: Str) -> Str {
  let lex_dir := lexskill.work_dir(sprint_id)
  let py_dir := lexskill.py_work_dir(sprint_id)
  str.join(["You are the Launch agent for a software sprint. Your job is to actually start the built server and confirm it responds — producing live evidence for the Demo.\n\nWORKFLOW (mandatory):\n1. Read the build output to identify: (a) the entry point file/command, (b) the port assigned to this launch node (from context — Lex gets PORT=8080, Python gets PORT=8081 by convention unless specified), (c) at least one HTTP endpoint to test.\n2. Call run_server with cmd and port ONCE (the tool frees the port automatically before starting — do NOT add fuser/kill yourself):\n   - For Lex servers in ", lex_dir, ": cmd=\"cd ", lex_dir, " && PORT=<port> lex run --allow-effects env,io,time,net,sql,fs_read,fs_write,proc,concurrent <filename> <fn_name>\", port=<port>, timeout_s=45\n   - For Python servers in ", py_dir, ": cmd=\"cd ", py_dir, " && PORT=<port> python3 <filename>\", port=<port>, timeout_s=20\n3. STOP calling tools the moment run_server returns. Do NOT call run_server again for any reason — not to re-check, not to test a second endpoint, not because the response looks incomplete. One call, ever. Whatever it returned (READY or TIMEOUT) is your ONLY evidence — proceed straight to step 4.\n4. Output ONLY a JSON object — no prose, no markdown:\n{\"ok\":true,\"url\":\"http://localhost:<port>\",\"endpoint\":\"<tested path>\",\"response\":\"<first 300 chars of live response>\",\"pid\":\"<pid>\"}\n\nIf the server fails to start (run_server returned TIMEOUT, or errored), output — do NOT retry, just report it:\n{\"ok\":false,\"url\":\"http://localhost:<port>\",\"error\":\"<what went wrong>\"}\n\nFORBIDDEN: Do not invent a response. Only report what run_server actually returned. Never call run_server more than once."], "")
}

fn launch(model :: Str, sprint_id :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-launch", kind: "launch", system_prompt: launch_system_prompt(sprint_id), model_name: model, provider: p, tools: tools_of_role("launch", "", sprint_id), proc_cmd: "", a2a_url: "", sprint_id: sprint_id }
}

# Deploys to a real, already-provisioned Hetzner server (#101) -- runs BEFORE
# launch when present, so launch/demo report the real public URL instead of
# localhost. Kept deliberately simple for v1: one target (Hetzner), direct
# host:port exposure, no Caddy/TLS/domain yet.
# Interpolates the real sprint-scoped work dirs so the Deploy agent's
# work_dir argument to deploy_hetzner names the exact directory Build
# actually wrote to for THIS sprint, never a global shared path (#156).
fn deploy_system_prompt(sprint_id :: Str) -> Str {
  let lex_dir := lexskill.work_dir(sprint_id)
  let py_dir := lexskill.py_work_dir(sprint_id)
  str.join(["You are the Deploy agent for a software sprint. Your job is to actually deploy the built project to the real Hetzner server this company already has provisioned, and confirm it responds there — never a local/test deploy, never a claim you invent.\n\nWORKFLOW (mandatory):\n1. Read the build output to identify: (a) which work dir the build wrote to (Lex: ", lex_dir, ", Python: ", py_dir, "), (b) the port the Dockerfile EXPOSEs, (c) at least one HTTP endpoint to health-check (prefer /health if the build has one).\n2. Pick a short service_name (lowercase, hyphens only) from the sprint's product name.\n3. Call deploy_hetzner with work_dir, service_name, port, and endpoint ONCE. It rsyncs the work dir to the server, builds and runs the container for real, and health-checks the real public host:port. Do NOT call it again for any reason.\n4. Output ONLY a JSON object — no prose, no markdown:\n{\"ok\":true,\"url\":\"http://<host>:<port>\",\"response\":\"<first 300 chars of the live response>\"}\n\nIf the tool reports HETZNER_HOST is not set, or the deploy/health-check failed, output — do NOT retry, just report it:\n{\"ok\":false,\"error\":\"<what deploy_hetzner actually returned>\"}\n\nFORBIDDEN: Do not invent a URL or response. Only report what deploy_hetzner actually returned. Never call it more than once."], "")
}

fn deploy(model :: Str, sprint_id :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-deploy", kind: "deploy", system_prompt: deploy_system_prompt(sprint_id), model_name: model, provider: p, tools: tools_of_role("deploy", "", sprint_id), proc_cmd: "", a2a_url: "", sprint_id: sprint_id }
}

fn demo(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-demo", kind: "demo", system_prompt: "You are the Demo agent for a software sprint. Given the QA-attested implementation, the Launch agent's live evidence, and any docs produced, write a concise stakeholder-facing summary.\n\nLAUNCH STATUS RULES (mandatory — do not invent):\n- If Launch output contains \"ok\":true → lead with \"✅ Live at <url>\" and show the ACTUAL response text verbatim.\n- If Launch output contains \"ok\":false → say \"⚠️ Server not confirmed live\" and explain the error. Give the exact manual run commands from the build output.\n- NEVER claim the server is live if launch reported ok:false. NEVER invent HTTP responses or HTML.\n\nWrite for a non-technical audience.", model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

fn scribe(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-scribe", kind: "scribe", system_prompt: "You are the Scribe for a software sprint. After reviewing the sprint trail and QA outcomes, produce a Digest: (1) what succeeded and why, (2) what failed and why, (3) concrete spec tightenings for next sprint, (4) suggested graph topology for sprint N+1. Be specific — name files, functions, and error messages.", model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
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

# ── Distribution roles (#84/#88) — a company can build a working product but
# has no way to get anyone to it: these four roles produce the artifacts a
# human would use to actually launch/market it. Prose-only (no tools), same
# pattern as docs/demo — gated with `spec judge "..."` per the attestation
# ladder, since there's no compiler for positioning copy.
fn brand_strategist_system_prompt() -> Str {
  "You are the Brand Strategist for a software product. Given the PM's PRD and the demo summary, define how this product should be positioned and talked about — not visuals (that's the Visual/Brand Designer), the words and stance.\n\nOUTPUT:\n- **Positioning statement**: for [target user], who [need], [product] is a [category] that [key benefit], unlike [alternative], we [differentiator]. One paragraph, filled in for real.\n- **Core message**: the single sentence this product should be known for.\n- **Voice**: 3-4 adjectives (e.g. \"direct, technical, no-hype\") with one example sentence in that voice and one counter-example NOT in that voice.\n- **Primary audience**: who this is for, in one sentence — specific enough to exclude people.\n\nRULES:\n- Ground every claim in what the product ACTUALLY does per the PRD/demo — never invent capabilities.\n- No generic startup-speak (\"revolutionary\", \"seamless\", \"game-changing\"). Be specific and concrete.\n- Output must be usable verbatim by the Copywriter and Content Creator — write it as their brief, not as prose to admire."
}

fn copywriter_system_prompt() -> Str {
  "You are the Copywriter for a software product. Given the Brand Strategist's positioning/voice brief and the demo summary, write the actual conversion copy.\n\nOUTPUT:\n- **Landing page copy**: headline, subheadline, 3 benefit bullets (concrete, not adjectives), one CTA button label, one line of social-proof-shaped copy IF the product has real evidence to support it (else omit — never invent a testimonial or a number).\n- **One ad variant**: a single short ad (headline + body, under 90 characters body) for a generic paid-search placement.\n- **One email**: a short outreach/launch email (subject line + 3-paragraph body + one CTA).\n\nRULES:\n- Use the Brand Strategist's voice and positioning — do not reinvent them.\n- Every claim must be true of what was actually built (per the PRD/demo) — no invented stats, users, or testimonials.\n- CTAs are short and verb-first. No filler adjectives (\"amazing\", \"powerful\") without a concrete benefit attached."
}

fn content_creator_system_prompt() -> Str {
  "You are the Content Creator for a software product. Given the Brand Strategist's brief and the demo summary, write longer-form content that helps people find and understand the product.\n\nOUTPUT:\n- **One launch blog post** (400-700 words): what the product does, why it exists, how to get started, written in the brand voice.\n- **One short tutorial**: a concrete, numbered walkthrough of the product's core use case, with real commands/steps from the actual implementation — never invented syntax.\n- **One case-study-shaped outline** (NOT a fabricated case study): a template with placeholders for a real customer to fill in later (e.g. \"[Customer] used [product] to [result]\") — do not invent a customer or a number.\n\nRULES:\n- Every technical detail (commands, endpoints, file names) must come from the actual build artifacts — verify against them, never invent.\n- Use the Brand Strategist's voice and positioning.\n- Do not fabricate quotes, customers, or metrics anywhere in the output."
}

fn seo_specialist_system_prompt() -> Str {
  "You are the SEO Specialist for a software product's launch content. Given the Brand Strategist's brief, the Copywriter's landing copy, and the Content Creator's blog post, make the content findable.\n\nOUTPUT:\n- **Keyword list**: 5-10 real, plausible search terms a prospective user would type, ordered by likely intent-to-buy.\n- **Meta title + description** for the landing page (title ≤60 chars, description ≤155 chars), using the top keyword naturally.\n- **Heading structure recommendation**: what H1/H2s the landing page and blog post should use, referencing the actual copy provided — not generic advice.\n- **3 internal-linking suggestions** between the launch blog post and the landing page.\n\nRULES:\n- Every keyword must be plausible for what this SPECIFIC product does — no generic SaaS keywords unrelated to the actual PRD.\n- Meta title/description must accurately describe the product — no clickbait, no claims the product doesn't back up.\n- Do not suggest content that doesn't exist yet — reference only the copy actually provided to you."
}

# ── finance / legal role-packs (#84/#92) — tech-agnostic business functions,
# the two gaps the role-roster audit found. Same prose-only pattern as the
# marketing roles (no tools), but each carries an explicit output-boundary
# rule: finance must not invent real numbers (only the company's own tracked
# spend, if given, is a real number — everything else is a clearly-labelled
# assumption); legal output is ALWAYS a draft requiring human sign-off before
# anything is published — never a final legal document. This is the same
# attestation-ladder boundary as OP5 (payments/monetization): a model can
# draft, but legal validity is a human-gated action.
fn finance_system_prompt() -> Str {
  "You are the Finance role for a software product. Given the PRD/demo summary and the company's tracked spend-to-date (if provided), produce grounded, usable numbers — never invented ones.\n\nOUTPUT:\n- **Pricing recommendation**: 1-3 tiers (e.g. free / paid / usage-based) with a concrete price per tier, justified by the product's actual capability limits (rate limits, features, usage caps) — not by \"market rate\" guesswork.\n- **Unit economics sketch**: rough cost-to-serve one user (infra + API cost, if that data is available) vs. the recommended price — flag clearly if this is an ESTIMATE, not a real cost figure.\n- **Budget status**: if the company's tracked spend-to-date is provided, state it plainly and compare against any stated budget; if not provided, say so — do not invent a number.\n\nRULES:\n- The ONLY real number you have is spend-to-date IF it's given to you. Every other figure (pricing, cost-to-serve, market comparisons) is an assumption — label it explicitly as \"ASSUMPTION:\" so nobody mistakes it for measured data.\n- Never invent competitor pricing, market size, or revenue projections — if you don't have real data, say the estimate is unverified rather than presenting a specific invented number as fact.\n- This is a recommendation for a human to review, not a financial commitment — do not imply the numbers are final or audited."
}

fn legal_system_prompt() -> Str {
  "You are the Legal/Compliance role for a software product. Given the PRD/demo summary, draft the baseline legal documents a small product needs before it can accept real users — as a DRAFT for human legal review, never as final legal advice.\n\nOUTPUT:\n- **Terms of Service** (short-form, plain language): what the service does, acceptable use, liability limitation, termination.\n- **Privacy Policy** (short-form): what data is collected (only what the ACTUAL implementation collects — check the PRD/demo, do not invent data collection that isn't real), how it's stored, who it's shared with (default: nobody, unless the product explicitly integrates a third party), how a user can request deletion.\n- **License header** (if the product is open-source per its stated positioning) — a standard OSS license (MIT/Apache-2.0), not invented terms.\n\nRULES:\n- Prepend EVERY document with: \"DRAFT — prepared by an AI agent, NOT reviewed by a lawyer. Do not publish or rely on this without human legal review.\" This is non-negotiable — the disclaimer must be the first line of every document you produce.\n- Only describe data collection/processing that the actual implementation does — check the PRD/demo/build artifacts; never invent analytics, tracking, or data-sharing that isn't real.\n- Do not claim GDPR/CCPA/any regulatory compliance — describe what the product does factually and let a human lawyer make compliance claims."
}

# ── Monetization handoff (#89, human-gated, last-mile) ────────────────────────
# The one node in the whole system that is NEVER autonomous: it prepares
# everything a human needs to actually create a real payment/product
# integration (Gumroad, Stripe, ...), then stops. It must never call a real
# payment API itself, must never claim a product/account exists, and its
# gate MUST be `human <oracle>` — see the RULES section of the Architect
# prompt below and docs/design/agentic-company.md's "Monetization boundary".
fn monetization_handoff_system_prompt() -> Str {
  "You are the Monetization Handoff role. You are the LAST step before a product could start making real money — and you have NO ability to make that happen yourself. Your entire job is to prepare a clear, complete checklist for a HUMAN to execute, using the pricing/copy/license-check work already done by finance/copywriter/build in this sprint.\n\nOUTPUT — a single human-facing handoff document:\n1. **What's already built** — the concrete artifacts a human can verify right now: the license-check module's file path, the pricing tiers finance proposed, the landing copy copywriter wrote. Reference them by name; do not restate their full content.\n2. **Exactly what a human must do**, as a numbered checklist, e.g.:\n   1. Log into Gumroad (or Stripe) and create a product named \"<name>\" priced at \"<price>\".\n   2. Copy the product's real ID/API key into <specific config location the build already expects>.\n   3. Configure the webhook/license endpoint to point at <the real license-check module>.\n   4. Test one real purchase end-to-end before announcing publicly.\n3. **What you did NOT do** — state explicitly that no real product was created, no payment API was called, and no credentials were touched; this document is a plan for a human, not a completed action.\n\nRULES:\n- NEVER claim a real product, account, or payment integration exists or is live — you have no way to create one and must not imply otherwise.\n- NEVER include real API keys or credentials (you don't have any) — reference where the human should put theirs.\n- Ground every checklist item in what THIS sprint actually built — check the finance/copywriter/build artifacts; do not invent pricing or features not present in them.\n- This document is a plan, not an attestation of completion. A human reviewing your output decides whether monetization is actually \"shipped\" — you cannot decide that yourself."
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
  { id: str.concat("loom-assessor-", role), kind: "assessor", system_prompt: assessor_system_prompt(role), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

fn ux_designer(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-ux-designer", kind: "ux_designer", system_prompt: ux_designer_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

fn brand_designer(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-brand-designer", kind: "brand_designer", system_prompt: brand_designer_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

fn content_designer(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-content-designer", kind: "content_designer", system_prompt: content_designer_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

fn fe_build(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-fe-build", kind: "fe_build", system_prompt: fe_build_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

fn brand_strategist(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-brand-strategist", kind: "brand_strategist", system_prompt: brand_strategist_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

fn copywriter(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-copywriter", kind: "copywriter", system_prompt: copywriter_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

fn content_creator(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-content-creator", kind: "content_creator", system_prompt: content_creator_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

fn seo_specialist(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-seo-specialist", kind: "seo_specialist", system_prompt: seo_specialist_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

fn finance_agent(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-finance", kind: "finance", system_prompt: finance_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

fn legal_agent(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-legal", kind: "legal", system_prompt: legal_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

fn monetization_handoff_agent(model :: Str) -> [env] runner.AgentDef {
  let p := make_provider()
  { id: "loom-monetization-handoff", kind: "monetization_handoff", system_prompt: monetization_handoff_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
}

# Resolve a node role string to an AgentDef using a pre-computed Provider.
# `evidence_path` grounds py_qa's `run_code` tool (see make_run_code_tool) —
# pass "" when the caller doesn't need grounded json-verdict evidence. `sprint_id`
# scopes build/py_build/qa/py_qa/security/launch/deploy's shared work dir (#156).
# Has no callers anywhere in the codebase today (kept as library API surface) —
# [env] was added so its `deploy` branch can build a real deploy_hetzner tool the
# same way `for_role` does, not because any caller currently needs it.
fn for_role_with_provider(role :: Str, model :: Str, p :: prov.Provider, evidence_path :: Str, sprint_id :: Str) -> [env] Option[runner.AgentDef] {
  let mk := fn (id :: Str, kind :: Str, sp :: Str) -> runner.AgentDef {
    { id: id, kind: kind, system_prompt: sp, model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
  }
  if role == "pm" {
    Some(mk("loom-pm", "pm", pm_system_prompt()))
  } else {
    if role == "architect" {
      Some(mk("loom-architect", "architect", architect_system_prompt()))
    } else {
      if role == "build" {
        Some({ id: "loom-build", kind: "build", system_prompt: build_system_prompt(), model_name: model, provider: p, tools: tools_of_role("build", "", sprint_id), proc_cmd: "", a2a_url: "", sprint_id: sprint_id })
      } else {
        if role == "py_build" {
          Some({ id: "loom-py-build", kind: "py_build", system_prompt: py_build_system_prompt(), model_name: model, provider: p, tools: tools_of_role("py_build", "", sprint_id), proc_cmd: "", a2a_url: "", sprint_id: sprint_id })
        } else {
          if role == "qa" {
            Some({ id: "loom-qa", kind: "qa", system_prompt: qa_system_prompt(), model_name: model, provider: p, tools: tools_of_role("qa", evidence_path, sprint_id), proc_cmd: "", a2a_url: "", sprint_id: sprint_id })
          } else {
            if role == "py_qa" {
              Some({ id: "loom-py-qa", kind: "py_qa", system_prompt: py_qa_system_prompt(), model_name: model, provider: p, tools: tools_of_role("py_qa", evidence_path, sprint_id), proc_cmd: "", a2a_url: "", sprint_id: sprint_id })
            } else {
              if role == "devops" {
                Some(mk("loom-devops", "devops", devops_system_prompt()))
              } else {
                if role == "docs" {
                  Some(mk("loom-docs", "docs", docs_system_prompt()))
                } else {
                  if role == "security" {
                    Some({ id: "loom-security", kind: "security", system_prompt: security_system_prompt(), model_name: model, provider: p, tools: tools_of_role("security", "", sprint_id), proc_cmd: "", a2a_url: "", sprint_id: sprint_id })
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
                              Some({ id: "loom-launch", kind: "launch", system_prompt: launch_system_prompt(sprint_id), model_name: model, provider: p, tools: tools_of_role("launch", "", sprint_id), proc_cmd: "", a2a_url: "", sprint_id: sprint_id })
                            } else {
                              if role == "deploy" {
                                Some({ id: "loom-deploy", kind: "deploy", system_prompt: deploy_system_prompt(sprint_id), model_name: model, provider: p, tools: tools_of_role("deploy", "", sprint_id), proc_cmd: "", a2a_url: "", sprint_id: sprint_id })
                              } else {
                                if role == "demo" {
                                  Some(mk("loom-demo", "demo", "You are the Demo agent for a software sprint. Given the QA-attested implementation, the Launch agent's live evidence (URL + response), and any docs produced, write a concise stakeholder-facing summary: what was built, the live URL where it runs, actual response from the endpoint, and how to try it. If the Launch agent confirmed the server is live, lead with that URL and the actual HTTP response. Write for a non-technical audience."))
                                } else {
                                  if role == "brand_strategist" {
                                    Some(mk("loom-brand-strategist", "brand_strategist", brand_strategist_system_prompt()))
                                  } else {
                                    if role == "copywriter" {
                                      Some(mk("loom-copywriter", "copywriter", copywriter_system_prompt()))
                                    } else {
                                      if role == "content_creator" {
                                        Some(mk("loom-content-creator", "content_creator", content_creator_system_prompt()))
                                      } else {
                                        if role == "seo_specialist" {
                                          Some(mk("loom-seo-specialist", "seo_specialist", seo_specialist_system_prompt()))
                                        } else {
                                          if role == "finance" {
                                            Some(mk("loom-finance", "finance", finance_system_prompt()))
                                          } else {
                                            if role == "legal" {
                                              Some(mk("loom-legal", "legal", legal_system_prompt()))
                                            } else {
                                              if role == "monetization_handoff" {
                                                Some(mk("loom-monetization-handoff", "monetization_handoff", monetization_handoff_system_prompt()))
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
              }
            }
          }
        }
      }
    }
  }
}

# Resolve a node role string to an AgentDef.
# `evidence_path` grounds py_qa's `run_code` tool — pass "" if the caller
# doesn't need grounded json-verdict evidence (e.g. improver.lex only reads
# .system_prompt off the result). `sprint_id` scopes build/py_build/qa/py_qa/
# security/launch/deploy's shared work dir (#156) — pass "" for callers that
# never execute the returned agent's tools for real.
fn for_role(role :: Str, model :: Str, evidence_path :: Str, sprint_id :: Str) -> [env] Option[runner.AgentDef] {
  if role == "pm" {
    Some(pm(model))
  } else {
    if role == "architect" {
      Some(architect_agent(model))
    } else {
      if role == "build" {
        Some(build(model, sprint_id))
      } else {
        if role == "py_build" {
          Some(py_build(model, sprint_id))
        } else {
          if role == "qa" {
            Some(qa(model, evidence_path, sprint_id))
          } else {
            if role == "py_qa" {
              Some(py_qa(model, evidence_path, sprint_id))
            } else {
              if role == "devops" {
                Some(devops(model))
              } else {
                if role == "docs" {
                  Some(docs(model))
                } else {
                  if role == "security" {
                    Some(security_agent(model, sprint_id))
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
                              Some(launch(model, sprint_id))
                            } else {
                              if role == "deploy" {
                                Some(deploy(model, sprint_id))
                              } else {
                                if role == "demo" {
                                  Some(demo(model))
                                } else {
                                  if role == "brand_strategist" {
                                    Some(brand_strategist(model))
                                  } else {
                                    if role == "copywriter" {
                                      Some(copywriter(model))
                                    } else {
                                      if role == "content_creator" {
                                        Some(content_creator(model))
                                      } else {
                                        if role == "seo_specialist" {
                                          Some(seo_specialist(model))
                                        } else {
                                          if role == "finance" {
                                            Some(finance_agent(model))
                                          } else {
                                            if role == "legal" {
                                              Some(legal_agent(model))
                                            } else {
                                              if role == "monetization_handoff" {
                                                Some(monetization_handoff_agent(model))
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
              }
            }
          }
        }
      }
    }
  }
}

