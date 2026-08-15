# pricing.lex — real token pricing for the cost ledger (#94).
#
# The ledger's v0 charged a blended 30¢/1k-token guess over artifact
# characters. runner.step has recorded REAL provider token counts
# (`llm_usage` trace events) since #94's first slice landed; this module
# prices those counts per model, with the input/output split real providers
# bill by. Three deliberate properties:
#
#   1. INTEGER MONEY. Rates are MILLI-cents per 1k tokens so cheap models
#      (e.g. $1/M input = 0.1¢/1k) survive integer arithmetic; a priced
#      event rounds to the nearest cent only at the end.
#   2. UNKNOWN MODEL → the old blended flat rate on total tokens, never a
#      guessed split — the fallback is the exact pre-#94 behavior, so an
#      unpriced model degrades to the historical estimate rather than to
#      silence or to invented precision.
#   3. LOCAL MODELS ARE FREE. Ollama-served models (qwen3-coder, gemma4,
#      devstral) cost no API dollars; pricing them at 0 keeps the ledger
#      honest — electricity is not API spend, and pretending otherwise
#      would let a budget envelope "exhaust" on money nobody spent.
#
# Rates drift. This table is the one place to update them; entries match by
# model-name prefix, first match wins.

import "std.str" as str

import "std.list" as list

import "std.sql" as sql

import "lex-schema/json_value" as jv

import "lex-orm/src/connection" as conn

import "lex-orm/src/query" as ormq

# in/out are MILLI-cents per 1k tokens (1¢ = 1000 milli-cents).
type Rate = { prefix :: Str, in_mc_per_1k :: Int, out_mc_per_1k :: Int }

fn rate_table() -> List[Rate] {
  [{ prefix: "claude-haiku", in_mc_per_1k: 100, out_mc_per_1k: 500 }, { prefix: "claude-sonnet", in_mc_per_1k: 300, out_mc_per_1k: 1500 }, { prefix: "claude-opus", in_mc_per_1k: 1500, out_mc_per_1k: 7500 }, { prefix: "qwen3-coder", in_mc_per_1k: 0, out_mc_per_1k: 0 }, { prefix: "gemma4", in_mc_per_1k: 0, out_mc_per_1k: 0 }, { prefix: "devstral", in_mc_per_1k: 0, out_mc_per_1k: 0 }, { prefix: "proc:", in_mc_per_1k: 0, out_mc_per_1k: 0 }]
}

# The pre-#94 blended guess, kept as the unknown-model fallback: 30¢ per 1k
# total tokens. Same constant company.lex's char-estimate path uses.
fn flat_cents_per_1k() -> Int {
  30
}

fn rate_for(model :: Str) -> Option[Rate] {
  list.fold(rate_table(), None, fn (acc :: Option[Rate], r :: Rate) -> Option[Rate] {
    match acc {
      Some(_) => acc,
      None => if str.starts_with(model, r.prefix) {
        Some(r)
      } else {
        None
      },
    }
  })
}

# Price one usage reading in integer cents. Known model: split input/output
# rates, rounded to the nearest cent. Unknown model (or empty — an old
# pre-model usage event): flat blended rate on total tokens, exactly the
# historical estimate.
fn price_cents(model :: Str, prompt_tokens :: Int, completion_tokens :: Int, total_tokens :: Int) -> Int
  examples {
    price_cents("claude-haiku-4-5-20251001", 10000, 2000, 12000) => 2,
    price_cents("claude-sonnet-5", 10000, 2000, 12000) => 6,
    price_cents("qwen3-coder:30b", 100000, 20000, 120000) => 0,
    price_cents("mystery-model", 0, 0, 10000) => 300,
    price_cents("", 0, 0, 1000) => 30
  }
{
  match rate_for(model) {
    Some(r) => {
      let mc := prompt_tokens * r.in_mc_per_1k / 1000 + completion_tokens * r.out_mc_per_1k / 1000
      (mc + 500) / 1000
    },
    None => total_tokens * flat_cents_per_1k() / 1000,
  }
}

# ── Priced usage from the trail ──────────────────────────────────────────────
type UsageEvRow = { data_json :: Str }

fn json_int(j :: jv.Json, key :: Str) -> Int {
  match jv.get_field(j, key) {
    Some(JInt(v)) => v,
    _ => 0,
  }
}

fn json_str(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# Price every `llm_usage` event recorded under `owner_id` — and, when
# `include_children` is true, under its node-scoped children
# ("<owner>#<node>") — returning (cents, event_count). The count lets a
# caller distinguish "no provider reported usage" (fall back to the char
# estimate) from "usage reported and it genuinely cost ~0" (a local model —
# do NOT re-invent spend with an estimate).
fn usage_cost_cents(db :: conn.ConnDb, owner_id :: Str, include_children :: Bool) -> [sql, fs_read] (Int, Int) {
  let q := if include_children {
    ormq.for_dialect({ sql: "SELECT data_json FROM traces WHERE (agent_id = ? OR agent_id LIKE ?) AND event_kind='llm_usage'", params: [PStr(owner_id), PStr(str.concat(owner_id, "#%"))] }, db.dialect)
  } else {
    ormq.for_dialect({ sql: "SELECT data_json FROM traces WHERE agent_id = ? AND event_kind='llm_usage'", params: [PStr(owner_id)] }, db.dialect)
  }
  let rows :: Result[List[UsageEvRow], SqlError] := sql.query(db.handle, q.sql, q.params)
  match rows {
    Err(_) => (0, 0),
    Ok(rs) => list.fold(rs, (0, 0), fn (acc :: (Int, Int), r :: UsageEvRow) -> (Int, Int) {
      match acc {
        (cents, n) => match jv.parse(r.data_json) {
          Err(_) => (cents, n),
          Ok(j) => (cents + price_cents(json_str(j, "model"), json_int(j, "prompt_tokens"), json_int(j, "completion_tokens"), json_int(j, "total_tokens")), n + 1),
        },
      }
    }),
  }
}

