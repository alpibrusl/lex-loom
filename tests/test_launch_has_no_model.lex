# test_launch_has_no_model.lex — launch starts what the build wrote and reports
# whether it answered. There is no judgement in that, so there is no model.
#
# Measured at n=20 on 2026-09-16 with a model in the node: 1/20. Pooled with
# the previous day's runs, 4 accepts in 44 samples -- about 9%. `build`,
# measured the same day at the same n, scored 20/20. The node that writes Lex
# from a spec is fine; the node that types a command line was not
# (lex-loom#508).
#
# Every failure captured was procedural, never intellectual: "the agent ran out
# of step budget before answering"; a prompt rule reading "Do NOT call
# run_server again for any reason", which exists because models re-called it
# inside a four-step budget; and a Lex branch demanding a fifteen-effect row be
# transcribed VERBATIM.
#
# Judging whether a RESPONSE is correct is a different question, and one that
# still wants a model where the answer is generated text. That is qa's job.
# launch's gate (`spec json-ok-true`) only ever asked whether the thing
# answered.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.process" as proc

import "lex-schema/json_value" as jv

import "../src/roles" as roles

fn sprint() -> Str {
  "probe-nomodel"
}

fn py_dir() -> Str {
  str.join(["/tmp/loom-py-work-", sprint()], "")
}

fn sh(cmd :: Str) -> [proc] Str {
  match proc.run("bash", ["-c", cmd]) {
    Err(_) => "",
    Ok(r) => str.trim(r.stdout),
  }
}

# A server shaped like anything a build would produce: reads PORT, answers a
# declared route, suppresses its own logging.
fn stage(route :: Str) -> [proc] Unit {
  let src := str.join(["import os\n", "from http.server import BaseHTTPRequestHandler, HTTPServer\n", "class H(BaseHTTPRequestHandler):\n", "    def do_GET(self):\n", "        if self.path == \"", route, "\":\n", "            self.send_response(200); self.end_headers(); self.wfile.write(b'served')\n", "        else:\n", "            self.send_response(404); self.end_headers()\n", "    def log_message(self, *a): pass\n", "HTTPServer((\"\", int(os.environ.get(\"PORT\", \"8081\"))), H).serve_forever()\n"], "")
  let __ := sh(str.join(["rm -rf '", py_dir(), "'; mkdir -p '", py_dir(), "'; cat > '", py_dir(), "/svc.py' <<'PYEOF'\n", src, "PYEOF"], ""))
  ()
}

fn clean() -> [proc] Unit {
  let __ := sh(str.join(["rm -rf '", py_dir(), "'; for q in $(lsof -ti :8081 2>/dev/null); do kill -9 $q 2>/dev/null; done"], ""))
  ()
}

fn field(out :: jv.Json, k :: Str) -> Str {
  match jv.get_field(out, k) {
    Some(JStr(v)) => v,
    Some(JBool(b)) => if b {
      "true"
    } else {
      "false"
    },
    _ => "",
  }
}

# The whole point: no arguments, no model, and it still starts and probes.
fn test_it_launches_with_no_arguments_at_all() -> [net, io, proc] Result[Unit, Str] {
  let __s := stage("/health")
  let tool := roles.make_launch_product_tool("/tmp/loom-nomodel-evidence.json", sprint(), "")
  match tool.execute(JObj([])) {
    Err(_) => {
      let __c := clean()
      Err("the tool itself failed")
    },
    Ok(out) => {
      let ok := field(out, "ok")
      let entry := field(out, "entry_point")
      let __c := clean()
      if ok == "true" {
        if entry == "svc.py" {
          Ok(())
        } else {
          Err(str.concat("started something, but not the entry point it should have found: ", entry))
        }
      } else {
        Err(str.concat("did not start: ", str.slice(field(out, "error"), 0, 140)))
      }
    },
  }
}

# The last judgement left in the node was which path to probe, and that is a
# literal in the source, not a judgement.
fn test_the_endpoint_comes_from_the_build() -> [net, io, proc] Result[Unit, Str] {
  let __s := stage("/health")
  let ep := roles.probe_endpoint_for(py_dir(), "svc.py")
  let __c := clean()
  if ep == "/health" {
    Ok(())
  } else {
    Err(str.concat("a declared health route was not the one chosen: ", ep))
  }
}

fn test_a_build_with_no_health_route_still_gets_a_real_path() -> [net, io, proc] Result[Unit, Str] {
  let __s := stage("/f/demo")
  let ep := roles.probe_endpoint_for(py_dir(), "svc.py")
  let __c := clean()
  if ep == "/f/demo" {
    Ok(())
  } else {
    Err(str.concat("the build's only declared route was not chosen: ", ep))
  }
}

# A build that produced nothing runnable must say so plainly rather than
# claiming a launch.
fn test_an_empty_work_dir_reports_it_honestly() -> [net, io, proc] Result[Unit, Str] {
  let __c0 := clean()
  let __ := sh(str.join(["mkdir -p '", py_dir(), "'; : > '", py_dir(), "/notes.txt'"], ""))
  let tool := roles.make_launch_product_tool("/tmp/loom-nomodel-evidence.json", sprint(), "")
  match tool.execute(JObj([])) {
    Err(_) => {
      let __c := clean()
      Err("the tool failed instead of reporting")
    },
    Ok(out) => {
      let ok := field(out, "ok")
      let err := field(out, "error")
      let __c := clean()
      if ok == "false" {
        if str.contains(err, "no entry point") {
          Ok(())
        } else {
          Err(str.concat("reported a failure but not a usable reason: ", err))
        }
      } else {
        Err("claimed a successful launch with nothing to launch")
      }
    },
  }
}

# COMPANY_PATH is not set in an eval probe, so the orchestrator passes an EMPTY
# language -- and an empty language used to fall through to the Lex branch,
# grepping *.lex for `fn main` inside a Python work dir. 0/20. The first
# version of this suite passed "python" explicitly and never touched the
# derivation the orchestrator actually uses, so it was 4/4 against a node that
# could not launch anything.
fn test_the_language_comes_from_the_dir_the_build_wrote_into() -> Result[Unit, Str] {
  if roles.language_of_work_dir(py_dir(), sprint()) == "python" {
    if roles.language_of_work_dir(str.join(["/tmp/loom-lex-work-", sprint()], ""), sprint()) == "lex" {
      if roles.language_of_work_dir("/tmp/somewhere-else", sprint()) == "" {
        Ok(())
      } else {
        Err("a dir that is not a work dir claimed a language")
      }
    } else {
      Err("a lex work dir was not recognised as lex")
    }
  } else {
    Err("a python work dir was not recognised as python -- this is the 0/20 bug")
  }
}

# A product whose only route is POST must still be probed. Probing it with GET
# earns a 405 or 404 and reports a live product as dead -- which is what the
# first deterministic version would have done to the form backend whose only
# route is `POST /f/demo`. run_server's `ok` means "started and answered", not
# "answered 200", so an empty POST body returning 400 is a fine liveness proof.
fn stage_post_only() -> [proc] Unit {
  let src := str.join(["import os\n", "from http.server import BaseHTTPRequestHandler, HTTPServer\n", "class H(BaseHTTPRequestHandler):\n", "    def do_POST(self):\n", "        if self.path == \"/f/demo\":\n", "            self.send_response(400); self.end_headers(); self.wfile.write(b'missing field')\n", "        else:\n", "            self.send_response(404); self.end_headers()\n", "    def log_message(self, *a): pass\n", "HTTPServer((\"\", int(os.environ.get(\"PORT\", \"8081\"))), H).serve_forever()\n"], "")
  let __ := sh(str.join(["rm -rf '", py_dir(), "'; mkdir -p '", py_dir(), "'; cat > '", py_dir(), "/svc.py' <<'PYEOF'\n", src, "PYEOF"], ""))
  ()
}

fn test_a_post_only_product_is_probed_with_post() -> [net, io, proc] Result[Unit, Str] {
  let __s := stage_post_only()
  let tool := roles.make_launch_product_tool("/tmp/loom-nomodel-evidence.json", sprint(), "")
  match tool.execute(JObj([])) {
    Err(_) => {
      let __c := clean()
      Err("the tool failed")
    },
    Ok(out) => {
      let ok := field(out, "ok")
      let method := field(out, "method")
      let __c := clean()
      if method == "POST" {
        if ok == "true" {
          Ok(())
        } else {
          Err(str.concat("POSTed but reported the product dead: ", str.slice(field(out, "error"), 0, 120)))
        }
      } else {
        Err(str.join(["a POST-only route was probed with ", method, " -- it will answer 404 and the node will call a live product dead"], ""))
      }
    },
  }
}

fn run_all() -> [net, io, proc] Int {
  let results := [("the language comes from the dir the build wrote into", test_the_language_comes_from_the_dir_the_build_wrote_into()), ("it launches with no arguments at all", test_it_launches_with_no_arguments_at_all()), ("the endpoint comes from the build", test_the_endpoint_comes_from_the_build()), ("a build with no health route still gets a real path", test_a_build_with_no_health_route_still_gets_a_real_path()), ("an empty work dir reports it honestly", test_an_empty_work_dir_reports_it_honestly()), ("a post-only product is probed with POST", test_a_post_only_product_is_probed_with_post())]
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

