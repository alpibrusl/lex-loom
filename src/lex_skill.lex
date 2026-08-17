# lex_skill.lex — Lex language skill: tools that give agents ground-truth
# knowledge of Lex, a language that is NOT in any model's training data.
#
# Three tools:
#   lex_guidelines — fetch authoritative Lex rules, topic-indexed:
#                    core | http | mcp | agent | sql | streaming | all
#   lex_check      — compile a .lex file, return structured type errors
#   lex_run        — execute a function (or run_all tests) in a .lex file
#
# The lex binary is resolved by bash as ${LEX:-lex}, so the tools stay pure
# (no env effect) and work in both the role constructors and the pure resolver.
# All files are written to a shared work dir so multi-file projects (a module
# plus its test that imports it) resolve imports across calls.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "lex-llm/src/tool" as t

import "lex-schema/schema" as s

import "lex-schema/json_value" as jv

import "lex-schema/error" as e

import "std.process" as proc

# A stray "/" in sprint_id (company iterations are ids like "<company>/iter-N")
# would otherwise split into a nested path component; flatten it instead.
fn sanitize_sprint_id(sprint_id :: Str) -> Str {
  str.replace(sprint_id, "/", "_")
}

# Scoped per sprint so two sprints running on the same machine — a live
# company's current iteration and an unrelated later sprint or test run —
# never share, and can never silently overwrite, each other's build files.
# Found live: a global "/tmp/loom-lex-work" was overwritten by a later test
# run's fixture seeding while a real company's server was still running out
# of it (#156).
fn work_dir(sprint_id :: Str) -> Str {
  str.join(["/tmp/loom-lex-work-", sanitize_sprint_id(sprint_id)], "")
}

# Python builds use a separate work dir so a parallel Lex build never clobbers
# them. Must match runner.py_work_dir().
fn py_work_dir(sprint_id :: Str) -> Str {
  str.join(["/tmp/loom-py-work-", sanitize_sprint_id(sprint_id)], "")
}

# Node/TS builds get their own work dir for the same reason (#92 golden
# paths). Must match runner.ts_work_dir().
fn ts_work_dir(sprint_id :: Str) -> Str {
  str.join(["/tmp/loom-ts-work-", sanitize_sprint_id(sprint_id)], "")
}

# Concise Lex essentials — the must-knows for a model that has never seen Lex.
# Kept small on purpose: it stays in the agent's conversation and is
# re-serialized every turn, so a 20KB dump (full `lex agent-guidelines`) would
# blow the orchestrator worker's step budget over a multi-turn tool loop.
fn lex_essentials() -> Str {
  str.join(["LEX LANGUAGE ESSENTIALS (you have NOT seen Lex before — follow exactly).", "", "LOOP: write a file, call lex_check, read errors, repair, repeat until ok='true'.", "", "SYNTAX:", "- Comments use # not //.", "- Booleans are true/false (lowercase), never True/False.", "- Unit value is (), never `unit`. Unit type is Unit.", "- let bindings are immutable; there is no `mut`, no reassignment, no `var`.", "- No `return`; a function's last expression is its value.", "- Function body is always wrapped in { }, even a single match.", "", "CONTROL FLOW:", "- No `else if`. Nest: if a { x } else { if b { y } else { z } }.", "- No && or ||. AND: if a { b } else { false }. OR: if a { true } else { b }.", "- No `not`/`!`. Negate: if x { false } else { true }.", "- No while/for loops. Use recursion or list.fold / list.map.", "", "TYPES:", "- ADT: type T = A | B(Str) | C(Int, Bool)   (NO leading |).", "- Record: type R = { field :: Str, n :: Int }.", "- Generics: Option[A], List[A], Result[A, B].", "- Pattern match must be exhaustive; add `_ => ...` if needed.", "- No tuple field access (pair.0); destructure: match pair { (a, b) => a }.", "", "FUNCTIONS & EFFECTS:", "- fn name(x :: Str, n :: Int) -> RetType { ... }", "- Effects go before the return type: fn f(p :: Str) -> [sql, net] Result[Str, Str].", "- Effect labels: io, fs_read, fs_write, sql, net, time, random, crypto, env, proc, concurrent, llm.", "", "IMPORTS (nothing is auto-available):", "- import \"std.list\" as list  /  \"std.str\" as str  /  \"std.int\" as int  /  \"std.io\" as io", "", "STDLIB (only these exist — do not invent functions):", "- str: len, slice(s,a,b), split, concat, join(list,sep), contains, starts_with, ends_with, to_lower, to_upper, trim, replace. NO index_of, NO to_chars, NO char_at.", "- list: map, filter, fold, len, is_empty, head (-> Option), tail, reverse, concat, cons, range. NO list.find (use filter then head).", "- int: to_str, to_float. NO int.from_str.", "- String concat: str.concat(a, b) or a + b.", "", "TESTS:", "- A test is `fn test_x() -> Result[Unit, Str]` returning Ok(()) or Err(\"msg\").", "- Entry point `fn run_all() -> Int` returns the number of FAILING tests (0 = all pass).", "- There is no `test \"...\"` syntax.", "", "PURE FUNCTIONS: add an examples { f(x) => y, ... } block — it runs at check time.", "", "After writing each file, ALWAYS call lex_check and fix every reported error."], "\n")
}

# ── Topic-indexed guides ─────────────────────────────────────────────────────
# HTTP server pattern — drawn from gateway_app.lex and weather_app.lex.
# Use topic='http' when implementing REST APIs or HTTP services.
fn guide_http() -> Str {
  str.join(["HTTP SERVER PATTERN (std.net)", "", "Two entry points:", "  net.serve(port, \"handle\")      -- handler fn referenced by name (string)", "  net.serve_fn(port, handler_fn) -- handler fn passed directly", "", "Request and Response types (declare these at the top of your file):", "  type Request  = { body :: Str, method :: Str, path :: Str, query :: Str }", "  type Response = { body :: Str, status :: Int }", "", "For streaming responses add a headers field:", "  type Response = { body :: ResponseBody, status :: Int, headers :: Map[Str, Str] }", "  -- ResponseBody variants: BodyStr(Str) | BodyStream(Iter[Str]) | BodyBytes(Iter[List[Int]])", "  -- Import: import \"std.map\" as map  then  map.from_list([(\"content-type\",\"application/json\")])", "", "ROUTING — match on method then path:", "  fn handle(req :: Request) -> [net, time, io] Response {", "    match req.method {", "      \"GET\" => match req.path {", "        \"/health\" => { status: 200, body: \"{\\\"ok\\\":true}\" },", "        _ => match str.strip_prefix(req.path, \"/items/\") {", "          Some(id) => get_item(id),", "          None     => { status: 404, body: \"{\\\"error\\\":\\\"not found\\\"}\" },", "        },", "      },", "      \"POST\" => match req.path {", "        \"/items\" => create_item(req.body),", "        _        => { status: 404, body: \"{\\\"error\\\":\\\"not found\\\"}\" },", "      },", "      _ => { status: 405, body: \"{\\\"error\\\":\\\"method not allowed\\\"}\" },", "    }", "  }", "  fn main() -> [net] Nil { net.serve(8080, \"handle\") }", "", "EFFECT DISCIPLINE for HTTP:", "  - Pure routes: no effect annotation on the route fn, but handle() must declare effects", "  - Route calling net.get: needs [net]", "  - Route calling io.read/write: needs [io] or [fs_read]/[fs_write]", "  - handle()'s effect row = union of all route effects", "  - main() always needs at least [net] for net.serve", "", "IMPORTS for HTTP:", "  import \"std.net\" as net", "  import \"std.str\" as str", "  import \"std.int\" as int", "  import \"std.map\" as map   # only if using headers/Map", "  import \"std.iter\" as iter  # only if streaming"], "\n")
}

# MCP server pattern — drawn from lex-mcp examples (echo_agent, dual_mount).
# Use topic='mcp' when implementing MCP servers or A2A+MCP agents.
fn guide_mcp() -> Str {
  str.join(["MCP SERVER PATTERN (lex-mcp)", "", "lex-mcp provides THREE transports from ONE AgentDef:", "", "1. STDIO (Claude Desktop, local tools):", "   import \"lex-mcp/src/mcp\" as mcp", "   fn main() -> [io, time, ...] Nil { mcp.server.run(my_agent) }", "", "2. HTTP (remote MCP clients / lex-mcp-client):", "   import \"lex-mcp/src/http\" as mcph", "   fn main() -> [net, io, ...] Nil { mcph.run_http(my_agent, 8080) }", "", "3. DUAL — A2A on / and MCP on /mcp, same port (RECOMMENDED):", "   import \"lex-mcp/src/compose\" as compose", "   fn main() -> [net, io, ...] Nil { compose.serve_both(my_agent, 8080) }", "   -- GET  /.well-known/agent.json  → A2A AgentCard", "   -- POST /                         → A2A JSON-RPC dispatch", "   -- POST /mcp                      → MCP streamable-HTTP dispatch", "   Both surfaces derive from the same skills list — they never drift.", "", "BUILDING AN AGENTDEF:", "   import \"lex-spec/capability\" as cap", "   import \"lex-schema/schema\" as sch", "   import \"lex-agent/src/agent_card\" as card", "   import \"lex-agent/src/server\" as srv", "   import \"lex-agent/src/message\" as msg", "", "   fn my_capability() -> cap.Capability {", "     cap.inbound(\"tool_name\", \"What it does.\",", "       { title: \"Args\", description: \"Input schema\",", "         fields: [sch.required_str(\"input\", [])] })", "   }", "", "   fn my_handler(m :: msg.Message) -> [io, ...] srv.HandlerOutcome {", "     let reply := msg.agent_text(\"response here\")", "     { next_state: TSCompleted, reply: Some(reply), artifacts: [] }", "   }", "", "   fn make_agent() -> srv.AgentDef {", "     let c := card.make(\"my-agent\", \"Description.\", \"0.1.0\",", "                        \"http://localhost:8080\", [my_capability()])", "     srv.make_agent_def(c, [{ capability: my_capability(), handle: my_handler }])", "   }", "", "EXTRACTING TEXT from a Message (DataPart arrives from MCP tools/call):", "   fn extract_text(parts :: List[msg.Part]) -> Str {", "     list.fold(parts, \"\", fn (acc :: Str, p :: msg.Part) -> Str {", "       if str.is_empty(acc) {", "         match p {", "           TextPart(s) => s,", "           DataPart(j) => match jv.get_field(j, \"text\") {", "             Some(v) => match jv.as_str(v) { Some(s) => s, None => acc },", "             None => acc,", "           },", "           _ => acc,", "         }", "       } else { acc }", "     })", "   }", "", "EFFECT ROW for MCP/A2A servers:", "   [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval]", "   (use this full row on main() and handler fns to avoid effect mismatch errors)", "", "IMPORTS for MCP:", "  import \"lex-schema/schema\" as sch", "  import \"lex-schema/json_value\" as jv", "  import \"lex-spec/capability\" as cap", "  import \"lex-agent/src/agent_card\" as card", "  import \"lex-agent/src/server\" as srv", "  import \"lex-agent/src/message\" as msg", "  import \"std.list\" as list", "  import \"std.str\" as str"], "\n")
}

# LLM agent loop pattern — drawn from lex-llm and lex-agent-llm.
# Use topic='agent' when implementing agents that call LLMs or dispatch to sub-agents.
fn guide_agent() -> Str {
  str.join(["LLM AGENT PATTERN (lex-llm + lex-agent-llm)", "", "lex-llm provides a multi-step tool-call loop. Provider is selected from env vars", "(LITELLM_BASE_URL → LiteLLM proxy, ANTHROPIC_API_KEY → Anthropic, etc.).", "", "PROVIDER SELECTION (from roles.lex — use the same pattern):", "  import \"lex-llm/src/providers\" as providers", "  -- providers.litellm()            # via LITELLM_BASE_URL", "  -- providers.anthropic()          # via ANTHROPIC_API_KEY", "  -- providers.ollama_at(url)       # local Ollama", "  -- providers.mlx_at(url)          # Apple Silicon MLX", "", "DEFINING AN AGENT:", "  import \"lex-llm/src/agent\" as ag", "  import \"lex-llm/src/provider\" as prov", "  import \"lex-llm/src/tool\" as t", "  import \"lex-llm/src/message\" as msg", "", "  let agent := {", "    name: \"my-agent\",", "    goal: \"System prompt here.\",", "    model: prov.make_model_ref(\"litellm\", \"qwen3-coder:30b\"),", "    provider: providers.litellm(),", "    tools: [my_tool],", "    options: { temperature: None, top_p: None, max_steps: Some(20), max_tokens: None },", "    permission_spec: None,", "  }", "", "RUNNING THE LOOP:", "  let messages := [msg.user(\"task description here\")]", "  let step_iter := ag.run_loop(agent, messages)", "  -- step_iter yields: TextChunk(s) | ToolCall(...) | StepDone(result)", "  -- Collect with iter.to_list(step_iter) or fold over it", "", "SUBPROCESS DISPATCH (agent_dispatcher pattern — proc effect):", "  import \"std.proc\" as proc", "  fn run_agent(cmd :: Str, args :: List[Str]) -> [proc] Result[Str, Str] {", "    match proc.spawn(cmd, args) {", "      Ok(r)  => Ok(r.stdout),", "      Err(e) => Err(e),", "    }", "  }", "  -- Requires --allow-proc <binary> at runtime", "", "WRAPPING AN LLM LOOP AS AN MCP/A2A SKILL (lex-agent-llm):", "  import \"lex-agent-llm/src/bridge\" as bridge", "  let skill := bridge.skill_of_loop(agent_def, loop_fn)", "", "IMPORTS for agent tasks:", "  import \"lex-llm/src/agent\" as ag", "  import \"lex-llm/src/provider\" as prov", "  import \"lex-llm/src/providers\" as providers", "  import \"lex-llm/src/tool\" as t", "  import \"lex-llm/src/message\" as msg", "  import \"std.proc\" as proc", "  import \"std.iter\" as iter"], "\n")
}

# SQL / persistence pattern — drawn from lex-trail and std.sql.
# Use topic='sql' when implementing SQLite-backed storage or audit logs.
# SQL guidance is GROUNDED in a real, CI-checked file (src/guidelines/sql_crud.lex)
# read at call time — so the API shown here can never drift from compiling code.
# (The previous hand-written version invented sql.str()/VStr/sql.Value, which do
#  not exist, and caused build agents to emit non-compiling SQLite code.)
fn guide_sql() -> [io] Str {
  let api := str.join(["SQL / PERSISTENCE PATTERN (std.sql)", "", "  import \"std.sql\" as sql", "", "FUNCTIONS (call as sql.NAME):", "  sql.open(path)            -> [sql, fs_write] Result[Db, SqlError]   # Db is OPAQUE", "  sql.exec(db, sqlstr, ps)  -> [sql] Result[Int, SqlError]            # rows affected", "  sql.query(db, sqlstr, ps) -> [sql] Result[List[Row], SqlError]      # SELECT", "", "PARAMS — the SqlParam ADT. GLOBAL constructors, NO `sql.` prefix:", "  PStr(s) | PInt(n) | PFloat(f) | PBool(b) | PNull", "  Bind `?` placeholders in order: [PStr(title), PInt(id)]", "", "ROWS — TYPED RECORDS you declare; field names match SELECTed columns.", "  Annotate the result and read fields directly (r.title):", "    type Note = { id :: Int, title :: Str, body :: Str }", "    let rows :: Result[List[Note], SqlError] := sql.query(db, \"SELECT id, title, body FROM notes\", [])", "", "  SqlError = { message :: Str, code :: Str, detail :: Str }", "", "DO NOT USE (these DO NOT EXIST): sql.str() / sql.int() / sql.Value / VStr / VInt /", "  List[List[sql.Value]] / sql.Db / sql.float() / sql.null(). Use the ADT + typed rows above.", "", "Any fn calling sql.* needs the [sql] effect; sql.open also needs [fs_write]."], "\n")
  let example := match io.read("src/guidelines/sql_crud.lex") {
    Ok(code) => str.join(["\n\nWORKED EXAMPLE — this exact file passes `lex check`; mirror it:\n```lex\n", code, "\n```"], ""),
    Err(_) => "",
  }
  str.join([api, example], "")
}

# Streaming HTTP pattern — drawn from streaming_app.lex.
# Use topic='streaming' when implementing SSE or chunked download endpoints.
fn guide_streaming() -> Str {
  str.join(["STREAMING HTTP PATTERN (std.net + std.iter)", "", "Use net.serve_fn (not net.serve) for streaming — it accepts a handler fn directly.", "", "ResponseBody variants for streaming:", "  BodyStr(Str)            -- eager string (non-streaming)", "  BodyStream(Iter[Str])   -- chunked text (SSE, line-by-line)", "  BodyBytes(Iter[List[Int]]) -- chunked binary", "", "Response type for streaming (must include headers field):", "  type Response = { body :: ResponseBody, status :: Int, headers :: Map[Str, Str] }", "", "SSE ENDPOINT EXAMPLE:", "  import \"std.net\"  as net", "  import \"std.iter\" as iter", "  import \"std.str\"  as str", "  import \"std.int\"  as int", "  import \"std.map\"  as map", "", "  fn sse_chunks() -> List[Str] {", "    let mk := fn (n :: Int) -> Str {", "      str.concat(str.concat(\"data: tick \", int.to_str(n)), \"\\n\\n\")", "    }", "    [mk(0), mk(1), mk(2)]", "  }", "", "  fn handler(req :: Request) -> Response {", "    match req.path {", "      \"/sse\" => {", "        status:  200,", "        body:    BodyStream(iter.from_list(sse_chunks())),", "        headers: map.from_list([(\"content-type\", \"text/event-stream\")]),", "      },", "      _ => { status: 404, body: BodyStr(\"not found\"),", "             headers: map.from_list([(\"content-type\", \"text/plain\")]) },", "    }", "  }", "  fn main() -> [net] Unit { net.serve_fn(8088, handler) }", "", "NOTE: BodyStream emits chunks under chunked transfer-encoding.", "      Content-Length is not set automatically — do not set it manually."], "\n")
}

# Select and combine guides by topic.
fn guide_for_topic(topic :: Str) -> [io] Str {
  let core := lex_essentials()
  if topic == "http" {
    str.join([core, "\n\n---\n\n", guide_http()], "")
  } else {
    if topic == "mcp" {
      str.join([core, "\n\n---\n\n", guide_mcp()], "")
    } else {
      if topic == "agent" {
        str.join([core, "\n\n---\n\n", guide_agent()], "")
      } else {
        if topic == "sql" {
          str.join([core, "\n\n---\n\n", guide_sql()], "")
        } else {
          if topic == "streaming" {
            str.join([core, "\n\n---\n\n", guide_streaming()], "")
          } else {
            if topic == "all" {
              str.join([core, "\n\n---\n\n", guide_http(), "\n\n---\n\n", guide_mcp(), "\n\n---\n\n", guide_agent(), "\n\n---\n\n", guide_sql(), "\n\n---\n\n", guide_streaming()], "")
            } else {
              core
            }
          }
        }
      }
    }
  }
}

# ── lex_guidelines ──────────────────────────────────────────────────────────
# Returns topic-indexed Lex language guides. Topics: core | http | mcp | agent | sql | streaming | all
# The model should call this FIRST with the relevant topic before writing any Lex code.
fn make_lex_guidelines_tool() -> t.Tool {
  let params := { title: "LexGuidelines", description: "Fetch Lex language rules by topic: core | http | mcp | agent | sql | streaming | all", fields: [s.required_str("topic", [])] }
  t.define("lex_guidelines", "Return Lex syntax, effect, type, stdlib, and pattern rules for the given topic. Topics: core (syntax only), http (REST server), mcp (MCP/A2A server), agent (LLM agent loop), sql (SQLite/lex-trail), streaming (SSE/chunked), all (everything). Lex is NOT in your training data — call this FIRST, before writing any Lex code.", params, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let topic := match jv.get_field(args, "topic") {
      Some(JStr(v)) => v,
      _ => "core",
    }
    Ok(JObj([("guidelines", JStr(guide_for_topic(topic)))]))
  })
}

# ── lex_check ───────────────────────────────────────────────────────────────
# Translate the compiler's terse diagnostics into the concrete edit a model that
# has never seen Lex needs. Keyed on stable error-message substrings; appended to
# the raw output so the agent still sees the original. These map the handful of
# mistakes local models make repeatedly (esp. in test files) — the #1 being
# `let x =` instead of Lex's `let x :=`, which prints the cryptic
# "expected ColonEq in let, got Eq".
fn lex_error_hints(output :: Str) -> Str {
  let h_let := if str.contains(output, "expected ColonEq in let") {
    "\nHINT: Lex let-bindings use `:=`, not `=`. You wrote `let x = ...`; change EVERY such line to `let x := ...`."
  } else {
    ""
  }
  let h_param := if str.contains(output, "expected ColonColon after parameter") {
    "\nHINT: Every function/lambda parameter needs a type annotation `name :: Type`. You wrote a bare parameter like `fn (t) -> ...` or `fn f(x) -> ...`; write `fn (t :: SomeType) -> ...` / `fn f(x :: SomeType) -> ...`. For list.map/filter/fold callbacks, annotate the element type, e.g. `fn (r :: Result[Unit, Str]) -> Bool`."
  } else {
    ""
  }
  let h_import := if str.contains(output, "expected As in import") {
    "\nHINT: Every import needs an alias. You wrote `import \"std.list\"`; it must be `import \"std.list\" as list`. Same for all modules: `import \"std.str\" as str`, `import \"std.io\" as io`."
  } else {
    ""
  }
  let h_id := if str.contains(output, "unknown_identifier") {
    "\nHINT: An identifier is undefined. (1) If it's a stdlib function (list.*, str.*, int.*, io.*), add `import \"std.<mod>\" as <mod>` at the top (there is no list.find/list.get — use filter+head). (2) If it's a function or type you defined in ANOTHER .lex file (e.g. `handle` or `Request` from server.lex), Lex does NOT auto-share names across files. Simplest fix: put the implementation AND its `run_all` tests in ONE file so the tests can call the functions directly — do not split across files."
  } else {
    ""
  }
  let h_tok := if str.contains(output, "unrecognized token") {
    "\nHINT: A token is not valid Lex. Common causes: `\\b`/`\\f`/`\\0` string escapes (not supported), `&&`/`||` (use nested if), `!`/`not` (negate via if), or `else if` (Lex has none — nest: `else { if c { } else { } }`)."
  } else {
    ""
  }
  let h_arity := if str.contains(output, "arity_mismatch") {
    "\nHINT: A call/constructor got the wrong number of args. Note record constructors like `AssistantMsg(a, b)` take positional args; check you destructure tuples via `match` (no `pair.0`)."
  } else {
    ""
  }
  str.join([h_let, h_param, h_import, h_id, h_tok, h_arity], "")
}

# ── QA evidence grounding (found live: qa's verdict was structurally
# ungroundable) ───────────────────────────────────────────────────────────────
# `spec json-verdict-pass` (mandated by the Architect's own rules for every
# qa/py_qa node) is only trusted when a real evidence file agrees with the
# claimed verdict (runner.verify_json_verdict_evidence). py_qa's run_code
# writes that file; lex_check/lex_run never did -- meaning every Lex `qa`
# node in every company this project has ever run was DENIED unconditionally,
# regardless of what the model did (confirmed live: 100% denial rate across
# both a real company run and a standalone smoke test). This merges each
# lex_check/lex_run call's real result into the same evidence file py_qa
# uses, so qa's grounding can actually succeed on real success.
fn json_bool_field(j :: jv.Json, key :: Str) -> Bool {
  match jv.get_field(j, key) {
    Some(JBool(v)) => v,
    _ => false,
  }
}

fn read_evidence_state(evidence_path :: Str) -> [io] { check_ok :: Bool, run_called :: Bool, run_ok :: Bool } {
  match io.read(evidence_path) {
    Err(_) => { check_ok: true, run_called: false, run_ok: true },
    Ok(raw) => match jv.parse(raw) {
      Err(_) => { check_ok: true, run_called: false, run_ok: true },
      Ok(j) => { check_ok: json_bool_field(j, "lex_check_ok"), run_called: json_bool_field(j, "lex_run_called"), run_ok: json_bool_field(j, "lex_run_ok") },
    },
  }
}

fn bool_json_str(b :: Bool) -> Str {
  if b {
    "true"
  } else {
    "false"
  }
}

fn write_evidence_state(evidence_path :: Str, check_ok :: Bool, run_called :: Bool, run_ok :: Bool) -> [io] Unit {
  let passed := if check_ok {
    if run_called {
      run_ok
    } else {
      true
    }
  } else {
    false
  }
  let json := str.join(["{\"ran\":true,\"lex_check_ok\":", bool_json_str(check_ok), ",\"lex_run_called\":", bool_json_str(run_called), ",\"lex_run_ok\":", bool_json_str(run_ok), ",\"passed\":", bool_json_str(passed), "}"], "")
  let __w := io.write(evidence_path, json)
  ()
}

# Called after a real lex_check result: AND this call's ok into the running
# "did every check so far pass" state, preserving any lex_run result already recorded.
fn record_lex_check_evidence(evidence_path :: Str, this_ok :: Bool) -> [io] Unit {
  let s := read_evidence_state(evidence_path)
  write_evidence_state(evidence_path, if s.check_ok {
    this_ok
  } else {
    false
  }, s.run_called, s.run_ok)
}

# Called after a real lex_run result: records it, preserving the accumulated
# lex_check state.
fn record_lex_run_evidence(evidence_path :: Str, this_ok :: Bool) -> [io] Unit {
  let s := read_evidence_state(evidence_path)
  write_evidence_state(evidence_path, s.check_ok, true, this_ok)
}

# Writes `code` to work_dir/<filename> and type-checks it. Returns structured
# errors so the model can repair. Files accumulate so imports resolve.
fn make_lex_check_tool(evidence_path :: Str, sprint_id :: Str) -> t.Tool {
  let dir := work_dir(sprint_id)
  let params := { title: "LexCheck", description: "Type-check a .lex file, return {ok, output}", fields: [s.required_str("filename", []), s.required_str("code", [])] }
  t.define("lex_check", "Write `code` to <filename> and run `lex check`. Returns {ok:'true'|'false', output:<json errors or 'ok'>}. ALWAYS call this after writing each .lex file and repair until ok='true' before finishing. Never claim code compiles without calling this.", params, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let filename := match jv.get_field(args, "filename") {
      Some(JStr(v)) => v,
      _ => "main.lex",
    }
    let code := match jv.get_field(args, "code") {
      Some(JStr(v)) => v,
      _ => "",
    }
    let path := str.join([dir, "/", filename], "")
    match proc.run("bash", ["-c", str.concat("mkdir -p ", dir)]) {
      Err(msg) => Err(e.single("", "proc_error", str.concat("mkdir failed: ", msg))),
      Ok(_) => {
        let __w := io.write(path, code)
        let cmd := str.join(["${LEX:-lex} check ", path, " 2>&1; echo '##EXIT:'$?"], "")
        match proc.run("bash", ["-c", cmd]) {
          Err(msg) => Ok(JObj([("ok", JStr("false")), ("output", JStr(msg))])),
          Ok(r) => {
            let combined := str.concat(r.stdout, r.stderr)
            let ok := str.contains(combined, "##EXIT:0")
            let out_with_hints := if ok {
              combined
            } else {
              str.concat(combined, lex_error_hints(combined))
            }
            let __ev := if str.is_empty(evidence_path) {
              ()
            } else {
              record_lex_check_evidence(evidence_path, ok)
            }
            Ok(JObj([("ok", JStr(if ok {
              "true"
            } else {
              "false"
            })), ("output", JStr(out_with_hints))]))
          },
        }
      },
    }
  })
}

# ── py_check ──────────────────────────────────────────────────────────────────
# The Python build gate, symmetric with lex_check. Writes `code` to
# py_work_dir/<filename> and compiles it with `python3 -m py_compile`. Files
# accumulate so multi-file projects build, and the runner recovers them as the
# node artifact. Without this gate a build agent can emit a prose plan that the
# build node accepts; py_compile forces real, parseable Python.
fn make_py_check_tool(sprint_id :: Str) -> t.Tool {
  let dir := py_work_dir(sprint_id)
  let params := { title: "PyCheck", description: "Compile a .py file, return {ok, output}", fields: [s.required_str("filename", []), s.required_str("code", [])] }
  t.define("py_check", "Write `code` to <filename> and run `python3 -m py_compile`. Returns {ok:'true'|'false', output:<compiler errors or 'ok'>}. ALWAYS call this after writing each .py file and repair until ok='true' before finishing. Never claim code compiles without calling this.", params, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let filename := match jv.get_field(args, "filename") {
      Some(JStr(v)) => v,
      _ => "app.py",
    }
    let code := match jv.get_field(args, "code") {
      Some(JStr(v)) => v,
      _ => "",
    }
    let path := str.join([dir, "/", filename], "")
    match proc.run("bash", ["-c", str.concat("mkdir -p ", dir)]) {
      Err(msg) => Err(e.single("", "proc_error", str.concat("mkdir failed: ", msg))),
      Ok(_) => {
        let __w := io.write(path, code)
        let cmd := str.join(["python3 -m py_compile ", path, " 2>&1 && echo 'ok'; echo '##EXIT:'$?"], "")
        match proc.run("bash", ["-c", cmd]) {
          Err(msg) => Ok(JObj([("ok", JStr("false")), ("output", JStr(msg))])),
          Ok(r) => {
            let combined := str.concat(r.stdout, r.stderr)
            let ok := str.contains(combined, "##EXIT:0")
            Ok(JObj([("ok", JStr(if ok {
              "true"
            } else {
              "false"
            })), ("output", JStr(combined))]))
          },
        }
      },
    }
  })
}

# ── ts_check ──────────────────────────────────────────────────────────────────
# The Node/TS build gate (#92), symmetric with py_check. Writes `code` to
# ts_work_dir/<filename> and syntax-checks it with Node itself: strip the
# types (module.stripTypeScriptTypes — throws on TS syntax errors) and parse
# the result as an ES module (vm.SourceTextModule — parse only, NEVER
# evaluated, so a server file can't start listening from inside the gate).
# Same strength class as py_compile: real, parseable code, no execution, no
# npm install. `node --check` is NOT usable here — found by real probe on
# Node 22, it parses every input as CommonJS regardless of extension or
# --input-type, so both type annotations and import statements become bogus
# SyntaxErrors.
fn make_ts_check_tool(sprint_id :: Str) -> t.Tool {
  let dir := ts_work_dir(sprint_id)
  let params := { title: "TsCheck", description: "Write a project file; syntax-check .ts/.js, parse-check .json, store the rest. Returns {ok, output}", fields: [s.required_str("filename", []), s.required_str("code", [])] }
  t.define("ts_check", "Write `code` to <filename> and validate it by type: .ts/.mts/.js/.mjs are syntax-checked with Node (type-strip + ES-module parse, no execution), .json/.webmanifest are parse-checked with JSON.parse, and any other file (html/css/svg/txt) is stored as-is with output 'stored'. Returns {ok:'true'|'false', output:<errors, 'ok', or 'stored'>}. ALWAYS call this for every file you produce (static assets included) and repair until ok='true' before finishing. Never claim code parses without calling this.", params, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let filename := match jv.get_field(args, "filename") {
      Some(JStr(v)) => v,
      _ => "app.ts",
    }
    let code := match jv.get_field(args, "code") {
      Some(JStr(v)) => v,
      _ => "",
    }
    if str.contains(filename, "..") {
      Ok(JObj([("ok", JStr("false")), ("output", JStr("filename must be a plain relative path (no '..')"))]))
    } else {
      let path := str.join([dir, "/", filename], "")
      let is_code := if str.ends_with(filename, ".ts") {
        true
      } else {
        if str.ends_with(filename, ".mts") {
          true
        } else {
          if str.ends_with(filename, ".js") {
            true
          } else {
            str.ends_with(filename, ".mjs")
          }
        }
      }
      let is_json := if str.ends_with(filename, ".json") {
        true
      } else {
        str.ends_with(filename, ".webmanifest")
      }
      match proc.run("bash", ["-c", str.join(["mkdir -p \"$(dirname \"", path, "\")\""], "")]) {
        Err(msg) => Err(e.single("", "proc_error", str.concat("mkdir failed: ", msg))),
        Ok(_) => {
          let __w := io.write(path, code)
          if is_code {
            let cmd := str.join(["node --no-warnings --experimental-vm-modules -e 'const{stripTypeScriptTypes}=require(\"node:module\");const{SourceTextModule}=require(\"node:vm\");const fs=require(\"node:fs\");try{new SourceTextModule(stripTypeScriptTypes(fs.readFileSync(process.argv[1],\"utf8\")));process.exit(0)}catch(e){console.error(String(e&&e.message?e.message:e));process.exit(1)}' \"", path, "\" 2>&1 && echo 'ok'; echo '##EXIT:'$?"], "")
            match proc.run("bash", ["-c", cmd]) {
              Err(msg) => Ok(JObj([("ok", JStr("false")), ("output", JStr(msg))])),
              Ok(r) => {
                let combined := str.concat(r.stdout, r.stderr)
                let ok := str.contains(combined, "##EXIT:0")
                Ok(JObj([("ok", JStr(if ok {
                  "true"
                } else {
                  "false"
                })), ("output", JStr(combined))]))
              },
            }
          } else {
            if is_json {
              let cmd := str.join(["node -e 'JSON.parse(require(\"node:fs\").readFileSync(process.argv[1],\"utf8\"))' \"", path, "\" 2>&1 && echo 'ok'; echo '##EXIT:'$?"], "")
              match proc.run("bash", ["-c", cmd]) {
                Err(msg) => Ok(JObj([("ok", JStr("false")), ("output", JStr(msg))])),
                Ok(r) => {
                  let combined := str.concat(r.stdout, r.stderr)
                  let ok := str.contains(combined, "##EXIT:0")
                  Ok(JObj([("ok", JStr(if ok {
                    "true"
                  } else {
                    "false"
                  })), ("output", JStr(combined))]))
                },
              }
            } else {
              Ok(JObj([("ok", JStr("true")), ("output", JStr("stored"))]))
            }
          }
        },
      }
    }
  })
}

# ── security_scan ─────────────────────────────────────────────────────────────
# Grounds the security role's verdict in a real check instead of self-report:
# greps both build work dirs for a curated set of known-dangerous patterns
# (hardcoded secrets, shell/eval injection, string-built SQL, debug-mode-on).
# No external scanner (semgrep/bandit) is assumed installed — this is the
# same "real tool, not a string check" philosophy as py_check, scoped to what
# grep can verify deterministically. It is a floor, not a replacement for a
# real SAST tool in a production pipeline.
fn part_at_or(xs :: List[Str], i :: Int, default :: Str) -> Str {
  if i <= 0 {
    match list.head(xs) {
      None => default,
      Some(h) => h,
    }
  } else {
    part_at_or(list.tail(xs), i - 1, default)
  }
}

fn parse_security_record(rec :: Str) -> jv.Json {
  let fields := str.split(rec, "@@F@@")
  let sev := part_at_or(fields, 0, "")
  let file := part_at_or(fields, 1, "")
  let line := part_at_or(fields, 2, "")
  let snip := part_at_or(fields, 3, "")
  JObj([("severity", JStr(sev)), ("file", JStr(file)), ("line", JStr(line)), ("snippet", JStr(snip))])
}

fn make_security_scan_tool(sprint_id :: Str) -> t.Tool {
  let params := { title: "SecurityScan", description: "Scan the build work dirs for known-dangerous code patterns", fields: [] }
  t.define("security_scan", "Call this FIRST, before writing your verdict. Greps every file in the Lex and Python work dirs for hardcoded secrets, shell/eval injection, string-built SQL, and debug-mode-on. Returns {findings: [{severity, file, line, snippet}]} (empty list if none found). A GROUNDED check — you must not report PASS if this returns critical/high findings, and must not invent findings it did not report.", params, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let script := str.join(["scan() {\n", "  local dir=\"$1\"\n", "  [ -d \"$dir\" ] || return 0\n", "  cd \"$dir\" || return 0\n", "  local pats=(\n", "    'critical:(api_key|apikey|secret|password|passwd|token)[[:space:]]*[:=][[:space:]]*[\"'\"'\"'][A-Za-z0-9+/=_-]{8,}[\"'\"'\"']'\n", "    'critical:shell[[:space:]]*=[[:space:]]*True'\n", "    'critical:os\\.(system|popen)\\('\n", "    'critical:\\b(eval|exec)\\('\n", "    'high:execute\\((f[\"'\"'\"']|[\"'\"'\"'].*%s|[\"'\"'\"'].*\\+)'\n", "    'medium:debug[[:space:]]*=[[:space:]]*[Tt]rue'\n", "  )\n", "  for p in \"${pats[@]}\"; do\n", "    local sev=\"${p%%:*}\"\n", "    local rx=\"${p#*:}\"\n", "    grep -rniE \"$rx\" . --include='*.py' --include='*.lex' --include='*.js' --include='*.ts' --include='*.mts' 2>/dev/null | while IFS=: read -r f l snip; do\n", "      clean=$(echo \"$snip\" | sed -e 's/^[[:space:]]*//' -e 's/@@[FR]@@//g' | cut -c1-200)\n", "      printf '%s@@F@@%s@@F@@%s@@F@@%s@@R@@\\n' \"$sev\" \"${f#./}\" \"$l\" \"$clean\"\n", "    done\n", "  done\n", "}\n", "scan '", work_dir(sprint_id), "'\n", "scan '", py_work_dir(sprint_id), "'\n", "scan '", ts_work_dir(sprint_id), "'\n"], "")
    match proc.run("bash", ["-c", script]) {
      Err(msg) => Err(e.single("", "proc_error", str.concat("security_scan failed: ", msg))),
      Ok(r) => {
        let trimmed := str.trim(r.stdout)
        let cleaned := str.replace(trimmed, "@@R@@", "")
        let records := if str.is_empty(trimmed) {
          []
        } else {
          str.split(cleaned, "\n")
        }
        let non_empty := list.filter(records, fn (rec :: Str) -> Bool {
          str.is_empty(str.trim(rec)) == false
        })
        let findings := list.map(non_empty, parse_security_record)
        Ok(JObj([("findings", JList(findings))]))
      },
    }
  })
}

# ── lex_run ─────────────────────────────────────────────────────────────────
# Executes a function in a previously-checked file. For tests, use
# fn_name='run_all'. The file must already exist in the work dir (write it
# with lex_check first).
fn make_lex_run_tool(evidence_path :: Str, sprint_id :: Str) -> t.Tool {
  let dir := work_dir(sprint_id)
  let params := { title: "LexRun", description: "Run a function in a .lex file, return {ok, output}", fields: [s.required_str("filename", []), s.required_str("fn_name", []), s.required_str("args", [])] }
  t.define("lex_run", "Run `lex run <filename> <fn_name> <args>` on a file already written via lex_check. For tests use fn_name='run_all' and args=''. args are space-separated JSON values. Returns {ok, output}. Base your verdict on this output — never guess.", params, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let filename := match jv.get_field(args, "filename") {
      Some(JStr(v)) => v,
      _ => "main.lex",
    }
    let fn_name := match jv.get_field(args, "fn_name") {
      Some(JStr(v)) => v,
      _ => "main",
    }
    let extra := match jv.get_field(args, "args") {
      Some(JStr(v)) => v,
      _ => "",
    }
    let path := str.join([dir, "/", filename], "")
    let cmd := str.join(["${LEX:-lex} run --allow-effects io,fs_read,fs_write,time,random,crypto,net ", path, " ", fn_name, " ", extra, " 2>&1; echo '##EXIT:'$?"], "")
    match proc.run("bash", ["-c", cmd]) {
      Err(msg) => Ok(JObj([("ok", JStr("false")), ("output", JStr(msg))])),
      Ok(r) => {
        let combined := str.concat(r.stdout, r.stderr)
        let ok := str.contains(combined, "##EXIT:0")
        let __ev := if str.is_empty(evidence_path) {
          ()
        } else {
          record_lex_run_evidence(evidence_path, ok)
        }
        Ok(JObj([("ok", JStr(if ok {
          "true"
        } else {
          "false"
        })), ("output", JStr(combined))]))
      },
    }
  })
}

