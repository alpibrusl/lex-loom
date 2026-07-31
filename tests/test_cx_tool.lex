# test_cx_tool.lex — unit tests for the fetch_support_items tool (#162).
#
# Read-only by design (see roles.lex's make_fetch_support_tool comment) — the
# CX role has no send path at all, so the only real behavior to verify is the
# fetch itself. Same reasoning as test_deploy_hetzner.lex: the real curl-a-
# live-server path is live-verified rather than mocked in this suite; only
# the deterministic validation/error paths are unit-tested here.

import "std.str" as str

import "std.list" as list

import "lex-schema/json_value" as jv

import "../src/roles" as roles

fn get_str(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn get_items(j :: jv.Json) -> List[jv.Json] {
  match jv.get_field(j, "items") {
    Some(JList(xs)) => xs,
    _ => [],
  }
}

# url is required -- must be rejected before any network call is attempted.
fn test_missing_url_returns_clean_error() -> [env, net, io, proc] Result[Unit, Str] {
  let tool := roles.make_fetch_support_tool()
  match tool.execute(JObj([("url", JStr(""))])) {
    Err(_) => Err("expected an Ok(JObj) result, not a tool-level Err"),
    Ok(result) => if str.contains(get_str(result, "error"), "url") {
      if list.is_empty(get_items(result)) {
        Ok(())
      } else {
        Err("expected an empty items list alongside the error")
      }
    } else {
      Err(str.concat("expected the error to mention url, got: ", get_str(result, "error")))
    },
  }
}

# A refused connection must report a clean error, not a tool-level Err or a
# fabricated items list.
fn test_unreachable_url_returns_clean_error() -> [env, net, io, proc] Result[Unit, Str] {
  let tool := roles.make_fetch_support_tool()
  match tool.execute(JObj([("url", JStr("http://127.0.0.1:1"))])) {
    Err(_) => Err("expected an Ok(JObj) result, not a tool-level Err"),
    Ok(result) => if str.contains(get_str(result, "error"), "could not reach") {
      if list.is_empty(get_items(result)) {
        Ok(())
      } else {
        Err("expected an empty items list alongside the unreachable error")
      }
    } else {
      Err(str.concat("expected a clean unreachable message, got: ", get_str(result, "error")))
    },
  }
}

fn suite() -> [env, net, io, proc] List[Result[Unit, Str]] {
  [test_missing_url_returns_clean_error(), test_unreachable_url_returns_clean_error()]
}

fn run_all() -> [env, net, io, proc] Unit {
  let failures := list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
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

