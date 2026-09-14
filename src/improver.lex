# improver.lex — post-retro agent improvement cycle.
#
# After the Scribe produces a Digest, the Improver reads each
# tightened_spec entry, loads the current best agent for that role,
# calls an LLM to generate an improved system prompt, and inserts
# a new versioned agent into agent_pool.
#
# SAFE INHERITANCE. A successor inherits its parent's standing and nothing
# more: it starts at exactly the parent's attestation_count, not above it, and
# it records the parent it came from.
#
# It used to start at parent + 2. load_best_agent picks the highest count, so
# a brand-new, unproven prompt outranked the proven agent it replaced the
# moment it was written -- and this module's own comment claimed the opposite
# ("new agents start at attestation_count=0"). formcolocal shipped
# build-improved-formcolocal/iter-2-next that way, minted from a retro with no
# lessons recorded at all, and it is the agent that then ran 549 steps and
# wrote forty scratch files. Its parent build-v1 sat at -6 while it sat at -2,
# not because it was better but because it had had fewer chances to fail.
#
# Starting level, plus a tie broken toward the newer agent, means the successor
# IS tried -- and the first bounce drops it below its parent, which restores
# the parent. That is the rollback: no separate mechanism, just no unearned
# head start.
#
# ID convention: <role>-improved-<sprint_id>
# e.g. build-improved-sprint-1

import "std.str" as str

import "std.int" as int

import "std.list" as list

import "std.sql" as sql

import "lex-orm/src/connection" as conn

import "std.io" as io

import "std.time" as time

import "./agent/runner" as runner

import "lex-llm/src/providers" as providers

import "./digest" as dg

import "./roles" as roles

import "./role_tools" as rt

import "lex-orm/src/query" as ormq

# ── Types ─────────────────────────────────────────────────────────────────────
type ImprovementResult = { improved_roles :: List[Str], new_agent_ids :: List[Str] }

type AgentRow = { id :: Str, system_prompt :: Str, domain_tags_json :: Str, model_name :: Str, attestation_count :: Int }

# ── Helpers ───────────────────────────────────────────────────────────────────
# What a successor is worth before it has done anything: exactly what its
# parent was worth. Named, so that raising it again is an edit to a rule with
# a test on it rather than a `+ 2` in the middle of a call.
fn inherited_standing(parent_count :: Int) -> Int {
  parent_count
}

# An "improvement" identical to what it replaces is a new id, a new row, and a
# reset of nothing -- pure churn in the lineage. formcolocal minted four such
# successors from a retro that recorded no lessons at all.
fn says_nothing_new(current_prompt :: Str, improved :: Str) -> Bool {
  str.trim(current_prompt) == str.trim(improved)
}

fn parent_label(parent_id :: Str) -> Str {
  if str.is_empty(parent_id) {
    "no parent"
  } else {
    parent_id
  }
}

fn new_agent_id(role :: Str, sprint_id :: Str) -> Str {
  str.join([role, "-improved-", sprint_id], "")
}

fn empty_result() -> ImprovementResult {
  { improved_roles: [], new_agent_ids: [] }
}

# ── DB helpers ────────────────────────────────────────────────────────────────
# ── Clade metaproductivity (HGM) ─────────────────────────────────────────────
#
# WHICH AGENT DOES THE WORK and WHICH AGENT IS WORTH FORKING FROM are different
# questions, and loom was answering both with the same number.
#
# The improver takes the best-performing agent for a role and writes a
# successor from its prompt. arXiv 2510.21614 (Huxley-Godel Machine, ICLR 2026)
# names why that is the wrong selector: the Metaproductivity-Performance
# Mismatch -- an agent with the best immediate score is often NOT the one whose
# descendants go on to perform, so a search that expands the current leader
# keeps forking from a dead end. HGM scores a candidate by the aggregated
# performance of its whole lineage (clade-metaproductivity) and expands that
# instead, and reaches human-level SWE-bench with fewer CPU-hours than DGM,
# which expanded on immediate score.
#
# So: execution still picks the best PERFORMER (load_best_agent -- the agent
# that does a node should be the one that does it well). The improver now
# picks the best SEED, which is the agent whose clade -- itself plus every
# descendant -- has the highest total standing.
#
# The lineage edge this walks is agent_pool.parent_id, added in #487. Pools are
# small (single digits per role), so the walk happens in Lex rather than a
# recursive CTE: pure, dialect-free, and testable without a database.
type PoolAgent = { id :: Str, parent_id :: Str, attestation_count :: Int }

fn own_count(agents :: List[PoolAgent], id :: Str) -> Int {
  list.fold(agents, 0, fn (acc :: Int, a :: PoolAgent) -> Int {
    if a.id == id {
      a.attestation_count
    } else {
      acc
    }
  })
}

fn children_of(agents :: List[PoolAgent], id :: Str) -> List[Str] {
  list.map(list.filter(agents, fn (a :: PoolAgent) -> Bool {
    if str.is_empty(a.parent_id) {
      false
    } else {
      if a.parent_id == id {
        a.id != id
      } else {
        false
      }
    }
  }), fn (a :: PoolAgent) -> Str {
    a.id
  })
}

# An agent's own standing plus every descendant's. `depth` bounds the walk at
# the size of the pool, so a parent_id cycle costs a bounded walk rather than
# the company.
fn clade_score(agents :: List[PoolAgent], id :: Str, depth :: Int) -> Int {
  if depth <= 0 {
    0
  } else {
    list.fold(children_of(agents, id), own_count(agents, id), fn (acc :: Int, kid :: Str) -> Int {
      acc + clade_score(agents, kid, depth - 1)
    })
  }
}

# The agent worth forking from. Ties go to whichever the caller listed first,
# which is the SQL order (own standing, then newest) -- so a pool with no
# lineage at all behaves exactly as it did before.
fn best_seed(agents :: List[PoolAgent]) -> Option[Str] {
  let depth := list.len(agents) + 1
  match list.head(agents) {
    None => None,
    Some(first) => Some(list.fold(agents, first.id, fn (best :: Str, a :: PoolAgent) -> Str {
      if clade_score(agents, a.id, depth) > clade_score(agents, best, depth) {
        a.id
      } else {
        best
      }
    })),
  }
}

fn load_pool(db :: conn.ConnDb, role :: Str) -> [sql, fs_read] List[PoolAgent] {
  let qd := ormq.for_dialect({ sql: "SELECT id, parent_id, attestation_count FROM agent_pool WHERE role=? ORDER BY attestation_count DESC, created_at DESC", params: [PStr(role)] }, db.dialect)
  let rows :: Result[List[PoolAgent], SqlError] := sql.query(db.handle, qd.sql, qd.params)
  match rows {
    Err(_) => [],
    Ok(rs) => rs,
  }
}

fn load_agent_by_id(db :: conn.ConnDb, id :: Str) -> [sql, fs_read] Option[AgentRow] {
  let qd := ormq.for_dialect({ sql: "SELECT id, system_prompt, domain_tags_json, model_name, attestation_count FROM agent_pool WHERE id=? LIMIT 1", params: [PStr(id)] }, db.dialect)
  let rows :: Result[List[AgentRow], SqlError] := sql.query(db.handle, qd.sql, qd.params)
  match rows {
    Err(_) => None,
    Ok(rs) => list.head(rs),
  }
}

# The agent the improver forks from: the best clade, falling back to the best
# performer when a role has no pool at all.
fn load_seed_agent(db :: conn.ConnDb, role :: Str) -> [sql, fs_read] Option[AgentRow] {
  match best_seed(load_pool(db, role)) {
    None => load_best_agent(db, role),
    Some(id) => match load_agent_by_id(db, id) {
      None => load_best_agent(db, role),
      Some(a) => Some(a),
    },
  }
}

fn load_best_agent(db :: conn.ConnDb, role :: Str) -> [sql, fs_read] Option[AgentRow] {
  let qd := ormq.for_dialect({ sql: "SELECT id, system_prompt, domain_tags_json, model_name, attestation_count FROM agent_pool WHERE role=? ORDER BY attestation_count DESC, created_at DESC LIMIT 1", params: [PStr(role)] }, db.dialect)
  let rows :: Result[List[AgentRow], SqlError] := sql.query(db.handle, qd.sql, qd.params)
  match rows {
    Err(_) => None,
    Ok(rs) => list.head(rs),
  }
}

fn save_improved_agent(db :: conn.ConnDb, new_id :: Str, role :: Str, prompt :: Str, tags_json :: Str, model_name :: Str, starting_count :: Int, parent_id :: Str) -> [sql, fs_write, time] Unit {
  let now := time.now_str()
  let qd := ormq.for_dialect({ sql: "INSERT OR REPLACE INTO agent_pool (id, role, system_prompt, model_name, domain_tags_json, attestation_count, created_at, parent_id) VALUES (?,?,?,?,?,?,?,?)", params: [PStr(new_id), PStr(role), PStr(prompt), PStr(model_name), PStr(tags_json), PInt(starting_count), PStr(now), PStr(parent_id)] }, db.dialect)
  let __r := sql.exec(db.handle, qd.sql, qd.params)
  ()
}

# ── Prompt engineering ────────────────────────────────────────────────────────
fn improver_system_prompt() -> Str {
  "You are an expert LLM agent prompt engineer. You rewrite agent system prompts to be more precise and effective based on sprint feedback. Output only the improved system prompt text — no labels, no commentary, no markdown fences.\n\nNEVER add a precondition that makes the role refuse, stop, or fail on the presence or absence of a file, marker, or artifact. The role's gate decides pass and fail; a prompt must not install its own gate, and must not name files that no role in the sprint produces."
}

# Found live (pdfx2 company run): the improver rewrote the `qa` role's
# system prompt to demand things qa's real tools (lex_check, lex_run only)
# cannot do -- "start the binary and confirm it accepts connections",
# "persist the actual smoke-test result to artifacts/smoke/...". qa has no
# way to start a server or make an HTTP request; that's the `launch` role's
# job. The improver had zero visibility into what tools the role it was
# rewriting actually has, so nothing stopped it from inventing requirements
# beyond that role's real capabilities -- the agent then failed forever
# trying to satisfy an unsatisfiable prompt, and every subsequent
# "improvement" made the prompt more elaborate and further from reality.
fn tool_capability_note(role :: Str) -> Str {
  let tools := rt.tools_for(role)
  if list.is_empty(tools) {
    "This role has NO tools at all -- it can only reason over the text it's given. Do not instruct it to run commands, call any tool, start a server, or verify anything beyond its own reasoning over the input text."
  } else {
    str.join(["This role's ONLY available tools are: ", str.join(tools, ", "), ". Do not instruct it to do anything beyond what these specific tools can do -- for example, do not ask it to start a server, make an HTTP request, persist files outside what these tools write, or verify runtime behavior no available tool can produce. If the lesson learned seems to call for a capability outside this list, the fix belongs in a DIFFERENT role (e.g. `launch` starts servers, `run_code`/`py_qa` execute Python) -- do not paper over a missing capability by demanding this role pretend to have it."], "")
  }
}

# An improved prompt may not install its own gate on an artifact it invented.
#
# Company tzc10: the improver rewrote py_qa's prompt to begin with a
# PRECONDITION that globs for .launch_attested, launch_ok.json and
# *.launch_status and, finding none, emits FAIL "refusing to QA a dead binary"
# before running a single test. No role produces those files -- the base prompt
# mentions none of them. Launch had returned HTTP 200 and been accepted; QA then
# refused on a marker it had made up, and the sprint failed. That is #113 again
# (the improver demanding what the role cannot have), for files instead of
# tools, and the tool guard could not see it.
#
# The detector needs BOTH halves: a refusal instruction, and a filename-like
# token that the base prompt never mentioned. Either alone is ordinary -- an
# improvement may cite main.py as an example, or say "do not proceed" about a
# gate that already exists.
fn installs_a_gate_on_an_invented_artifact(base :: Str, improved :: Str) -> Option[Str] {
  let refusal_words := ["PRECONDITION", "Refusing to", "refuse to", "FAIL immediately", "Do NOT proceed", "before any other test", "stop and emit"]
  let refuses := list.fold(refusal_words, false, fn (acc :: Bool, w :: Str) -> Bool {
    acc or str.contains(improved, w)
  })
  if not refuses {
    None
  } else {
    let invented := list.filter(filename_like_tokens(improved), fn (t :: Str) -> Bool {
      not str.contains(base, t)
    })
    if list.is_empty(invented) {
      None
    } else {
      Some(str.join(["the improved prompt tells the role to refuse or fail based on files no role produces: ", str.join(invented, ", ")], ""))
    }
  }
}

# Tokens shaped like a file: a dotfile (.launch_attested) or name.ext where ext
# is 2-6 lowercase letters. URLs and sentence-ending dots are excluded.
fn filename_like_tokens(text :: Str) -> List[Str] {
  let cleaned := str.replace(str.replace(str.replace(str.replace(str.replace(str.replace(text, "\"", " "), "'", " "), "(", " "), ")", " "), ",", " "), "\n", " ")
  let raw := list.filter(str.split(cleaned, " "), fn (t :: Str) -> Bool {
    not str.is_empty(t)
  })
  list.fold(raw, [], fn (acc :: List[Str], t :: Str) -> List[Str] {
    let tok := str.trim(t)
    if str.contains(tok, "://") or str.contains(tok, "..") or has(acc, tok) {
      acc
    } else {
      if looks_like_a_file(tok) {
        list.concat(acc, [tok])
      } else {
        acc
      }
    }
  })
}

fn has(xs :: List[Str], x :: Str) -> Bool {
  list.fold(xs, false, fn (a :: Bool, y :: Str) -> Bool {
    a or y == x
  })
}

fn looks_like_a_file(tok :: Str) -> Bool {
  if str.starts_with(tok, ".") {
    str.len(tok) > 3 and is_ident(str.slice(tok, 1, str.len(tok)))
  } else {
    let parts := str.split(tok, ".")
    if list.len(parts) < 2 {
      false
    } else {
      let ext := list.fold(parts, "", fn (__lex_discard_1 :: Str, part :: Str) -> Str {
        part
      })
      let stem := match list.head(parts) {
        Some(h) => h,
        None => "",
      }
      str.len(ext) >= 2 and str.len(ext) <= 6 and is_lower_alpha(ext) and not str.is_empty(stem) and is_ident(str.replace(stem, "*", "x"))
    }
  }
}

fn is_lower_alpha(sx :: Str) -> Bool {
  str.len(sx) > 0 and every_char_in(sx, "abcdefghijklmnopqrstuvwxyz", 0)
}

fn is_ident(sx :: Str) -> Bool {
  str.len(sx) > 0 and every_char_in(sx, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-", 0)
}

fn every_char_in(sx :: Str, alphabet :: Str, i :: Int) -> Bool {
  if i >= str.len(sx) {
    true
  } else {
    str.contains(alphabet, str.slice(sx, i, i + 1)) and every_char_in(sx, alphabet, i + 1)
  }
}

fn improvement_prompt(role :: Str, current_prompt :: Str, lesson :: Str, specs :: List[dg.TightenedSpec]) -> Str {
  let spec_lines := list.fold(specs, "", fn (acc :: Str, ts :: dg.TightenedSpec) -> Str {
    str.join([acc, "  - Must satisfy: ", ts.spec_src, " (reason: ", ts.reason, ")\n"], "")
  })
  str.join(["Improve the system prompt below for the '", role, "' agent role.\n\n", "CURRENT SYSTEM PROMPT:\n", current_prompt, "\n\n", "WHAT LAST SPRINT TAUGHT US:\n", lesson, "\n\n", "TIGHTENED SPECS this agent must now reliably satisfy:\n", spec_lines, "\n", tool_capability_note(role), "\n\nWrite an improved system prompt that:\n", "1. Directly addresses the lesson learned, WITHOUT exceeding this role's real tool capabilities\n", "2. Will reliably produce output satisfying all specs above, using only the tools this role actually has\n", "3. Retains what worked in the original\n\n", "Output ONLY the new prompt text — nothing else."], "")
}

# ── Role deduplication ────────────────────────────────────────────────────────
fn unique_roles(specs :: List[dg.TightenedSpec]) -> List[Str] {
  list.fold(specs, [], fn (acc :: List[Str], ts :: dg.TightenedSpec) -> List[Str] {
    if list.fold(acc, false, fn (found :: Bool, r :: Str) -> Bool {
      if found {
        true
      } else {
        r == ts.node_role
      }
    }) {
      acc
    } else {
      list.concat(acc, [ts.node_role])
    }
  })
}

fn specs_for_role(all_specs :: List[dg.TightenedSpec], role :: Str) -> List[dg.TightenedSpec] {
  list.fold(all_specs, [], fn (acc :: List[dg.TightenedSpec], ts :: dg.TightenedSpec) -> List[dg.TightenedSpec] {
    if ts.node_role == role {
      list.concat(acc, [ts])
    } else {
      acc
    }
  })
}

# ── Core improvement ──────────────────────────────────────────────────────────
fn improve_role(db :: conn.ConnDb, sprint_id :: Str, role :: Str, specs :: List[dg.TightenedSpec], lesson :: Str, model :: Str) -> [env, io, time, crypto, sql, fs_read, fs_write, net, concurrent, llm, proc, random, approval] Option[Str] {
  let current_opt := load_seed_agent(db, role)
  let __seed := match current_opt {
    None => (),
    Some(seed) => match load_best_agent(db, role) {
      None => (),
      Some(top) => if top.id == seed.id {
        ()
      } else {
        io.print(str.join(["[loom/improver] forking role=", role, " from ", seed.id, " (best clade) rather than ", top.id, " (best score)"], ""))
      },
    },
  }
  let current_prompt := match current_opt {
    Some(a) => a.system_prompt,
    None => match roles.for_role(role, model, "", "") {
      Some(def) => def.system_prompt,
      None => str.join(["You are the ", role, " agent. Complete your assigned task carefully and accurately."], ""),
    },
  }
  let tags_json := match current_opt {
    Some(a) => a.domain_tags_json,
    None => str.join(["[\"", role, "\"]"], ""),
  }
  let model_name := match current_opt {
    Some(a) => a.model_name,
    None => "",
  }
  let parent_count := match current_opt {
    Some(a) => a.attestation_count,
    None => 0,
  }
  let parent_id := match current_opt {
    Some(a) => a.id,
    None => "",
  }
  let p := roles.make_provider()
  let improver_def := { id: "loom-improver", kind: "improver", system_prompt: improver_system_prompt(), model_name: model, provider: p, tools: [], proc_cmd: "", a2a_url: "", sprint_id: "" }
  let prompt := improvement_prompt(role, current_prompt, lesson, specs)
  let __log := io.print(str.join(["[loom/improver] improving role=", role, " sprint=", sprint_id], ""))
  let improved_prompt := runner.step(db, improver_def, prompt, sprint_id, "")
  if str.is_empty(improved_prompt) {
    let __log2 := io.print(str.join(["[loom/improver] empty output for role=", role, " — skipping"], ""))
    None
  } else {
    if says_nothing_new(current_prompt, improved_prompt) {
      let __same := io.print(str.join(["[loom/improver] improvement for role=", role, " is its parent's prompt — not minting a successor"], ""))
      None
    } else {
      match installs_a_gate_on_an_invented_artifact(current_prompt, improved_prompt) {
        Some(why) => {
          let __rej := io.print(str.join(["[loom/improver] REJECTED improvement for role=", role, ": ", why], ""))
          None
        },
        None => {
          let new_id := new_agent_id(role, sprint_id)
          let __save := save_improved_agent(db, new_id, role, improved_prompt, tags_json, model_name, inherited_standing(parent_count), parent_id)
          let __log3 := io.print(str.join(["[loom/improver] saved agent ", new_id, " (inherits ", parent_label(parent_id), " at ", int.to_str(parent_count), ")"], ""))
          Some(new_id)
        },
      }
    }
  }
}

# ── Public API ────────────────────────────────────────────────────────────────
fn run_improvement(db :: conn.ConnDb, sprint_id :: Str, lesson :: Str, model :: Str) -> [env, io, time, crypto, sql, fs_read, fs_write, net, concurrent, llm, proc, random, approval] ImprovementResult {
  let specs := dg.load_tightened_specs(db, sprint_id)
  if list.is_empty(specs) {
    let __log := io.print("[loom/improver] no tightened specs — nothing to improve")
    empty_result()
  } else {
    let roles_to_improve := unique_roles(specs)
    let __log := io.print(str.join(["[loom/improver] improving ", int.to_str(list.len(roles_to_improve)), " role(s): ", str.join(roles_to_improve, ", ")], ""))
    let results := list.map(roles_to_improve, fn (role :: Str) -> [env, io, time, crypto, sql, fs_read, fs_write, net, concurrent, llm, proc, random, approval] Option[Str] {
      improve_role(db, sprint_id, role, specs_for_role(specs, role), lesson, model)
    })
    let new_ids := list.fold(results, [], fn (acc :: List[Str], opt :: Option[Str]) -> List[Str] {
      match opt {
        None => acc,
        Some(id) => list.concat(acc, [id]),
      }
    })
    { improved_roles: roles_to_improve, new_agent_ids: new_ids }
  }
}

