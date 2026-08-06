# test_cx_a2a.lex — regression coverage for the cx A2A token gate
# (lex-loom#193): src/server/cx_a2a.lex.

import "std.list" as list

import "std.map" as map

import "lex-web/ctx" as ctx

import "../src/server/cx_a2a" as cx_a2a

fn ctx_with_auth_header(value :: Str) -> ctx.Ctx {
  { method: "POST", path: "/", query: "", body: "{}", path_params: map.new(), headers: map.from_list([("authorization", value)]), state: map.new() }
}

fn ctx_without_auth_header() -> ctx.Ctx {
  { method: "POST", path: "/", query: "", body: "{}", path_params: map.new(), headers: map.new(), state: map.new() }
}

# ── token_matches ─────────────────────────────────────────────────────────────
fn test_token_matches_identical_strings() -> Result[Unit, Str] {
  if cx_a2a.token_matches("secret-abc", "secret-abc") {
    Ok(())
  } else {
    Err("expected identical tokens to match")
  }
}

fn test_token_matches_rejects_wrong_token() -> Result[Unit, Str] {
  if cx_a2a.token_matches("wrong-token", "secret-abc") {
    Err("expected a mismatched token to be rejected")
  } else {
    Ok(())
  }
}

fn test_token_matches_rejects_empty_presented() -> Result[Unit, Str] {
  if cx_a2a.token_matches("", "secret-abc") {
    Err("expected an empty presented token to be rejected")
  } else {
    Ok(())
  }
}

fn test_token_matches_rejects_empty_expected() -> Result[Unit, Str] {
  if cx_a2a.token_matches("anything", "") {
    Err("expected an empty expected token to never match (misconfiguration is a deny, not an allow)")
  } else {
    Ok(())
  }
}

# ── is_authorized ──────────────────────────────────────────────────────────────
fn test_is_authorized_with_correct_bearer_token() -> Result[Unit, Str] {
  let c := ctx_with_auth_header("Bearer secret-abc")
  if cx_a2a.is_authorized(c, "secret-abc") {
    Ok(())
  } else {
    Err("expected a matching Bearer token to authorize")
  }
}

fn test_is_authorized_with_wrong_bearer_token() -> Result[Unit, Str] {
  let c := ctx_with_auth_header("Bearer wrong-token")
  if cx_a2a.is_authorized(c, "secret-abc") {
    Err("expected a mismatched Bearer token to be denied")
  } else {
    Ok(())
  }
}

fn test_is_authorized_with_no_auth_header() -> Result[Unit, Str] {
  let c := ctx_without_auth_header()
  if cx_a2a.is_authorized(c, "secret-abc") {
    Err("expected a request with no Authorization header to be denied")
  } else {
    Ok(())
  }
}

fn test_is_authorized_with_non_bearer_scheme() -> Result[Unit, Str] {
  let c := ctx_with_auth_header("Basic secret-abc")
  if cx_a2a.is_authorized(c, "secret-abc") {
    Err("expected a non-Bearer Authorization header to be denied")
  } else {
    Ok(())
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_token_matches_identical_strings(), test_token_matches_rejects_wrong_token(), test_token_matches_rejects_empty_presented(), test_token_matches_rejects_empty_expected(), test_is_authorized_with_correct_bearer_token(), test_is_authorized_with_wrong_bearer_token(), test_is_authorized_with_no_auth_header(), test_is_authorized_with_non_bearer_scheme()]
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

