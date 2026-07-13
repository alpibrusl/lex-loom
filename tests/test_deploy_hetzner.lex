# test_deploy_hetzner.lex — unit tests for the deploy_hetzner tool (#101).
#
# Exercises the two deterministic, no-real-infra validation paths directly:
# HETZNER_HOST unset (the honest "a human hasn't provisioned a server yet"
# case) and a missing work_dir. The actual rsync/ssh/docker/curl path against
# a real server is intentionally NOT unit-tested here -- same reasoning as
# `run_server` having no behavior-level test either: it needs live infra, so
# it's verified live (see the PR description) rather than mocked.

import "std.str" as str

import "std.list" as list

import "std.env" as env

import "lex-schema/json_value" as jv

import "../src/roles" as roles

fn get_bool(j :: jv.Json, key :: Str) -> Option[Bool] {
  match jv.get_field(j, key) {
    Some(JBool(b)) => Some(b),
    _ => None,
  }
}

fn get_str(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# With HETZNER_HOST unset (the default -- no server provisioned yet), the
# tool must refuse cleanly and say exactly why, rather than attempt a deploy
# against nothing or silently claim success.
fn test_no_host_set_returns_clean_error() -> [env, net, io, proc] Result[Unit, Str] {
  let tool := roles.make_deploy_hetzner_tool()
  match tool.execute(JObj([("work_dir", JStr("/tmp/loom-py-work")), ("service_name", JStr("myapp")), ("port", JInt(8080))])) {
    Err(_) => Err("expected an Ok(JObj) result, not a tool-level Err"),
    Ok(result) => match get_bool(result, "ok") {
      Some(false) => if str.contains(get_str(result, "error"), "HETZNER_HOST") {
        Ok(())
      } else {
        Err(str.concat("expected the error to mention HETZNER_HOST, got: ", get_str(result, "error")))
      },
      _ => Err("expected ok:false when HETZNER_HOST is unset"),
    },
  }
}

# work_dir is required -- an empty one must be rejected before any
# rsync/ssh is attempted (this check runs before the host check would even
# matter in a misconfigured call).
fn test_missing_work_dir_returns_clean_error() -> [env, net, io, proc] Result[Unit, Str] {
  let tool := roles.make_deploy_hetzner_tool()
  match tool.execute(JObj([("work_dir", JStr("")), ("service_name", JStr("myapp")), ("port", JInt(8080))])) {
    Err(_) => Err("expected an Ok(JObj) result, not a tool-level Err"),
    Ok(result) => match get_bool(result, "ok") {
      Some(false) => if str.contains(get_str(result, "error"), "work_dir") {
        Ok(())
      } else {
        Err(str.concat("expected the error to specifically mention work_dir (not some other unrelated validation failure), got: ", get_str(result, "error")))
      },
      _ => Err("expected ok:false for an empty work_dir"),
    },
  }
}

fn suite() -> [env, net, io, proc] List[Result[Unit, Str]] {
  [test_no_host_set_returns_clean_error(), test_missing_work_dir_returns_clean_error()]
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

