# test_run_server_evidence.lex -- run_server must attest only to a server it
# actually started, serving the endpoint it was asked about (#312).
#
# run_server had no behaviour-level test: it needs live processes, so it was
# only ever "verified live". A probe of the launch node then accepted a node
# whose recorded evidence was
#
#   {"ok":true,"status":"404","response":"{\"detail\":\"Not Found\"}","pid":"3336"}
#
# in a work dir containing no server at all. Two separate holes produced that
# single false pass:
#
#   1. `ok` was `contains(output, "READY")`, and READY was printed for ANY
#      response. A 404 is a response. So "the endpoint under test does not
#      exist" was recorded as live evidence that the product works.
#   2. Nothing checked that the process we started was the one answering. A
#      leftover server from an earlier attempt was still holding the port, so
#      the health check hit a stranger and called it ours.
#
# Both are the shape this project keeps hitting: a gate reporting a cause that
# is not true, which then steers the repair loop. These tests use real
# processes -- a mock would re-assert my own beliefs about the shell rather
# than test it.

import "std.str" as str

import "std.list" as list

import "std.proc" as proc

import "std.io" as io

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

# Leaving a server behind is not hypothetical: a leaked one squatting a launch
# port is what made the probe accept a stranger's response in the first place.
fn free_port(port :: Int) -> [proc] Unit {
  let __ := proc.run("bash", ["-c", str.join(["lsof -ti tcp:", int.to_str(port), " 2>/dev/null | xargs kill -9 2>/dev/null || true"], "")])
  ()
}

fn run(port :: Int, cmd :: Str, endpoint :: Str) -> [env, net, io, proc, fs_write] jv.Json {
  let __free := free_port(port)
  let tool := roles.make_run_server_tool("/tmp/loom-launch-evidence-test.json", "sprint-runserver-test")
  let out := match tool.execute(JObj([("cmd", JStr(cmd)), ("port", JInt(port)), ("endpoint", JStr(endpoint)), ("timeout_s", JInt(8))])) {
    Err(_) => JObj([("ok", JBool(false)), ("error", JStr("tool-level Err"))]),
    Ok(r) => r,
  }
  let __cleanup := free_port(port)
  out
}

# `python3 -m http.server` in an empty directory answers 200 on / and 404 on
# anything else, so one command exercises both verdicts and neither test can
# pass because the server simply failed to start.
fn serve_cmd(port :: Int) -> Str {
  str.join(["cd /tmp && python3 -m http.server ", int.to_str(port)], "")
}

fn test_a_working_endpoint_is_accepted() -> [env, net, io, proc, fs_write] Result[Unit, Str] {
  let r := run(8791, serve_cmd(8791), "/")
  match get_bool(r, "ok") {
    Some(true) => Ok(()),
    _ => Err(str.concat("a server really serving the endpoint was rejected: ", get_str(r, "error"))),
  }
}

# The regression that matters: same live server, endpoint that does not exist.
fn test_a_404_endpoint_is_not_evidence() -> [env, net, io, proc, fs_write] Result[Unit, Str] {
  let r := run(8792, serve_cmd(8792), "/convert")
  match get_bool(r, "ok") {
    Some(false) => if str.contains(get_str(r, "error"), "never served") {
      Ok(())
    } else {
      Err(str.concat("rejected, but for the wrong reason -- the message should say the endpoint was never served: ", get_str(r, "error")))
    },
    _ => Err("a 404 on the endpoint under test was accepted as live evidence that the product works"),
  }
}

# A command that backgrounds its server and exits leaves the port answering
# while the process we started is gone -- indistinguishable, to the old check,
# from a stranger holding the port, and reported as success by both.
#
# A server that deliberately daemonises is now reported as FOREIGN too. That
# is the intended trade: loom's launch role runs foreground servers, and a
# loud wrong answer is recoverable where a silent false pass is not.
fn test_a_server_we_did_not_start_is_refused() -> [env, net, io, proc, fs_write] Result[Unit, Str] {
  let r := run(8793, str.join(["cd /tmp && (python3 -m http.server 8793 >/dev/null 2>&1 &) && sleep 0.2"], ""), "/")
  match get_bool(r, "ok") {
    Some(false) => if str.contains(get_str(r, "error"), "NOT the one this command started") {
      Ok(())
    } else {
      Err(str.concat("rejected, but not as a foreign server: ", get_str(r, "error")))
    },
    _ => Err("a server this command did not start was accepted as its own live evidence"),
  }
}

fn test_a_command_that_starts_nothing_is_refused() -> [env, net, io, proc, fs_write] Result[Unit, Str] {
  let r := run(8794, "cd /tmp && python3 no_such_server_file.py", "/")
  match get_bool(r, "ok") {
    Some(false) => Ok(()),
    _ => Err("a command that starts no server at all was accepted"),
  }
}

fn suite() -> [env, net, io, proc, fs_write] List[Result[Unit, Str]] {
  [test_a_working_endpoint_is_accepted(), test_a_404_endpoint_is_not_evidence(), test_a_server_we_did_not_start_is_refused(), test_a_command_that_starts_nothing_is_refused()]
}

fn run_all() -> [env, net, io, proc, fs_write] Unit {
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

fn report() -> [env, net, io, proc, fs_write] Unit {
  let __ := list.map(suite(), fn (r :: Result[Unit, Str]) -> [io] Unit {
    match r {
      Ok(_) => io.print("ok\n"),
      Err(e) => io.print(str.concat("FAIL: ", str.concat(e, "\n"))),
    }
  })
  ()
}

