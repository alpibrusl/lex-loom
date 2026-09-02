# test_ts_path.lex — the Node/TS golden path's grounded plumbing (#92).
#
# The path is only real when its gates are: these tests prove the
# `spec compiles` gate for ts_build actually runs Node's syntax check
# against the files the node wrote (pass on real TS, fail on a syntax
# error, fail on an empty work dir — never a silent allow), and that the
# roster/tooling rows agree with the rest of the vocabulary.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.process" as proc

import "../src/agent/runner" as runner

import "../src/role_tools" as rt

import "../src/role_kinds" as role_kinds

import "../src/lex_skill" as lexskill

import "lex-schema/json_value" as jv

fn seed(sprint :: Str, filename :: Str, code :: Str) -> [io, proc] Unit {
  let dir := lexskill.ts_work_dir(sprint)
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf ", dir, "; mkdir -p ", dir], "")])
  let __w := io.write(str.join([dir, "/", filename], ""), code)
  ()
}

fn test_ts_compiles_gate_passes_on_real_ts() -> [io, proc] Result[Unit, Str] {
  let sprint := "t-tspath-good"
  let __s := seed(sprint, "app.ts", "const x: number = 1;\nexport function double(n: number): number {\n  return n * 2;\n}\nconsole.log(x);\n")
  match runner.verify_build_compiles("ts_build", sprint) {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("expected real TS to pass the compiles gate, got: ", e)),
  }
}

fn test_ts_compiles_gate_fails_on_syntax_error() -> [io, proc] Result[Unit, Str] {
  let sprint := "t-tspath-bad"
  let __s := seed(sprint, "app.ts", "const x: number = ;\nfunction {{\n")
  match runner.verify_build_compiles("ts_build", sprint) {
    Ok(_) => Err("expected a syntax error to fail the compiles gate"),
    Err(e) => if str.contains(e, "COMPILE_FAIL") {
      Ok(())
    } else {
      Err(str.concat("failed, but not with COMPILE_FAIL: ", e))
    },
  }
}

fn test_ts_compiles_gate_fails_on_empty_work_dir() -> [io, proc] Result[Unit, Str] {
  let sprint := "t-tspath-empty"
  let dir := lexskill.ts_work_dir(sprint)
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf ", dir, "; mkdir -p ", dir], "")])
  match runner.verify_build_compiles("ts_build", sprint) {
    Ok(_) => Err("expected an empty work dir to fail (prose, not code)"),
    Err(e) => if str.contains(e, "no ts source files") {
      Ok(())
    } else {
      Err(str.concat("failed, but not with the no-source message: ", e))
    },
  }
}

fn test_ts_roster_rows_agree() -> Result[Unit, Str] {
  let has := fn (xs :: List[Str], x :: Str) -> Bool {
    list.fold(xs, false, fn (found :: Bool, e :: Str) -> Bool {
      found or e == x
    })
  }
  if rt.tools_for("ts_build") == ["ts_check"] {
    if rt.tools_for("ts_qa") == ["run_node_code"] {
      if has(role_kinds.known_kinds(), "ts_build") {
        if has(role_kinds.known_kinds(), "ts_qa") {
          Ok(())
        } else {
          Err("ts_qa missing from role_kinds.known_kinds")
        }
      } else {
        Err("ts_build missing from role_kinds.known_kinds")
      }
    } else {
      Err("ts_qa should wield exactly [run_node_code]")
    }
  } else {
    Err("ts_build should wield exactly [ts_check]")
  }
}

# ── ts_check file-type dispatch (#92 web-pwa) ────────────────────────────────
# The one build tool writes the whole project: code is syntax-checked, JSON
# manifests are parse-checked, static assets are stored — and a bad file of
# any checkable type is refused, never silently accepted.
fn tool_result_field(r :: jv.Json, key :: Str) -> Str {
  match jv.get_field(r, key) {
    Some(JStr(v)) => v,
    _ => "",
  }
}

fn check_tool(filename :: Str, code :: Str) -> [env, io, net, proc] Result[(Str, Str), Str] {
  let tool := lexskill.make_ts_check_tool("/tmp/loom-evidence-test.json", "t-tspath-dispatch")
  match tool.execute(JObj([("filename", JStr(filename)), ("code", JStr(code))])) {
    Err(_) => Err("ts_check errored"),
    Ok(r) => Ok((tool_result_field(r, "ok"), tool_result_field(r, "output"))),
  }
}

fn test_ts_check_stores_static_assets() -> [env, io, net, proc] Result[Unit, Str] {
  match check_tool("public/styles.css", "body { margin: 0; }") {
    Err(e) => Err(e),
    Ok((ok, output)) => if ok == "true" {
      if output == "stored" {
        Ok(())
      } else {
        Err(str.concat("expected output 'stored' for css, got: ", output))
      }
    } else {
      Err("css asset should be accepted as stored")
    },
  }
}

fn test_ts_check_parse_checks_manifest() -> [env, io, net, proc] Result[Unit, Str] {
  match check_tool("public/manifest.webmanifest", "{\"name\": \"x\", }") {
    Err(e) => Err(e),
    Ok((ok, _)) => if ok == "false" {
      match check_tool("public/manifest.webmanifest", "{\"name\": \"x\"}") {
        Err(e) => Err(e),
        Ok((ok2, _)) => if ok2 == "true" {
          Ok(())
        } else {
          Err("valid manifest JSON should pass")
        },
      }
    } else {
      Err("trailing-comma manifest should fail JSON.parse")
    },
  }
}

fn test_ts_check_still_refuses_bad_ts() -> [env, io, net, proc] Result[Unit, Str] {
  match check_tool("bad.ts", "const x: number = ;") {
    Err(e) => Err(e),
    Ok((ok, _)) => if ok == "false" {
      Ok(())
    } else {
      Err("bad TS should still be refused")
    },
  }
}

fn test_ts_check_refuses_dotdot_filename() -> [env, io, net, proc] Result[Unit, Str] {
  match check_tool("../escape.ts", "const x = 1;") {
    Err(e) => Err(e),
    Ok((ok, output)) => if ok == "false" {
      if str.contains(output, "plain relative path") {
        Ok(())
      } else {
        Err(str.concat("refused, but with the wrong message: ", output))
      }
    } else {
      Err("a '..' filename must be refused")
    },
  }
}

# ── The sprint-workdir ↔ workspace bridge (#256) ─────────────────────────────
# For a company sprint ("<company>/iter-N") whose workspace carries the
# bootstrap-install marker, the ts_build compile gate must run the
# workspace's real `npm run build` with the sprint's files overlaid — and
# must refuse (not skip) when the marker is present but the install is
# gone. The fake workspace's build script proves the overlay is real: it
# fails unless App.tsx contains the SPRINT's edit, so a gate that built
# the pristine workspace copy would fail the pass-case below.
fn seed_bridge_ws(ws_root :: Str, company :: Str) -> [io, proc] Unit {
  let dir := str.join([ws_root, "/", company], "")
  let __mk := proc.run("bash", ["-c", str.join(["rm -rf ", ws_root, "; mkdir -p ", dir, "/node_modules"], "")])
  let __m := io.write(str.join([dir, "/.loom-installed"], ""), "test\n")
  let __p := io.write(str.join([dir, "/package.json"], ""), "{\"scripts\": {\"build\": \"node build-check.js\"}}\n")
  let __c := io.write(str.join([dir, "/build-check.js"], ""), "const fs = require('node:fs');\nconst s = fs.readFileSync('App.tsx', 'utf8');\nif (!s.includes('SPRINT_EDIT')) { console.error('overlay missing: built the workspace copy, not the sprint files'); process.exit(1); }\nif (s.includes('BROKEN')) { console.error('metro-sim: JSX parse error in App.tsx'); process.exit(1); }\nprocess.exit(0);\n")
  let __a := io.write(str.join([dir, "/App.tsx"], ""), "// workspace baseline\n")
  ()
}

fn test_bridge_gate_passes_and_overlays_sprint_files() -> [io, proc] Result[Unit, Str] {
  let ws := "/tmp/loom-bi2-bridge-ws"
  let sprint := "bi2co/iter-1"
  let __ws := seed_bridge_ws(ws, "bi2co")
  let __s := seed(sprint, "App.tsx", "// SPRINT_EDIT\nexport default function App() { return null; }\n")
  match runner.verify_compiles_at(ws, "ts_build", sprint) {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("expected the bridged gate to pass on a good sprint .tsx (and .tsx alone to count as source), got: ", e)),
  }
}

fn test_bridge_gate_fails_on_broken_app_build() -> [io, proc] Result[Unit, Str] {
  let ws := "/tmp/loom-bi2-bridge-ws"
  let sprint := "bi2co/iter-2"
  let __ws := seed_bridge_ws(ws, "bi2co")
  let __s := seed(sprint, "App.tsx", "// SPRINT_EDIT BROKEN\n")
  match runner.verify_compiles_at(ws, "ts_build", sprint) {
    Ok(_) => Err("expected the workspace build failure to fail the gate"),
    Err(e) => if str.contains(e, "metro-sim") {
      Ok(())
    } else {
      Err(str.concat("failed, but without the build script's output: ", e))
    },
  }
}

fn test_bridge_refuses_marker_without_install() -> [io, proc] Result[Unit, Str] {
  let ws := "/tmp/loom-bi2-bridge-ws"
  let sprint := "bi2co/iter-3"
  let __ws := seed_bridge_ws(ws, "bi2co")
  let __rm := proc.run("bash", ["-c", str.join(["rm -rf ", ws, "/bi2co/node_modules"], "")])
  let __s := seed(sprint, "App.tsx", "// SPRINT_EDIT\n")
  match runner.verify_compiles_at(ws, "ts_build", sprint) {
    Ok(_) => Err("expected a marker with no node_modules to REFUSE, not silently skip"),
    Err(e) => if str.contains(e, "no node_modules") {
      Ok(())
    } else {
      Err(str.concat("refused, but with the wrong message: ", e))
    },
  }
}

fn test_bridge_skipped_without_marker() -> [io, proc] Result[Unit, Str] {
  let ws := "/tmp/loom-bi2-bridge-ws"
  let sprint := "bi2co/iter-4"
  let __ws := seed_bridge_ws(ws, "bi2co")
  let __rm := proc.run("bash", ["-c", str.join(["rm -f ", ws, "/bi2co/.loom-installed"], "")])
  let __s := seed(sprint, "app.ts", "const x: number = 1;\nconsole.log(x);\n")
  match runner.verify_compiles_at(ws, "ts_build", sprint) {
    Ok(_) => Ok(()),
    Err(e) => Err(str.concat("no marker means no bridge — syntax-only gate should pass: ", e)),
  }
}

fn run_all() -> [env, io, net, proc] Int {
  let results := [("ts compiles gate passes on real ts", test_ts_compiles_gate_passes_on_real_ts()), ("ts compiles gate fails on syntax error", test_ts_compiles_gate_fails_on_syntax_error()), ("ts compiles gate fails on empty work dir", test_ts_compiles_gate_fails_on_empty_work_dir()), ("ts roster rows agree", test_ts_roster_rows_agree()), ("ts_check stores static assets", test_ts_check_stores_static_assets()), ("ts_check parse-checks manifest", test_ts_check_parse_checks_manifest()), ("ts_check still refuses bad ts", test_ts_check_still_refuses_bad_ts()), ("ts_check refuses dotdot filename", test_ts_check_refuses_dotdot_filename()), ("bridge gate passes and overlays sprint files", test_bridge_gate_passes_and_overlays_sprint_files()), ("bridge gate fails on broken app build", test_bridge_gate_fails_on_broken_app_build()), ("bridge refuses marker without install", test_bridge_refuses_marker_without_install()), ("bridge skipped without marker", test_bridge_skipped_without_marker())]
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

