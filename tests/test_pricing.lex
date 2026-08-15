# test_pricing.lex — #94: real token pricing and the node-charge decision.
#
# All offline:
#   1. RATES — per-model split pricing; unknown model falls back to the
#      historical flat rate; local models price at 0.
#   2. PRICED USAGE — usage_cost_cents prices every llm_usage event under an
#      owner (and, when asked, its node-scoped "#" children), per model, and
#      returns the event count so callers can tell "nothing reported" from
#      "reported and genuinely free".
#   3. CHARGE BASIS — new usage events charge the priced delta (0 for free
#      models, honestly); no new events fall back to the artifact estimate.
#   4. LEDGER — estimate_iteration_cost_cents prices node-scoped children
#      and does NOT re-inflate a reported-but-free run with the estimate.

import "std.list" as list

import "std.str" as str

import "std.io" as io

import "std.int" as int

import "std.sql" as sql

import "std.time" as time

import "std.crypto" as crypto

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

import "../src/migrate" as migrate

import "../src/pricing" as pricing

import "../src/budget" as budget

import "../src/company" as company

fn check(name :: Str, cond :: Bool) -> Result[Unit, Str] {
  if cond {
    Ok(())
  } else {
    Err(name)
  }
}

fn open_db() -> [sql, fs_write, random, crypto] Result[conn.ConnDb, Str] {
  let path := str.join(["/tmp/loom-pricing-test-", crypto.random_str_hex(8), ".db"], "")
  match conn.open(path) {
    Err(_) => Err("open test db"),
    Ok(db) => match migrate.run(db.handle) {
      Err(e) => Err(e),
      Ok(_) => Ok(db),
    },
  }
}

fn seed_usage(db :: conn.ConnDb, owner :: Str, model :: Str, p :: Int, c :: Int, t :: Int) -> [sql, fs_write, time] Unit {
  let json := str.join(["{\"model\":\"", model, "\",\"prompt_tokens\":", int.to_str(p), ",\"completion_tokens\":", int.to_str(c), ",\"total_tokens\":", int.to_str(t), "}"], "")
  let q := ormq.for_dialect({ sql: "INSERT INTO traces (run_id, agent_id, event_kind, data_json, ts) VALUES (?, ?, 'llm_usage', ?, ?)", params: [PStr("r"), PStr(owner), PStr(json), PStr(time.now_str())] }, db.dialect)
  let __r := sql.exec(db.handle, q.sql, q.params)
  ()
}

# ── 1. Rates ─────────────────────────────────────────────────────────────────
fn test_rates() -> Result[Unit, Str] {
  match check("haiku split pricing", pricing.price_cents("claude-haiku-4-5-20251001", 10000, 2000, 12000) == 2) {
    Err(e) => Err(e),
    Ok(_) => match check("sonnet costs more per token", pricing.price_cents("claude-sonnet-5", 10000, 2000, 12000) == 6) {
      Err(e) => Err(e),
      Ok(_) => match check("local model is free", pricing.price_cents("qwen3-coder:30b", 100000, 20000, 120000) == 0) {
        Err(e) => Err(e),
        Ok(_) => match check("unknown model falls back to the flat blended rate", pricing.price_cents("mystery-model", 0, 0, 10000) == 300) {
          Err(e) => Err(e),
          Ok(_) => check("pre-model events (empty model) price at the flat rate", pricing.price_cents("", 0, 0, 1000) == 30),
        },
      },
    },
  }
}

# ── 2. Priced usage with node-scoped children ────────────────────────────────
fn test_usage_cost() -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let owner := str.concat("acme/iter-1-", crypto.random_str_hex(6))
      let __u1 := seed_usage(db, owner, "claude-haiku-4-5", 10000, 2000, 12000)
      let __u2 := seed_usage(db, str.concat(owner, "#build"), "claude-sonnet-5", 10000, 2000, 12000)
      let __u3 := seed_usage(db, str.concat(owner, "#qa"), "qwen3-coder:30b", 50000, 5000, 55000)
      match pricing.usage_cost_cents(db, owner, true) {
        (cents, n) => match check("children included: 3 events priced per model (2+6+0)", cents == 8 and n == 3) {
          Err(e) => Err(e),
          Ok(_) => match pricing.usage_cost_cents(db, owner, false) {
            (cents2, n2) => match check("exact owner only: 1 event", cents2 == 2 and n2 == 1) {
              Err(e) => Err(e),
              Ok(_) => match pricing.usage_cost_cents(db, str.concat(owner, "#build"), false) {
                (cents3, n3) => check("a node owner reads only its own usage", cents3 == 6 and n3 == 1),
              },
            },
          },
        },
      }
    },
  }
}

# ── 3. The charge basis ──────────────────────────────────────────────────────
fn test_charge_basis() -> Result[Unit, Str] {
  match check("new usage charges the priced delta", budget.charge_basis((3, 1), (10, 3), 4000) == 7) {
    Err(e) => Err(e),
    Ok(_) => match check("reported-but-free charges 0, never the estimate", budget.charge_basis((5, 1), (5, 2), 4000) == 0) {
      Err(e) => Err(e),
      Ok(_) => check("no new usage falls back to the artifact estimate", budget.charge_basis((5, 1), (5, 1), 4000) == 30),
    },
  }
}

# ── 4. The iteration ledger ──────────────────────────────────────────────────
fn test_ledger_includes_children_and_respects_free() -> [io, sql, fs_read, fs_write, time, random, crypto] Result[Unit, Str] {
  match open_db() {
    Err(e) => Err(e),
    Ok(db) => {
      let sprint := str.concat("acme/iter-", crypto.random_str_hex(6))
      let __u1 := seed_usage(db, str.concat(sprint, "#build"), "claude-haiku-4-5", 10000, 2000, 12000)
      let __u2 := seed_usage(db, sprint, "claude-sonnet-5", 10000, 2000, 12000)
      match check("iteration cost sums sprint + node-scoped usage, priced", company.estimate_iteration_cost_cents(db, sprint) == 8) {
        Err(e) => Err(e),
        Ok(_) => {
          let free_sprint := str.concat("acme/free-", crypto.random_str_hex(6))
          let __u3 := seed_usage(db, str.concat(free_sprint, "#build"), "qwen3-coder:30b", 90000, 9000, 99000)
          check("a reported-but-free iteration costs 0, not the estimate", company.estimate_iteration_cost_cents(db, free_sprint) == 0)
        },
      }
    },
  }
}

fn suite() -> [io, sql, fs_read, fs_write, time, random, crypto] List[Result[Unit, Str]] {
  [test_rates(), test_usage_cost(), test_charge_basis(), test_ledger_includes_children_and_respects_free()]
}

fn run_all() -> [io, sql, fs_read, fs_write, time, random, crypto] Unit {
  let results := suite()
  let __dbg := list.map(results, fn (r :: Result[Unit, Str]) -> [io] Unit {
    match r {
      Ok(_) => (),
      Err(e) => io.print(str.concat("FAIL: ", e)),
    }
  })
  let failures := list.fold(results, 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
  if failures == 0 {
    ()
  } else {
    let __force_fail := 1 / 0
    ()
  }
}

