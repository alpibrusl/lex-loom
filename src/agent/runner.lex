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
#             With LEX_OS_ISOLATION set, the same command is mediated
#             through `lex-os exec` under the phase's manifests.lex grant
#             first (docs/design/lex-os-isolation.md) — unset, unchanged.
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

import "std.process" as proc

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

import "lex-memory/src/memory" as mem

import "lex-orm/src/connection" as conn

import "./trace" as trace

import "../manifests" as manifests

import "../org" as org

import "../delegation" as delegation

import "../tool_grant" as tool_grant

import "../agui_store" as agui_store

import "std.env" as env

# sprint_id scopes build-kind roles' shared work dir (see build_work_dir/
# py_work_dir below) so two sprints never read/write each other's files (#156).
# Empty for roles that never touch a work dir (pm, architect, docs, ...).
type AgentDef = { id :: Str, kind :: Str, system_prompt :: Str, model_name :: Str, provider :: prov.Provider, tools :: List[t.Tool], proc_cmd :: Str, a2a_url :: Str, sprint_id :: Str }

type PeerInfo = { id :: Str, kind :: Str, name :: Str, inbox_url :: Str, role :: Str }

# ── P1b: op_call telemetry via wrapped tool handlers (#65) ────────────────────
# The first implementation destructured lex-llm's StepToolExec/StepToolResult
# variants, whose runtime payload is a bare Str (constructed with two positional
# args against a 1-tuple-param declaration) — the tuple destructure crashed
# every tool-using sprint. Instead of reading the Step stream, loom now observes
# its own tool handlers: every tool handed to an agent is wrapped so an executed
# invocation appends "<tool> ok|err" to a per-run ops file. The handler effect
# row is [net, io, proc] — no sql — so the wrapper cannot write the traces table
# itself; after the agent loop returns, flush_op_calls replays the file into
# `traces` as op_call events, the exact rows verify_operations (P1b) re-derives
# per-operation authority from. Coverage is the same class the Step-based
# emission had: tools that actually dispatched. A hallucinated tool name that
# lex-llm never dispatches executes nothing and leaves no op to prove.
fn ops_file(run_id :: Str) -> Str {
  str.join(["/tmp/loom-ops-", run_id, ".log"], "")
}

# Append one executed-tool record. Read-then-write is race-free here: calls
# within one agent loop are sequential, and the path is unique per run_id.
fn note_op_call(path :: Str, tool_name :: Str, ok :: Bool) -> [io] Unit {
  let prior := match io.read(path) {
    Ok(s) => s,
    Err(_) => "",
  }
  let __w := io.write(path, str.join([prior, tool_name, if ok {
    " ok"
  } else {
    " err"
  }, "\n"], ""))
  ()
}

# Same tool, same schema, same precondition — but the executor records its own
# invocation before returning. The wrapper stays inside the tool's
# [io, net, proc] row, so the record is a file append, not a traces write.
fn wrap_tool(path :: Str, tl :: t.Tool) -> t.Tool {
  let inner := tl.execute
  { name: tl.name, description: tl.description, params: tl.params, precondition: tl.precondition, approval_scope: tl.approval_scope, execute: fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    let out := inner(args)
    let ok := match out {
      Ok(_) => true,
      Err(_) => false,
    }
    let __n := note_op_call(path, tl.name, ok)
    out
  } }
}

fn op_call_json(agent_id :: Str, tool_name :: Str, ok :: Bool) -> Str {
  str.join(["{\"agent\":\"", agent_id, "\",\"tool\":\"", tool_name, "\",\"ok\":", if ok {
    "true"
  } else {
    "false"
  }, "}"], "")
}

# Replay the ops file into the traces table as op_call events and remove it.
fn flush_op_calls(db :: conn.ConnDb, run_id :: Str, agent_id :: Str) -> [io, sql, fs_write, time, proc] Unit {
  let path := ops_file(run_id)
  let content := match io.read(path) {
    Ok(s) => s,
    Err(_) => "",
  }
  let __rm := proc.run("bash", ["-c", str.concat("rm -f ", path)])
  let __each := list.fold(str.split(content, "\n"), (), fn (acc :: Unit, line :: Str) -> [sql, fs_write, time] Unit {
    let l := str.trim(line)
    if str.is_empty(l) {
      ()
    } else {
      let nm := match list.head(str.split(l, " ")) {
        None => "",
        Some(h) => h,
      }
      let ok := str.ends_with(l, " ok")
      trace.record(db, run_id, agent_id, "op_call", op_call_json(agent_id, nm, ok))
    }
  })
  ()
}

# Sum every UsageDelta a turn's provider reported this step (a tool-calling
# agent may take several turns; each turn reports its own usage). Providers
# that never report usage (most non-OpenAI-compatible ones today) contribute
# nothing, so the sum stays (0,0,0) rather than a wrong estimate.
fn sum_usage_tokens(steps :: List[d.Step]) -> (Int, Int, Int) {
  list.fold(steps, (0, 0, 0), fn (acc :: (Int, Int, Int), st :: d.Step) -> (Int, Int, Int) {
    match st {
      StepDelta(UsageDelta(p, c, t)) => match acc {
        (ap, ac, at) => (ap + p, ac + c, at + t),
      },
      _ => acc,
    }
  })
}

fn usage_json(p :: Int, c :: Int, t :: Int) -> Str {
  str.join(["{\"prompt_tokens\":", int.to_str(p), ",\"completion_tokens\":", int.to_str(c), ",\"total_tokens\":", int.to_str(t), "}"], "")
}

# Records this call's real token usage against `cost_owner` (a sprint_id for
# an in-sprint node, or a company_id for a between-iteration call like the
# strategist) using the SAME agent_id-as-owner convention `op_grant`/
# `node_started` already rely on, so company.lex's cost ledger can query it
# straightforwardly by that owner id (#94). A no-op when cost_owner is empty
# (proc_cmd/a2a_url paths never reach this branch anyway) or no provider in
# this turn ever reported usage.
fn record_usage(db :: conn.ConnDb, run_id :: Str, cost_owner :: Str, steps :: List[d.Step]) -> [sql, fs_write, time] Unit {
  if str.is_empty(cost_owner) {
    ()
  } else {
    match sum_usage_tokens(steps) {
      (p, c, t) => if t == 0 {
        ()
      } else {
        trace.record(db, run_id, cost_owner, "llm_usage", usage_json(p, c, t))
      },
    }
  }
}

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
# Lex and Python builds run in parallel, so each gets its OWN work dir — they
# must never share, or recover_build_artifact would mix one language's files into
# the other's artifact. Keep the Lex path in sync with lex_skill.work_dir() and
# the Python path with lex_skill.py_work_dir().
# Scoped per sprint -- keep in sync with lex_skill.sanitize_sprint_id.
fn sanitize_sprint_id(sprint_id :: Str) -> Str {
  str.replace(sprint_id, "/", "_")
}

fn build_work_dir(sprint_id :: Str) -> Str {
  str.join(["/tmp/loom-lex-work-", sanitize_sprint_id(sprint_id)], "")
}

fn py_work_dir(sprint_id :: Str) -> Str {
  str.join(["/tmp/loom-py-work-", sanitize_sprint_id(sprint_id)], "")
}

# Which work dir a build kind writes to (build → Lex, py_build → Python).
fn work_dir_for(kind :: Str, sprint_id :: Str) -> Str {
  if kind == "py_build" {
    py_work_dir(sprint_id)
  } else {
    build_work_dir(sprint_id)
  }
}

# True for any code-producing build node (Lex or Python).
fn is_build_kind(kind :: Str) -> Bool {
  if kind == "build" {
    true
  } else {
    kind == "py_build"
  }
}

# Per-role tool-call budget (max LLM rounds before the loop is force-stopped).
# The lex-llm default is 20, which suits build/py_build (they legitimately
# write+check many files across many rounds). But `launch` is single-shot: a
# correct launch is exactly two rounds — call run_server once, then emit the
# JSON verdict. Its run_server tool BLOCKS up to timeout_s (20-45s) waiting for
# the server, so if a model stochastically keeps re-calling it (a real,
# intermittent failure seen across runs — glm-5.2 et al.), a budget of 20
# means ~10 minutes of wasted blocking launches before the cap trips and the
# node fails its `spec json` gate anyway. A tight budget makes that failure
# CHEAP and FAST, and the node-level retry (max_node_retries) still gives a
# looping launch fresh attempts. Keep the default for every other role.
fn max_steps_for(kind :: Str) -> Int {
  if kind == "launch" {
    4
  } else {
    20
  }
}

fn has_fence(s :: Str) -> Bool {
  str.contains(s, "```")
}

# Start each build attempt from a clean work_dir so stale files don't leak in.
fn clear_work_dir(kind :: Str, sprint_id :: Str) -> [proc] Unit {
  let d := work_dir_for(kind, sprint_id)
  let __ := proc.run("bash", ["-c", str.join(["rm -rf ", d, "/* 2>/dev/null; mkdir -p ", d], "")])
  ()
}

# Emit every file written to the work_dir as a fenced block labelled with its
# filename — the format the QA agent extracts.
fn recover_build_artifact(kind :: Str, sprint_id :: Str) -> [proc] Str {
  let cmd := str.join(["cd ", work_dir_for(kind, sprint_id), " 2>/dev/null && for f in *; do [ -f \"$f\" ] && { echo '```'\"$f\"; cat \"$f\"; echo '```'; }; done"], "")
  match proc.run("bash", ["-c", cmd]) {
    Err(_) => "",
    Ok(r) => r.stdout,
  }
}

# Build gate: compile EVERY file the build agent wrote, not just the ones it
# bothered to check. Without this a build node can ship a correct server.lex
# alongside a test.lex that doesn't even parse — QA then fails and burns bounces.
# Compiles each file in the kind's work dir (lex check for .lex, py_compile for
# .py). Returns Ok(()) if all compile and at least one source file exists, else
# Err(<first failing file + compiler output>). Pure [proc] — runs the real
# compiler, same as the agent's own check tool.
fn verify_build_compiles(kind :: Str, sprint_id :: Str) -> [proc] Result[Unit, Str] {
  if is_build_kind(kind) {
    verify_compiles(kind, sprint_id)
  } else {
    Ok(())
  }
}

# Gate-driven compile check (#32, "spec compiles"). Unlike verify_build_compiles
# this runs regardless of role — the GATE, not the kind, decides it should run —
# so any code-producing node can declare `spec compiles` and have it enforced.
# Compiles every source file in the node's work dir; py_compile for py_build,
# `lex check` otherwise. Returns Ok(()) iff all compile and ≥1 source file exists.
# Grounded TOOL gate (`spec sh "<cmd>"`): run an arbitrary verifier in the node's
# work dir; pass iff it exits 0. The general grounding primitive — wraps ANY
# tool (docker build, semgrep, gitleaks, dbt test, an ML metric script) the same
# way `spec compiles` wraps the compiler. Runs on the files the node produced
# (build/py_build/fe_build work dir). Trusted-sprint use: the gate is author-
# defined and runs at the same trust level as the build agent's own code.
fn verify_shell(cmd :: Str, kind :: Str, sprint_id :: Str) -> [proc] Result[Unit, Str] {
  let dir := work_dir_for(kind, sprint_id)
  let script := str.join(["cd ", dir, " 2>/dev/null || { echo NO_WORKDIR; exit 3; }; ", cmd, "; rc=$?; echo \"##GATE_EXIT:$rc\"; exit $rc"], "")
  match proc.run("bash", ["-c", script]) {
    Err(msg) => Err(str.concat("gate command could not run: ", msg)),
    Ok(r) => {
      let combined := str.concat(r.stdout, r.stderr)
      if str.contains(combined, "##GATE_EXIT:0") {
        Ok(())
      } else {
        if str.contains(combined, "NO_WORKDIR") {
          Err("gate: node produced no files (work dir missing)")
        } else {
          Err(str.concat("gate command failed:\n", str.slice(combined, 0, 1200)))
        }
      }
    },
  }
}

# `spec sh` for a NON-build role (devops, security, docs, finance, legal, ...).
# verify_shell above only makes sense for build/py_build: those roles' tools
# (lex_check/py_check) actually persist files to work_dir_for(kind) across the
# node's tool-call turns. Every other role has no such tool — it just returns
# prose/code fenced in its final answer, which never touches disk — so
# verify_shell would run the gate command against a stale or unrelated work
# dir (e.g. a devops node's `spec sh "docker build..."` silently checking
# whatever the LAST build/py_build node happened to leave in /tmp/loom-lex-
# work, which the devops agent never wrote to). Found live: an e2e sprint
# where devops was denied every attempt because its Dockerfile output was
# never written anywhere the gate could see (#21).
#
# Fix: re-materialize the node's own `output` into a fresh scratch dir via
# extract_fenced.py (same mechanism verify.lex's independent reverify_grounded
# already uses for post-hoc verification) and run the gate command there —
# grounding it in what THIS node actually produced, for any role.
fn verify_shell_on_output(cmd :: Str, output :: Str, scratch :: Str) -> [io, proc] Result[Unit, Str] {
  let art := str.join(["/tmp/loom-gate-", scratch, "-art.txt"], "")
  let work := str.join(["/tmp/loom-gate-", scratch, "-work"], "")
  let __w := io.write(art, output)
  let script := str.join(["W=", work, "; rm -rf $W; mkdir -p $W; python3 bin/extract_fenced.py ", art, " $W >/dev/null 2>&1; cd $W && n=$(find . -type f | wc -l); if [ \"$n\" -eq 0 ]; then echo NO_FILES; exit 3; fi; ", cmd, "; rc=$?; echo \"##GATE_EXIT:$rc\"; exit $rc"], "")
  match proc.run("bash", ["-c", script]) {
    Err(msg) => Err(str.concat("gate command could not run: ", msg)),
    Ok(r) => {
      let combined := str.concat(r.stdout, r.stderr)
      if str.contains(combined, "##GATE_EXIT:0") {
        Ok(())
      } else {
        if str.contains(combined, "NO_FILES") {
          Err("gate: node produced no fenced files to check (write your output as fenced code blocks, e.g. ```Dockerfile)")
        } else {
          Err(str.concat("gate command failed:\n", str.slice(combined, 0, 1200)))
        }
      }
    },
  }
}

fn verify_compiles(kind :: Str, sprint_id :: Str) -> [proc] Result[Unit, Str] {
  {
    let dir := work_dir_for(kind, sprint_id)
    let check := if kind == "py_build" {
      "python3 -m py_compile"
    } else {
      "${LEX:-lex} check"
    }
    let ext := if kind == "py_build" {
      "py"
    } else {
      "lex"
    }
    let script := str.join(["cd ", dir, " 2>/dev/null || { echo 'NO_WORKDIR'; exit 3; }; n=0; for f in *.", ext, "; do [ -f \"$f\" ] || continue; n=$((n+1)); out=$(", check, " \"$f\" 2>&1); if [ $? -ne 0 ]; then echo \"COMPILE_FAIL $f\"; echo \"$out\"; exit 1; fi; done; if [ $n -eq 0 ]; then echo 'NO_SOURCE_FILES'; exit 2; fi; echo OK"], "")
    match proc.run("bash", ["-c", script]) {
      Err(msg) => Err(str.concat("compile check could not run: ", msg)),
      Ok(r) => {
        let combined := str.concat(r.stdout, r.stderr)
        if str.contains(combined, "OK") {
          Ok(())
        } else {
          if str.contains(combined, "NO_SOURCE_FILES") {
            Err(str.concat("build produced no ", str.concat(ext, " source files — output was prose, not code")))
          } else {
            if str.contains(combined, "NO_WORKDIR") {
              Err("build produced no files (work dir missing)")
            } else {
              Err(str.concat("a source file failed to compile:\n", combined))
            }
          }
        }
      },
    }
  }
}

# ── Grounded evidence for `spec json-verdict-pass` ──────────────────────────
# The gate used to trust a QA agent's self-reported "verdict" field
# unconditionally (gates.lex's extract_verdict is a linear string scan with
# no independent check). That let a hallucinated or stale PASS through with
# no evidence run_code was ever actually called. This ties the verdict to a
# real subprocess result instead, the same grounding `spec compiles` already
# has via verify_compiles.
#
# Keyed by sprint+node (not attempt): the roster's AgentDef -- and therefore
# its run_code tool closure -- is built once per node before any attempt
# runs (cast.select_roster), so every retry's run_code calls land in the
# same file; each attempt's real result simply overwrites the last.
fn qa_evidence_path(sprint_id :: Str, node_id :: Str) -> Str {
  str.join(["/tmp/loom-qa-evidence-", str.replace(str.join([sprint_id, "_", node_id], ""), "/", "_"), ".json"], "")
}

# Clear any evidence left over from a previous attempt/sprint so a
# fabricated verdict can't be validated against stale real evidence.
fn clear_qa_evidence(path :: Str) -> [proc] Unit {
  let __ := proc.run("bash", ["-c", str.join(["rm -f '", path, "'"], "")])
  ()
}

# Deny unless the agent actually called run_code and its real result
# agrees with the verdict it claimed. `claimed_pass` is the gate's own
# extract_verdict("PASS"/other) reduced to a bool by the caller.
fn verify_json_verdict_evidence(path :: Str, claimed_pass :: Bool) -> [io] Result[Unit, Str] {
  match io.read(path) {
    Err(_) => Err("no run_code evidence found — the QA agent must call run_code before emitting a verdict, never guess"),
    Ok(raw) => {
      let evidence_pass := str.contains(raw, "\"passed\":true")
      if claimed_pass == evidence_pass {
        Ok(())
      } else {
        Err(str.join(["claimed verdict does not match run_code evidence (run_code actually reported passed=", if evidence_pass {
          "true"
        } else {
          "false"
        }, ")"], ""))
      }
    },
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
  match proc.run("bash", ["-c", "mktemp /tmp/loom-proc.XXXXXXXX"]) {
    Err(msg) => str.concat("PROC_ERROR: mktemp failed: ", msg),
    Ok(mk) => {
      let path := str.trim(mk.stdout)
      let __w := io.write(path, full_input)
      let cmd := str.join([def.proc_cmd, " < ", path, "; echo '##PROC_EXIT:'$?"], "")
      match proc.run("bash", ["-c", cmd]) {
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

# ── lex-os mediated exec (opt-in) ────────────────────────────────────────────
# Pure — the env read (LEX_OS_SIMULATED) lives in lex_os_exec_step, not here,
# so this stays dependency-free and directly unit-testable
# (tests/test_lex_os_exec_args.lex).
fn lex_os_exec_args(simulated :: Bool, manifest_path :: Str, cmd :: Str) -> List[Str] {
  let base := ["--output", "json", "exec"]
  let sim_flag := if simulated {
    ["--simulated"]
  } else {
    []
  }
  list.concat(base, list.concat(sim_flag, ["--manifest", manifest_path, "--", "bash", "-c", cmd]))
}

# simulated=true forces the in-process `--simulated` perimeter (OA3,
# lex-loom#184: LEX_OS_SIMULATED=1). false defers entirely to lex-os's own
# selection — real Firecracker by default on a KVM host, the same rule
# `lex-os run` already documents; off a KVM host with this unset, lex-os
# refuses rather than silently downgrading (lex-os's own "refuse, don't
# downgrade" principle). Loom has no opinion of its own on
# real-vs-simulated; before OA3 this hardcoded --simulated
# unconditionally, which is exactly the choice that belongs to lex-os and
# the host it's running on, not to loom.
fn lex_os_simulated_requested() -> [env] Bool {
  match env.get("LEX_OS_SIMULATED") {
    Some(_) => true,
    None => false,
  }
}

# When LEX_OS_ISOLATION is set, proc_cmd nodes route through `lex-os exec`
# instead of a bare proc.run, so the phase's manifests.lex grant actually
# gates whether the command may run at all (docs/design/lex-os-isolation.md).
# The command construction below is byte-for-byte what proc_step already
# builds — only the launcher changes, so unset this is a no-op: behavior is
# identical to proc_step. `policy_isolation` is the company's raw
# [policy.isolation] table (OA1) — "" for every non-company/no-override
# caller — resolved here through the SAME override machinery cast.lex's
# grant report already uses (manifest_json_for_kind_with_overrides), so a
# company's declared override now actually changes what gets mediated
# (OA1's own scope note: "wiring an override into what actually gets
# mediated is OA2").
fn lex_os_exec_step(def :: AgentDef, msg_json :: Str, policy_isolation :: Str) -> [proc, io, env] Str {
  let full_input := str.join([def.system_prompt, "\n\n", msg_json], "")
  match proc.run("bash", ["-c", "mktemp /tmp/loom-proc.XXXXXXXX"]) {
    Err(msg) => str.concat("PROC_ERROR: mktemp failed: ", msg),
    Ok(mk) => {
      let path := str.trim(mk.stdout)
      let __w := io.write(path, full_input)
      match proc.run("bash", ["-c", "mktemp /tmp/loom-manifest.XXXXXXXX"]) {
        Err(msg) => str.concat("PROC_ERROR: manifest mktemp failed: ", msg),
        Ok(mm) => {
          let manifest_path := str.trim(mm.stdout)
          let overrides := manifests.parse_isolation_overrides(policy_isolation)
          let __m := io.write(manifest_path, manifests.manifest_json_for_kind_with_overrides(def.kind, def.sprint_id, overrides))
          let cmd := str.join([def.proc_cmd, " < ", path], "")
          match proc.run("lex-os", lex_os_exec_args(lex_os_simulated_requested(), manifest_path, cmd)) {
            Err(msg) => str.concat("PROC_ERROR: lex-os exec spawn failed: ", msg),
            Ok(r) => parse_lex_os_exec_output(r.stdout),
          }
        },
      }
    },
  }
}

# Parse `lex-os --output json exec`'s acli envelope:
#   allowed:  {"ok":true,"data":{"exit_code":0,"stdout":"...","stderr":"...",...}}
#   denied:   {"ok":false,"error":{"code":"...","message":"..."}}
fn parse_lex_os_exec_output(stdout :: Str) -> Str {
  match jv.parse(stdout) {
    Err(_) => str.concat("PROC_ERROR: lex-os exec produced unparseable output: ", stdout),
    Ok(j) => match jv.get_field(j, "ok") {
      Some(JBool(false)) => match jv.get_field(j, "error") {
        Some(err) => match jv.get_field(err, "message") {
          Some(JStr(m)) => str.concat("PROC_ERROR: lex-os exec denied: ", m),
          _ => "PROC_ERROR: lex-os exec denied (no message)",
        },
        None => "PROC_ERROR: lex-os exec denied (no error field)",
      },
      _ => match jv.get_field(j, "data") {
        None => "PROC_ERROR: lex-os exec: success envelope has no data",
        Some(data) => extract_exec_data(data),
      },
    },
  }
}

fn extract_exec_data(data :: jv.Json) -> Str {
  let exit_ok := match jv.get_field(data, "exit_code") {
    Some(JInt(0)) => true,
    _ => false,
  }
  if exit_ok {
    match jv.get_field(data, "stdout") {
      Some(JStr(s)) => str.trim(s),
      _ => "",
    }
  } else {
    match jv.get_field(data, "stderr") {
      Some(JStr(s)) => str.join(["PROC_ERROR: exit non-zero. stderr: ", s], ""),
      _ => "PROC_ERROR: exit non-zero (no stderr captured)",
    }
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

# ── conversation memory across QA bounces ─────────────────────────────────────
# A build node that is bounced back from QA receives a structured "bounce
# envelope" instead of a flat string. We rebuild it into a proper multi-turn
# conversation so the model sees its OWN previous attempt (AssistantMsg) and the
# QA critique (UserMsg) and edits its code, rather than re-deriving from scratch.
# Non-build kinds (or non-envelope input) keep the single-UserMsg behaviour.
fn jstr_field(j :: jv.Json, key :: Str, default :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => default,
  }
}

# Pull the Nth section of a delimiter-split list, or "" if absent.
fn nth_or_empty(parts :: List[Str], i :: Int) -> Str {
  match list.head(parts) {
    None => "",
    Some(h) => if i == 0 {
      h
    } else {
      nth_or_empty(list.tail(parts), i - 1)
    },
  }
}

fn conv_from_msg(kind :: Str, msg_json :: Str) -> List[llm_msg.Message] {
  let is_bounce := if is_build_kind(kind) {
    str.starts_with(msg_json, "<<<LOOM_BOUNCE>>>")
  } else {
    false
  }
  if is_bounce {
    let body := str.slice(msg_json, 17, str.len(msg_json))
    let parts := str.split(body, "<<<LOOM_SEP>>>")
    let task := nth_or_empty(parts, 0)
    let prior := nth_or_empty(parts, 1)
    let feedback := nth_or_empty(parts, 2)
    let critique := str.join(["Your previous attempt above did NOT pass QA.", "", "Reason: ", feedback, "", "Fix YOUR code: keep what worked, change only what failed. Call lex_check and repair until ok='true', then output the corrected file."], "\n")
    [llm_msg.UserMsg(task), llm_msg.AssistantMsg(prior, []), llm_msg.UserMsg(critique)]
  } else {
    [llm_msg.UserMsg(msg_json)]
  }
}

# ── main step ─────────────────────────────────────────────────────────────────
# `cost_owner` scopes this call's real token usage (#94) for the cost ledger:
# pass a sprint_id for an in-sprint node call, or a company_id for a
# between-iteration call (e.g. the strategist) that has no sprint of its own.
# Empty string means "don't record" (e.g. proc_cmd/a2a_url paths never touch
# an LLM directly, so there is no usage to attribute).
fn step(db :: conn.ConnDb, def :: AgentDef, msg_json :: Str, cost_owner :: Str, policy_isolation :: Str) -> [io, time, sql, concurrent, net, random, fs_read, fs_write, llm, proc, env, approval, crypto] Str {
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
      let use_lex_os := match env.get("LEX_OS_ISOLATION") {
        Some(_) => true,
        None => false,
      }
      let out := if use_lex_os {
        lex_os_exec_step(def, msg_json, policy_isolation)
      } else {
        proc_step(def, msg_json)
      }
      let _t3 := trace.record(db, run_id, def.id, "proc_done", jv.stringify(JStr(out)))
      out
    } else {
      let state := mem.load_state(db, def.id)
      let entries := mem.recall_all(db, def.id)
      let sys := build_system_prompt(def, state, entries)
      let ops_path := ops_file(run_id)
      let overrides := manifests.parse_isolation_overrides(policy_isolation)
      let manifest_json := manifests.manifest_json_for_kind_with_overrides(def.kind, def.sprint_id, overrides)
      let granted_tools := list.filter(def.tools, fn (tl :: t.Tool) -> Bool {
        tool_grant.tool_allowed_under_manifest(tl.name, manifest_json)
      })
      let base_wrapped := list.map(granted_tools, fn (tl :: t.Tool) -> t.Tool {
        wrap_tool(ops_path, tl)
      })
      let company_id := match list.head(str.split(cost_owner, "/")) {
        Some(cid) => cid,
        None => cost_owner,
      }
      let manages_someone := not list.is_empty(list.filter(org.load_org(db, company_id), fn (edge :: org.OrgEdge) -> Bool {
        edge.parent == def.kind
      }))
      let all_tools := if manages_someone {
        list.concat(base_wrapped, [wrap_tool(ops_path, delegation.delegate_tool(delegation.delegations_file(run_id)))])
      } else {
        base_wrapped
      }
      let the_model := prov.make_model_ref(def.provider.name, def.model_name)
      let base_opts := llm_agent.default_options()
      let opts := { temperature: base_opts.temperature, top_p: base_opts.top_p, max_steps: Some(max_steps_for(def.kind)), max_tokens: base_opts.max_tokens }
      let llm_def := { name: def.id, goal: sys, model: the_model, provider: def.provider, tools: all_tools, options: opts, permission_spec: None }
      let conv := conv_from_msg(def.kind, msg_json)
      let __clear := if is_build_kind(def.kind) {
        clear_work_dir(def.kind, def.sprint_id)
      } else {
        ()
      }
      let _t2 := trace.record(db, run_id, def.id, "llm_start", "{}")
      let steps := iter.to_list(llm_agent.run_loop(llm_def, conv))
      let __usage := record_usage(db, run_id, cost_owner, steps)
      let __ops := flush_op_calls(db, run_id, def.id)
      let delegated := delegation.flush_delegations(db, company_id, def.kind, delegation.delegations_file(run_id))
      let __dp := if delegated > 0 {
        io.print(str.join(["[runner] ", def.id, " delegated ", int.to_str(delegated), " task(s) — queued as assignments"], ""))
      } else {
        ()
      }
      let __agui := agui_store.persist_agui_events(db, run_id, cost_owner, def.id, steps)
      let out0 := extract_answer(steps)
      let out := if is_build_kind(def.kind) {
        if has_fence(out0) {
          out0
        } else {
          let recovered := recover_build_artifact(def.kind, def.sprint_id)
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

