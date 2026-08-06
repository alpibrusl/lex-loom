# test_web_auth.lex — regression coverage for src/web/server.lex's API
# token gate (lex-loom#190): token_matches / presented_token /
# is_authorized.

import "std.list" as list

import "std.map" as map

import "lex-web/src/ctx" as ctx

import "../src/web/server" as server

fn ctx_with_header(value :: Str) -> ctx.Ctx {
  { method: "GET", path: "/api/companies", query: "", body: "", path_params: map.new(), headers: map.from_list([("authorization", value)]), state: map.new() }
}

fn ctx_with_query(query :: Str) -> ctx.Ctx {
  { method: "GET", path: "/api/companies", query: query, body: "", path_params: map.new(), headers: map.new(), state: map.new() }
}

fn ctx_bare() -> ctx.Ctx {
  { method: "GET", path: "/api/companies", query: "", body: "", path_params: map.new(), headers: map.new(), state: map.new() }
}

# ── token_matches ─────────────────────────────────────────────────────────────
fn test_token_matches_identical_strings() -> Result[Unit, Str] {
  if server.token_matches("secret-abc", "secret-abc") {
    Ok(())
  } else {
    Err("expected identical tokens to match")
  }
}

fn test_token_matches_rejects_wrong_token() -> Result[Unit, Str] {
  if server.token_matches("wrong", "secret-abc") {
    Err("expected a mismatched token to be rejected")
  } else {
    Ok(())
  }
}

fn test_token_matches_rejects_both_empty() -> Result[Unit, Str] {
  if server.token_matches("", "") {
    Err("expected two empty tokens to never match (misconfiguration is a deny, not an allow)")
  } else {
    Ok(())
  }
}

# ── presented_token / is_authorized ───────────────────────────────────────────
fn test_authorized_via_bearer_header() -> Result[Unit, Str] {
  let c := ctx_with_header("Bearer secret-abc")
  if server.is_authorized(c, "secret-abc") {
    Ok(())
  } else {
    Err("expected a matching Bearer header to authorize")
  }
}

fn test_authorized_via_query_param() -> Result[Unit, Str] {
  let c := ctx_with_query("token=secret-abc")
  if server.is_authorized(c, "secret-abc") {
    Ok(())
  } else {
    Err("expected a matching ?token= query param to authorize (EventSource can't set headers)")
  }
}

fn test_header_takes_priority_over_query() -> Result[Unit, Str] {
  let c := { method: "GET", path: "/api/companies", query: "token=wrong-one", body: "", path_params: map.new(), headers: map.from_list([("authorization", "Bearer secret-abc")]), state: map.new() }
  if server.is_authorized(c, "secret-abc") {
    Ok(())
  } else {
    Err("expected the correct header token to authorize even with a wrong query param present")
  }
}

fn test_denied_with_no_token_anywhere() -> Result[Unit, Str] {
  let c := ctx_bare()
  if server.is_authorized(c, "secret-abc") {
    Err("expected no credentials anywhere to be denied")
  } else {
    Ok(())
  }
}

fn test_denied_with_wrong_query_token() -> Result[Unit, Str] {
  let c := ctx_with_query("token=not-it")
  if server.is_authorized(c, "secret-abc") {
    Err("expected a wrong query token to be denied")
  } else {
    Ok(())
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_token_matches_identical_strings(), test_token_matches_rejects_wrong_token(), test_token_matches_rejects_both_empty(), test_authorized_via_bearer_header(), test_authorized_via_query_param(), test_header_takes_priority_over_query(), test_denied_with_no_token_anywhere(), test_denied_with_wrong_query_token()]
}

fn run_all() -> Unit {
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

