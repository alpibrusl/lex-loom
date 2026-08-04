# tests/test_soft_register.lex — SA2 (lex-loom#179): unit tests for
# soft_register.lex's deterministic paths.
#
# Same discipline as test_cx_tool.lex: the real round-trip against a live
# lex-soft mesh node is verified live (see demo/sa2-mesh-roundtrip.sh and
# the PR description), not mocked here — only clean-error and pure-builder
# paths are unit-tested, plus one real "connection refused" case (fast and
# deterministic in CI, same pattern test_cx_tool.lex already uses for
# test_unreachable_url_returns_clean_error).

import "std.str" as str

import "std.list" as list

import "lex-schema/json_value" as jv

import "../src/soft_register" as sr

# ── known_capabilities / is_known_role ──────────────────────────────────────────
fn test_cx_is_a_known_role() -> Result[Unit, Str] {
  if sr.is_known_role("cx") {
    if list.len(sr.known_capabilities("cx")) > 0 {
      Ok(())
    } else {
      Err("cx should have at least one known capability")
    }
  } else {
    Err("expected cx to be a known role")
  }
}

fn test_unknown_role_is_not_known() -> Result[Unit, Str] {
  if sr.is_known_role("monetization_handoff") {
    Err("monetization_handoff has no A2A server wired yet — should not be known")
  } else {
    if list.is_empty(sr.known_capabilities("monetization_handoff")) {
      Ok(())
    } else {
      Err("expected no capabilities for an unknown role")
    }
  }
}

# ── split_roles ───────────────────────────────────────────────────────────────
fn test_split_roles_trims_and_drops_empty() -> Result[Unit, Str] {
  let got := sr.split_roles(" cx, distribution ,,monetization_handoff ")
  if got == ["cx", "distribution", "monetization_handoff"] {
    Ok(())
  } else {
    Err(str.join(["unexpected split: ", str.join(got, "|")], ""))
  }
}

fn test_split_roles_empty_string_is_empty_list() -> Result[Unit, Str] {
  if list.is_empty(sr.split_roles("")) {
    Ok(())
  } else {
    Err("expected an empty role list for an empty string")
  }
}

# ── peer_payload ──────────────────────────────────────────────────────────────
fn get_str(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn get_caps(j :: jv.Json) -> List[Str] {
  match jv.get_field(j, "capabilities") {
    Some(JList(xs)) => list.fold(xs, [], fn (acc :: List[Str], x :: jv.Json) -> List[Str] {
      match x {
        JStr(s) => list.concat(acc, [s]),
        _ => acc,
      }
    }),
    _ => [],
  }
}

fn test_peer_payload_carries_id_inbox_org_and_capabilities() -> Result[Unit, Str] {
  let body := sr.peer_payload("acme-cx", "http://localhost:9200", "cx", "acme")
  match jv.parse(body) {
    Err(_) => Err(str.concat("payload did not parse as JSON: ", body)),
    Ok(j) => if get_str(j, "id") == "acme-cx" {
      if get_str(j, "inbox_url") == "http://localhost:9200" {
        if get_str(j, "org") == "acme" {
          if get_caps(j) == ["support.fetch_items"] {
            Ok(())
          } else {
            Err(str.concat("unexpected capabilities in payload: ", body))
          }
        } else {
          Err(str.concat("unexpected org in payload: ", body))
        }
      } else {
        Err(str.concat("unexpected inbox_url in payload: ", body))
      }
    } else {
      Err(str.concat("unexpected id in payload: ", body))
    },
  }
}

# ── interpret_peers_response ────────────────────────────────────────────────────
fn test_interpret_peers_response_ok_true_is_ok() -> Result[Unit, Str] {
  match sr.interpret_peers_response("{\"ok\":true,\"peer\":\"acme-cx\"}") {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("expected Ok, got: ", e)),
  }
}

fn test_interpret_peers_response_error_body_is_err() -> Result[Unit, Str] {
  match sr.interpret_peers_response("{\"error\":\"id is required\"}") {
    Ok(_) => Err("expected Err for an error-shaped response"),
    Err(_) => Ok(()),
  }
}

fn test_interpret_peers_response_garbage_is_err() -> Result[Unit, Str] {
  match sr.interpret_peers_response("not json") {
    Ok(_) => Err("expected Err for an unparseable response"),
    Err(_) => Ok(()),
  }
}

# ── register_role — clean errors before any network call ───────────────────────
fn test_register_role_missing_mesh_url_is_clean_error() -> [net] Result[Unit, Str] {
  match sr.register_role("", "acme", "cx", "http://localhost:9200") {
    Ok(_) => Err("expected an error for a missing mesh_url"),
    Err(e) => if str.contains(e, "mesh_url") {
      Ok(())
    } else {
      Err(str.concat("expected the error to mention mesh_url, got: ", e))
    },
  }
}

fn test_register_role_missing_org_id_is_clean_error() -> [net] Result[Unit, Str] {
  match sr.register_role("http://localhost:9100", "", "cx", "http://localhost:9200") {
    Ok(_) => Err("expected an error for a missing org_id"),
    Err(e) => if str.contains(e, "org_id") {
      Ok(())
    } else {
      Err(str.concat("expected the error to mention org_id, got: ", e))
    },
  }
}

fn test_register_role_unknown_role_is_clean_error() -> [net] Result[Unit, Str] {
  match sr.register_role("http://localhost:9100", "acme", "monetization_handoff", "http://localhost:9200") {
    Ok(_) => Err("expected an error for an unknown role"),
    Err(e) => if str.contains(e, "no known A2A server") {
      Ok(())
    } else {
      Err(str.concat("expected the error to mention no known A2A server, got: ", e))
    },
  }
}

fn test_register_role_missing_inbox_url_is_clean_error() -> [net] Result[Unit, Str] {
  match sr.register_role("http://localhost:9100", "acme", "cx", "") {
    Ok(_) => Err("expected an error for a missing inbox_url"),
    Err(e) => if str.contains(e, "inbox URL") {
      Ok(())
    } else {
      Err(str.concat("expected the error to mention the inbox URL, got: ", e))
    },
  }
}

# A refused connection (nothing listens on 127.0.0.1:1) must report a clean
# error, not crash or hang — same pattern as test_cx_tool.lex's
# test_unreachable_url_returns_clean_error.
fn test_register_role_unreachable_mesh_is_clean_error() -> [net] Result[Unit, Str] {
  match sr.register_role("http://127.0.0.1:1", "acme", "cx", "http://localhost:9200") {
    Ok(_) => Err("expected an error for an unreachable mesh node"),
    Err(e) => if str.contains(e, "registration request failed") {
      Ok(())
    } else {
      Err(str.concat("expected a clean unreachable message, got: ", e))
    },
  }
}

# ── register_configured_roles — declared-but-unconfigured is a silent skip ─────
fn test_register_configured_roles_skips_unconfigured_role() -> [net] Result[Unit, Str] {
  let results := sr.register_configured_roles("http://localhost:9100", "acme", "cx,monetization_handoff", [])
  if list.is_empty(results) {
    Ok(())
  } else {
    Err("expected no results when no inbox URLs are configured for any declared role")
  }
}

fn test_register_configured_roles_only_registers_configured() -> [net] Result[Unit, Str] {
  let results := sr.register_configured_roles("http://127.0.0.1:1", "acme", "cx,monetization_handoff", [{ role: "cx", inbox_url: "http://localhost:9200" }])
  if list.len(results) == 1 {
    match list.head(results) {
      Some(r) => if r.role == "cx" {
        Ok(())
      } else {
        Err(str.concat("expected the one result to be for cx, got: ", r.role))
      },
      None => Err("unreachable"),
    }
  } else {
    Err(str.join(["expected exactly 1 result (cx only), got ", str.join(list.map(results, fn (r :: sr.RoleResult) -> Str {
      r.role
    }), ","), ""], ""))
  }
}

fn suite() -> [net] List[Result[Unit, Str]] {
  [test_cx_is_a_known_role(), test_unknown_role_is_not_known(), test_split_roles_trims_and_drops_empty(), test_split_roles_empty_string_is_empty_list(), test_peer_payload_carries_id_inbox_org_and_capabilities(), test_interpret_peers_response_ok_true_is_ok(), test_interpret_peers_response_error_body_is_err(), test_interpret_peers_response_garbage_is_err(), test_register_role_missing_mesh_url_is_clean_error(), test_register_role_missing_org_id_is_clean_error(), test_register_role_unknown_role_is_clean_error(), test_register_role_missing_inbox_url_is_clean_error(), test_register_role_unreachable_mesh_is_clean_error(), test_register_configured_roles_skips_unconfigured_role(), test_register_configured_roles_only_registers_configured()]
}

fn run_all() -> [net] Unit {
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

