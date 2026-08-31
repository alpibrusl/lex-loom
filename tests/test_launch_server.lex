# test_launch_server.lex — the launch node must be able to start the thing the
# build produced, and must say why when it cannot.
#
# Found live (tzpin): launch returned {"ok":false} seven times across four
# attempts each, on a server that started by hand in six seconds and answered
# correctly. Three separate causes, all in the tool:
#
#   1. The command ran from the REPO ROOT, not the node's work dir, so the
#      natural `python3 main.py` could never find its file.
#   2. `port` built the URL and freed the port but was never given to the
#      child, so the server bound its own default while the poller watched a
#      different port. Even an explicit `cd` still failed.
#   3. The script captured the server's own log and then threw it away: the
#      agent was told "server did not respond within 12s" while the log said
#      `can't open file 'main.py'`. Four retries against a message carrying no
#      information to act on.
#
# The prompt did tell the agent to cd and to set PORT itself. Requiring a model
# to get two fiddly things right inside a command string, when the tool knows
# both, is what these tests exist to prevent.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.process" as proc

import "../src/roles" as roles

import "../src/lex_skill" as lexskill

import "lex-schema/json_value" as jv

fn field(r :: jv.Json, key :: Str) -> Str {
  match jv.get_field(r, key) {
    Some(JStr(v)) => v,
    Some(JBool(b)) => if b {
      "true"
    } else {
      "false"
    },
    _ => "",
  }
}

fn seed_server(sprint :: Str) -> [io, proc] Unit {
  let dir := lexskill.py_work_dir(sprint)
  let __f := proc.run("bash", ["-c", "lsof -ti tcp:9999 2>/dev/null | xargs kill -9 2>/dev/null || true"])
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf ", dir, "; mkdir -p ", dir], "")])
  let __w := io.write(str.join([dir, "/main.py"], ""), "import http.server, os, socketserver\n\nclass H(http.server.BaseHTTPRequestHandler):\n    def do_GET(self):\n        self.send_response(200)\n        self.end_headers()\n        self.wfile.write(b'alive')\n    def log_message(self, *a):\n        pass\n\nport = int(os.environ.get('PORT', '9999'))\nsocketserver.TCPServer(('127.0.0.1', port), H).serve_forever()\n")
  ()
}

fn launch(sprint :: Str, cmd :: Str, port :: Int) -> [env, io, net, proc] Result[jv.Json, Str] {
  let tool := roles.make_run_server_tool(sprint)
  match tool.execute(JObj([("cmd", JStr(cmd)), ("port", JInt(port)), ("endpoint", JStr("/")), ("timeout_s", JInt(15))])) {
    Err(_) => Err("run_server errored"),
    Ok(r) => Ok(r),
  }
}

fn kill_port(port :: Str) -> [proc] Unit {
  let __k := proc.run("bash", ["-c", str.join(["lsof -ti tcp:", port, " 2>/dev/null | xargs kill -9 2>/dev/null || true"], "")])
  ()
}

# The command a model actually writes, with no cd and no PORT: the tool knows
# the work dir and the port, so it must supply both.
fn test_bare_command_starts_the_build() -> [env, io, net, proc] Result[Unit, Str] {
  let sprint := "t-launch-bare/iter-1"
  let __s := seed_server(sprint)
  let res := launch(sprint, "python3 main.py", 8121)
  let __k := kill_port("8121")
  match res {
    Err(e) => Err(e),
    Ok(r) => if field(r, "ok") == "true" {
      Ok(())
    } else {
      Err(str.concat("a bare command must still start the build: ", field(r, "error")))
    },
  }
}

# The port the tool was given is the port the server must bind, or the poller
# and the server are watching different sockets by construction.
fn test_the_port_reaches_the_server() -> [env, io, net, proc] Result[Unit, Str] {
  let sprint := "t-launch-port/iter-1"
  let __s := seed_server(sprint)
  let res := launch(sprint, "python3 main.py", 8122)
  let __k := kill_port("8122")
  match res {
    Err(e) => Err(e),
    Ok(r) => if str.contains(field(r, "url"), "8122") and field(r, "ok") == "true" {
      Ok(())
    } else {
      Err(str.concat("the server must bind the port the tool was given, not its own default: ", field(r, "error")))
    },
  }
}

# The whole reason four retries were wasted: the tool had the answer and
# discarded it.
fn test_failure_reports_what_the_server_said() -> [env, io, net, proc] Result[Unit, Str] {
  let sprint := "t-launch-broken/iter-1"
  let __s := seed_server(sprint)
  let res := launch(sprint, "python3 nosuchfile.py", 8123)
  let __k := kill_port("8123")
  match res {
    Err(e) => Err(e),
    Ok(r) => if field(r, "ok") == "true" {
      Err("a command that cannot start must not report ok")
    } else {
      if str.contains(field(r, "error"), "nosuchfile") {
        Ok(())
      } else {
        Err(str.concat("the failure must carry the server's own error, got: ", field(r, "error")))
      }
    },
  }
}

# An explicit cd is the caller being specific — never overridden.
fn test_explicit_cd_is_respected() -> [env, io, net, proc] Result[Unit, Str] {
  let sprint := "t-launch-explicit/iter-1"
  let __s := seed_server(sprint)
  let dir := lexskill.py_work_dir(sprint)
  let res := launch(sprint, str.join(["cd ", dir, " && python3 main.py"], ""), 8124)
  let __k := kill_port("8124")
  match res {
    Err(e) => Err(e),
    Ok(r) => if field(r, "ok") == "true" {
      Ok(())
    } else {
      Err(str.concat("an explicit cd must still work: ", field(r, "error")))
    },
  }
}

# A 404 to the endpoint under test still means a server is UP, but it is much
# weaker evidence than a 200 and the demo must be able to tell them apart.
fn test_status_is_reported() -> [env, io, net, proc] Result[Unit, Str] {
  let sprint := "t-launch-status/iter-1"
  let __s := seed_server(sprint)
  let res := launch(sprint, "python3 main.py", 8125)
  let __k := kill_port("8125")
  match res {
    Err(e) => Err(e),
    Ok(r) => if field(r, "status") == "200" {
      Ok(())
    } else {
      Err(str.concat("launch evidence must carry the HTTP status, got: ", field(r, "status")))
    },
  }
}

fn run_all() -> [env, io, net, proc] Int {
  let results := [("bare command starts the build", test_bare_command_starts_the_build()), ("the port reaches the server", test_the_port_reaches_the_server()), ("failure reports what the server said", test_failure_reports_what_the_server_said()), ("explicit cd is respected", test_explicit_cd_is_respected()), ("status is reported", test_status_is_reported())]
  list.fold(results, 0, fn (fails :: Int, r :: (Str, Result[Unit, Str])) -> [io] Int {
    match r {
      (name, Ok(_)) => {
        let __ := io.print(str.concat("ok   ", name))
        fails
      },
      (name, Err(e)) => {
        let __ := io.print(str.join(["FAIL ", name, ": ", e], ""))
        fails + 1
      },
    }
  })
}

