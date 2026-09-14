# test_launch_dir_follows_the_language.lex — a launch node boots the product
# its company built, not whichever work dir happens to be on disk first.
#
# run_server's directory prelude tries the python, node and lex work dirs for a
# sprint in a fixed order and takes the first that is not empty. The dirs live
# in /tmp, keyed by sprint id, and /tmp outlives the company workspace -- loom
# empties that between iterations -- so a sprint that re-planned across
# languages (metaspec refuses a graph whose build roles do not match the stack
# path, #478) leaves an abandoned py dir standing in front of the lex dir that
# actually passed QA. The fixed order picked the abandoned one.
#
# Both dirs here hold an `app.py` and both are started with the same command,
# so the ONLY thing under test is which directory the prelude chose.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.process" as proc

import "lex-schema/json_value" as jv

import "../src/roles" as roles

import "../src/lex_skill" as lexskill

fn sprint() -> Str {
  "sprint-langdir-test"
}

fn get_str(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn free_port(port :: Int) -> [proc] Unit {
  let __ := proc.run("bash", ["-c", str.join(["lsof -ti tcp:", int.to_str(port), " 2>/dev/null | xargs kill -9 2>/dev/null || true"], "")])
  ()
}

# One marker per directory, served on / by the same command in both.
fn seed_dir(dir :: Str, marker :: Str) -> [proc] Unit {
  let script := str.join(["set -e\n", "rm -rf '", dir, "'\n", "mkdir -p '", dir, "'\n", "cat > '", dir, "/app.py' <<'PYEOF'\n", "import os\n", "from http.server import BaseHTTPRequestHandler, HTTPServer\n", "class H(BaseHTTPRequestHandler):\n", "    def do_GET(self):\n", "        self.send_response(200)\n", "        self.end_headers()\n", "        self.wfile.write(b'", marker, "')\n", "    def log_message(self, *a):\n", "        pass\n", "HTTPServer(('127.0.0.1', int(os.environ['PORT'])), H).serve_forever()\n", "PYEOF\n"], "")
  let __ := proc.run("bash", ["-c", script])
  ()
}

fn clear_dirs() -> [proc] Unit {
  let __ := proc.run("bash", ["-c", str.join(["rm -rf '", lexskill.py_work_dir(sprint()), "' '", lexskill.work_dir(sprint()), "' '", lexskill.ts_work_dir(sprint()), "'"], "")])
  ()
}

# Both dirs seeded, so every run has a real choice to get wrong.
fn boot_with(language :: Str, port :: Int) -> [env, net, io, proc, fs_write] Str {
  let __free := free_port(port)
  let __py := seed_dir(lexskill.py_work_dir(sprint()), "FROM-PY-DIR")
  let __lex := seed_dir(lexskill.work_dir(sprint()), "FROM-LEX-DIR")
  let tool := roles.make_run_server_tool_for("/tmp/loom-langdir-evidence.json", sprint(), language)
  let out := match tool.execute(JObj([("cmd", JStr("python3 app.py")), ("port", JInt(port)), ("endpoint", JStr("/")), ("timeout_s", JInt(8))])) {
    Err(_) => JObj([("response", JStr("tool-level Err"))]),
    Ok(r) => r,
  }
  let __cleanup := free_port(port)
  let __rm := clear_dirs()
  get_str(out, "response")
}

fn expect_marker(got :: Str, want :: Str, what :: Str) -> Result[Unit, Str] {
  if str.contains(got, want) {
    Ok(())
  } else {
    Err(str.join([what, ": expected ", want, ", got ", got], ""))
  }
}

fn test_a_lex_company_boots_the_lex_dir() -> [env, net, io, proc, fs_write] Result[Unit, Str] {
  expect_marker(boot_with("lex", 8231), "FROM-LEX-DIR", "lex company")
}

fn test_a_python_company_boots_the_py_dir() -> [env, net, io, proc, fs_write] Result[Unit, Str] {
  expect_marker(boot_with("python", 8232), "FROM-PY-DIR", "python company")
}

# An unknown path must not move anything: the historical order tried python
# first and a company that never told us what it is keeps that behaviour.
fn test_an_unknown_path_keeps_the_old_order() -> [env, net, io, proc, fs_write] Result[Unit, Str] {
  expect_marker(boot_with("", 8233), "FROM-PY-DIR", "unknown path")
}

fn test_the_order_is_a_permutation_of_all_three() -> Result[Unit, Str] {
  let lex_first := roles.work_dirs_in_language_order(sprint(), "lex")
  if list.len(lex_first) == 3 {
    if list.len(roles.work_dirs_in_language_order(sprint(), "")) == 3 {
      match list.head(lex_first) {
        None => Err("empty order"),
        Some(h) => if h == lexskill.work_dir(sprint()) {
          Ok(())
        } else {
          Err("a lex company does not try its own work dir first")
        },
      }
    } else {
      Err("an unknown path lost a candidate dir")
    }
  } else {
    Err("a lex company lost a candidate dir")
  }
}

fn run_all() -> [env, net, io, proc, fs_write] Int {
  let results := [("a lex company boots the lex dir", test_a_lex_company_boots_the_lex_dir()), ("a python company boots the py dir", test_a_python_company_boots_the_py_dir()), ("an unknown path keeps the old order", test_an_unknown_path_keeps_the_old_order()), ("the order is a permutation of all three", test_the_order_is_a_permutation_of_all_three())]
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

