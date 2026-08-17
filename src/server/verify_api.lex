# server/verify_api.lex — the hosted verifier (#68, Phase 3).
#
# "Someone outside the project independently verifies a result they did
# not produce" needs a surface they can hand a run record TO — not just a
# local binary. This service accepts a company DB (raw base64 body), runs
# the same four-layer verifier `verify_sprint_cmd` runs locally, and
# returns the recomputed verdicts. The uploaded record is judged
# SELF-CONTAINED: artifacts must re-derive from the bytes inside the
# upload, never from anything cached on this host — which is why the
# service refuses to start unless LEX_STORE_ROOT is explicitly set (point
# it at an empty, dedicated directory; a shared store would let a
# tampered upload borrow canonical bytes it did not carry).
#
# Refuse, don't downgrade:
#   - VERIFY_API_TOKEN unset → refuse to serve (mirrors cx_a2a/#193).
#   - LEX_STORE_ROOT unset  → refuse to serve (self-contained judging).
#   - upload larger than VERIFY_MAX_BYTES (default 10 MB decoded) → 413.
#   - grounded gate re-runs are OFF by default and reported as skipped:
#     re-running `spec sh`/`spec compiles` executes build commands FROM
#     THE UPLOAD — remote code execution by design. A host that wants the
#     grounded layer sets VERIFY_RERUN_GROUNDED=1 and runs this service
#     inside a sandbox it trusts (lex-os). Integrity, authority and
#     operations always run; they only read the record.
#
# POST /verify?sprint_id=<id>   Authorization: Bearer <VERIFY_API_TOKEN>
#                body: the base64 of the .db, raw (NOT wrapped in JSON —
#                lex-schema's JSON parser is O(n²) and a record-sized
#                payload would blow the request handler's step budget)
#             →  {"sprint_id":..., "verified":bool, "integrity":{...},
#                 "grounded":{...}|{"skipped":true,...},
#                 "authority":{...}, "operations":{...}}
# GET  /healthz  open — liveness only, no record access.

import "std.str" as str

import "std.int" as int

import "std.env" as env

import "std.io" as io

import "std.list" as list

import "std.net" as net

import "std.fs" as fs

import "std.map" as map

import "std.crypto" as crypto

import "std.bytes" as bytes

import "std.process" as process

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-web/body" as wbody

# Decoded-size gate, pure so the bound is testable: 0 or negative caps
# make no sense and refuse everything (fail closed on misconfiguration).
fn size_ok(decoded_len :: Int, cap :: Int) -> Bool
  examples {
    size_ok(1000, 10485760) => true,
    size_ok(10485761, 10485760) => false,
    size_ok(1, 0) => false
  }
{
  if cap <= 0 {
    false
  } else {
    decoded_len <= cap
  }
}

fn env_or(key :: Str, default :: Str) -> [env] Str {
  match env.get(key) {
    Some(v) => v,
    None => default,
  }
}

fn error_json(status :: Int, reason :: Str) -> resp.Response {
  { status: status, body: str.join(["{\"error\":\"", reason, "\"}"], ""), headers: map.from_list([("content-type", "application/json")]) }
}

# Land the uploaded bytes in a private temp file. There is no bytes→file
# builtin, so the bytes go through `cat`'s stdin — never through argv
# (argv would corrupt binary and caps out), never through a Str (SQLite
# bytes are not UTF-8).
fn write_temp_db(db_bytes :: Bytes) -> [proc, random, crypto] Result[Str, Str] {
  let tmp := str.join(["/tmp/loom-verify-", crypto.random_str_hex(12), ".db"], "")
  match process.spawn("sh", ["-c", str.join(["cat > '", tmp, "'"], "")], { cwd: None, env: map.from_list([]), stdin: Some(db_bytes) }) {
    Err(e) => Err(str.concat("cannot spawn writer: ", e)),
    Ok(h) => {
      let ex := process.wait(h)
      if ex.code == 0 {
        Ok(tmp)
      } else {
        Err("writing the uploaded record failed")
      }
    },
  }
}

# A sprint id is interpolated into a single-quoted shell word for the
# subprocess relay below. Inside single quotes the ONLY dangerous byte is
# the single quote itself; newlines are refused too for log hygiene.
fn quote_safe(s :: Str) -> Bool
  examples {
    quote_safe("pilotco/iter-1") => true,
    quote_safe("x' ; rm -rf /tmp'") => false,
    quote_safe("a\nb") => false
  }
{
  if str.contains(s, "'") {
    false
  } else {
    str.contains(s, "\n") == false
  }
}

# Pull the one VERDICTS| line out of the relay subprocess's output.
fn extract_verdicts(output :: Str) -> Option[Str]
  examples {
    extract_verdicts("noise\nVERDICTS|{\"verified\":true}\nnull\n") => Some("{\"verified\":true}"),
    extract_verdicts("no marker here") => None
  }
{
  match list.head(list.tail(str.split(output, "VERDICTS|"))) {
    None => None,
    Some(rest) => match list.head(str.split(rest, "\n")) {
      None => Some(rest),
      Some(line) => Some(line),
    },
  }
}

# The verification itself runs in a SUBPROCESS: the exact same
# `verify_record_cmd` a pilot runs locally (src/main.lex), so the hosted
# path and the local path cannot drift — one verifier, two transports.
# (It also has to be a subprocess: the record re-derivation needs the
# `vcs` effect, which `net.serve_fn`'s fixed handler row does not carry.)
# The subprocess inherits this service's LEX_STORE_ROOT, so uploads stay
# judged self-contained.
fn run_verifier(tmp :: Str, sprint_id :: Str, rerun_grounded :: Bool) -> [proc] Result[Str, Str] {
  let cmd := str.join(["DB_PATH='", tmp, "' SPRINT_ID='", sprint_id, "' VERIFY_RERUN_GROUNDED='", if rerun_grounded {
    "1"
  } else {
    "0"
  }, "' lex run --max-steps 0 --allow-effects approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs src/main.lex verify_record_cmd"], "")
  match process.run("sh", ["-c", cmd]) {
    Err(e) => Err(str.concat("verifier failed to run: ", e)),
    Ok(r) => match extract_verdicts(r.stdout) {
      None => Err("verifier produced no verdicts"),
      Some(v) => Ok(v),
    },
  }
}

fn handle_verify(sprint_id :: Str, db_b64 :: Str, max_bytes :: Int, rerun_grounded :: Bool) -> [fs_write, crypto, proc, random, io] resp.Response {
  if str.is_empty(sprint_id) or str.is_empty(db_b64) {
    error_json(400, "sprint_id (query param) and a base64 body are required")
  } else {
    if quote_safe(sprint_id) == false {
      error_json(400, "sprint_id contains refused characters")
    } else {
      match crypto.base64_decode(db_b64) {
        Err(_) => error_json(400, "body is not valid base64"),
        Ok(db_bytes) => if size_ok(bytes.len(db_bytes), max_bytes) == false {
          error_json(413, "record exceeds VERIFY_MAX_BYTES")
        } else {
          match write_temp_db(db_bytes) {
            Err(e) => error_json(500, e),
            Ok(tmp) => {
              let result := run_verifier(tmp, sprint_id, rerun_grounded)
              let __rm := fs.remove(tmp)
              match result {
                Err(e) => error_json(500, e),
                Ok(v) => { status: 200, body: v, headers: map.from_list([("content-type", "application/json")]) },
              }
            },
          }
        },
      }
    }
  }
}

# ── Token gate (mirrors server/cx_a2a.lex) ───────────────────────────────────
fn token_matches(presented :: Str, expected :: Str) -> Bool {
  if str.is_empty(presented) or str.is_empty(expected) {
    false
  } else {
    crypto.constant_time_eq(bytes.from_str(presented), bytes.from_str(expected))
  }
}

fn is_authorized(c :: ctx.Ctx, expected_token :: Str) -> Bool {
  match ctx.bearer_token(c) {
    None => false,
    Some(presented) => token_matches(presented, expected_token),
  }
}

fn verify_route(expected_token :: Str, max_bytes :: Int, rerun_grounded :: Bool) -> (ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
  fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] resp.Response {
    if is_authorized(c, expected_token) {
      let sprint_id := match map.get(ctx.query_map(c), "sprint_id") {
        Some(v) => v,
        None => "",
      }
      handle_verify(sprint_id, str.trim(wbody.raw_body(c)), max_bytes, rerun_grounded)
    } else {
      resp.unauthorized("missing or invalid Authorization: Bearer <token>")
    }
  }
}

fn health_route() -> (ctx.Ctx) -> resp.Response {
  fn (_c :: ctx.Ctx) -> resp.Response {
    resp.json("{\"ok\":true,\"service\":\"loom-verify\"}")
  }
}

# ── Entry point ───────────────────────────────────────────────────────────────
# Run it:
#   VERIFY_API_TOKEN=<a real secret> LEX_STORE_ROOT=$(mktemp -d) \
#   lex run --max-steps 0 --allow-effects approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,time,vcs \
#     src/server/verify_api.lex serve_verify_api
#
# Env:
#   PORT                   HTTP listen port (default 9400)
#   VERIFY_API_TOKEN       required — refuses to serve unauthenticated.
#   LEX_STORE_ROOT         required — MUST point at an empty, dedicated
#                          directory so uploads are judged self-contained.
#   VERIFY_MAX_BYTES       decoded-size cap (default 10485760 = 10 MB).
#   VERIFY_RERUN_GROUNDED  "1" re-runs grounded gates — EXECUTES BUILD
#                          COMMANDS FROM THE UPLOAD; sandbox only.
fn serve_verify_api() -> [env, net, io, time, crypto, random, sql, fs_read, fs_write, concurrent, llm, proc, approval, vcs] Unit {
  let token := env_or("VERIFY_API_TOKEN", "")
  let store_root := env_or("LEX_STORE_ROOT", "")
  if str.is_empty(token) {
    io.print("[verify-api] FATAL: VERIFY_API_TOKEN is required — refusing to serve an unauthenticated verifier")
  } else {
    if str.is_empty(store_root) {
      io.print("[verify-api] FATAL: LEX_STORE_ROOT is required (point it at an empty, dedicated directory) — a shared content store would let a tampered upload borrow canonical bytes it did not carry")
    } else {
      let port := match str.to_int(env_or("PORT", "9400")) {
        Some(n) => n,
        None => 9400,
      }
      let max_bytes := match str.to_int(env_or("VERIFY_MAX_BYTES", "10485760")) {
        Some(n) => n,
        None => 10485760,
      }
      let rerun_grounded := env_or("VERIFY_RERUN_GROUNDED", "") == "1"
      let r0 := router.route(router.new(), "GET", "/healthz", health_route())
      let r := router.route_effectful(r0, "POST", "/verify", verify_route(token, max_bytes, rerun_grounded))
      let __p1 := io.print("=== lex-loom hosted verifier (token-gated, self-contained judging) ===")
      let __p2 := io.print(str.concat("  port: ", int.to_str(port)))
      let __p3 := io.print(str.concat("  grounded re-runs: ", if rerun_grounded {
        "ENABLED (sandbox only!)"
      } else {
        "skipped (default)"
      }))
      net.serve_fn(port, fn (req :: Request) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc, approval] Response {
        let raw := { body: req.body, method: req.method, path: req.path, query: req.query, headers: req.headers }
        let rsp := router.dispatch(r, raw)
        { status: rsp.status, body: BodyStr(rsp.body), headers: rsp.headers }
      })
    }
  }
}

