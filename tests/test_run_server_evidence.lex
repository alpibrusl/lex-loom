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

# A port held by something loom did not start must be LEFT ALONE. run_server
# used to `lsof -ti tcp:PORT | xargs kill -9` unconditionally, so a launch node
# on the Lex convention port (8080) would have killed whatever else was there.
# On the machine this was found on, that was Colima's ssh port-forward -- the
# user's Docker VM. Refusing to attest to a stranger's server while still
# killing it was the inconsistency.
# A port held by something loom did not start must be LEFT ALONE. run_server
# used to `lsof -ti tcp:PORT | xargs kill -9` unconditionally, so a launch node
# on the Lex convention port (8080) would kill whatever else was there -- on the
# machine this was found on, Colima's ssh port-forward, i.e. the developer's
# Docker VM. Refusing to ATTEST to a stranger's server while still KILLING it
# was the inconsistency.
#
# The server here is started through run_server rather than backgrounded by
# hand: a plain `nohup ... &` inside proc.run never releases the captured stdout
# pipe and hangs the test instead of failing it -- the very hazard run_server's
# own detach-to-a-logfile exists to avoid. Wiping the registry afterwards puts
# loom in the position of facing a listener it has no record of starting, which
# is what a developer's own process looks like from the inside.
#
# The assertion that matters is the SURVIVAL, not the wording: a test that only
# checked the message would pass while the process was still being killed. And
# if the setup server never came up there is nothing to protect, so the test
# reports that rather than claiming a pass it has not earned.
fn test_a_foreign_process_on_the_port_is_not_killed() -> [env, net, io, proc, fs_write] Result[Unit, Str] {
  let __clear := proc.run("bash", ["-c", "rm -f /tmp/loom-servers.pids; lsof -ti tcp:8795 2>/dev/null | xargs kill -9 2>/dev/null || true"])
  let tool := roles.make_run_server_tool("/tmp/loom-launch-evidence-test.json", "sprint-a")
  let started := match tool.execute(JObj([("cmd", JStr("cd /tmp && python3 -m http.server 8795")), ("port", JInt(8795)), ("endpoint", JStr("/")), ("timeout_s", JInt(8))])) {
    Err(_) => JObj([("ok", JBool(false))]),
    Ok(r) => r,
  }
  let __forget := proc.run("bash", ["-c", "rm -f /tmp/loom-servers.pids"])
  let out := match tool.execute(JObj([("cmd", JStr("cd /tmp && python3 -m http.server 8795")), ("port", JInt(8795)), ("endpoint", JStr("/")), ("timeout_s", JInt(5))])) {
    Err(_) => JObj([("ok", JBool(false)), ("error", JStr("tool-level Err"))]),
    Ok(r) => r,
  }
  let survived := match proc.run("bash", ["-c", "lsof -ti tcp:8795 >/dev/null 2>&1 && echo ALIVE || echo GONE"]) {
    Err(_) => "GONE",
    Ok(r) => str.trim(r.stdout),
  }
  let __cleanup := proc.run("bash", ["-c", "lsof -ti tcp:8795 2>/dev/null | xargs kill -9 2>/dev/null || true; rm -f /tmp/loom-servers.pids"])
  match get_bool(started, "ok") {
    Some(true) => if survived == "ALIVE" {
      match get_bool(out, "ok") {
        Some(false) => if str.contains(get_str(out, "error"), "loom did not start") {
          Ok(())
        } else {
          Err(str.concat("the server survived, but the error does not explain why: ", get_str(out, "error")))
        },
        _ => Err("a port held by a process loom has no record of was reported as a successful launch"),
      }
    } else {
      Err("run_server killed a process it has no record of starting -- on a developer machine that is whatever else happens to hold the port")
    },
    _ => Err("the test could not start a server to protect, so it proved nothing about run_server either way"),
  }
}

# Loom must be able to reclaim a port IT started. #316 recorded the pid of the
# `nohup bash -c` wrapper, but the process holding the port is that wrapper's
# CHILD, so loom saw its own server as a stranger and refused to restart on the
# same port. Every existing test missed it because each one kills its port
# explicitly between cases; the probe that caught it did not, and four of five
# launch attempts failed with "held by another process that loom did not start"
# -- naming loom's own python.
# Loom must be able to reclaim a port IT started. #316 recorded the pid of the
# `nohup bash -c` wrapper, but the process holding the port is that wrapper's
# CHILD, so loom saw its own server as a stranger and refused to restart on the
# same port. Every existing test missed it because each one kills its port
# explicitly between cases; the probe that caught it did not, and four of five
# launch attempts failed with "held by another process that loom did not
# start" -- naming loom's own python.
#
# So the two calls below deliberately share a port with no cleanup between
# them, which is exactly the state a retrying launch node is in.
fn test_loom_can_restart_on_a_port_it_started() -> [env, net, io, proc, fs_write] Result[Unit, Str] {
  let __clear := proc.run("bash", ["-c", "rm -f /tmp/loom-servers.pids; lsof -ti tcp:8796 2>/dev/null | xargs kill -9 2>/dev/null || true"])
  let tool := roles.make_run_server_tool("/tmp/loom-launch-evidence-test.json", "sprint-restart")
  let first := match tool.execute(JObj([("cmd", JStr(serve_cmd(8796))), ("port", JInt(8796)), ("endpoint", JStr("/")), ("timeout_s", JInt(8))])) {
    Err(_) => JObj([("ok", JBool(false))]),
    Ok(r) => r,
  }
  let second := match tool.execute(JObj([("cmd", JStr(serve_cmd(8796))), ("port", JInt(8796)), ("endpoint", JStr("/")), ("timeout_s", JInt(8))])) {
    Err(_) => JObj([("ok", JBool(false)), ("error", JStr("tool-level Err"))]),
    Ok(r) => r,
  }
  let __cleanup := proc.run("bash", ["-c", "lsof -ti tcp:8796 2>/dev/null | xargs kill -9 2>/dev/null || true; rm -f /tmp/loom-servers.pids"])
  match get_bool(first, "ok") {
    Some(true) => match get_bool(second, "ok") {
      Some(true) => Ok(()),
      _ => Err(str.concat("loom refused to reuse a port its own previous call had started: ", get_str(second, "error"))),
    },
    _ => Err("the first launch did not come up, so this proves nothing about reclaiming its port"),
  }
}

# A launch that comes up but never serves its endpoint must not leave its
# server holding the port. #321 registered the listener only on the READY
# path, so a server that answered 404 was left running AND unregistered, and
# every later launch in the company was refused with "held by another process
# that loom did not start" -- eleven of fifteen attempts in tzc9, all on loom's
# own earlier server.
fn test_a_failed_launch_frees_its_port() -> [env, net, io, proc, fs_write] Result[Unit, Str] {
  let __clear := proc.run("bash", ["-c", "rm -f /tmp/loom-servers.pids; lsof -ti tcp:8797 2>/dev/null | xargs kill -9 2>/dev/null || true"])
  let tool := roles.make_run_server_tool("/tmp/loom-launch-evidence-test.json", "sprint-fail-frees")
  let out := match tool.execute(JObj([("cmd", JStr(serve_cmd(8797))), ("port", JInt(8797)), ("endpoint", JStr("/does-not-exist")), ("timeout_s", JInt(4))])) {
    Err(_) => JObj([("ok", JBool(false)), ("error", JStr("tool-level Err"))]),
    Ok(r) => r,
  }
  let held := match proc.run("bash", ["-c", "lsof -ti tcp:8797 >/dev/null 2>&1 && echo HELD || echo FREE"]) {
    Err(_) => "HELD",
    Ok(r) => str.trim(r.stdout),
  }
  let __cleanup := proc.run("bash", ["-c", "lsof -ti tcp:8797 2>/dev/null | xargs kill -9 2>/dev/null || true; rm -f /tmp/loom-servers.pids"])
  match get_bool(out, "ok") {
    Some(true) => Err("a 404 on the endpoint was accepted as a launch"),
    _ => if held == "FREE" {
      Ok(())
    } else {
      Err("the failed launch left its server holding the port, so every later launch on it would be refused as foreign")
    },
  }
}

fn suite() -> [env, net, io, proc, fs_write] List[Result[Unit, Str]] {
  [test_a_working_endpoint_is_accepted(), test_a_404_endpoint_is_not_evidence(), test_a_server_we_did_not_start_is_refused(), test_a_command_that_starts_nothing_is_refused(), test_a_foreign_process_on_the_port_is_not_killed(), test_loom_can_restart_on_a_port_it_started(), test_a_failed_launch_frees_its_port()]
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

