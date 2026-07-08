# test_security_scan.lex — unit tests for the security_scan tool (#13).
#
# Exercises make_security_scan_tool() directly against seeded work-dir
# content: a file with real, known-dangerous patterns and a clean file that
# must NOT trigger any finding.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.process" as proc

import "lex-schema/json_value" as jv

import "../src/lex_skill" as lexskill

fn seed_dirty(dir :: Str) -> [io, proc] Unit {
  let __mk := proc.run("bash", ["-c", str.concat("mkdir -p ", dir)])
  let __w := io.write(str.concat(dir, "/app.py"), "import os\nAPI_KEY = \"sk-abcd1234efgh5678\"\ndef run(cmd):\n    os.system(cmd)\ndef query(user_id):\n    db.execute(f\"SELECT * FROM users WHERE id={user_id}\")\napp.run(debug=True)\n")
  ()
}

fn seed_clean(dir :: Str) -> [io, proc] Unit {
  let __mk := proc.run("bash", ["-c", str.concat("mkdir -p ", dir)])
  let __w := io.write(str.concat(dir, "/clean.py"), "import os\nAPI_KEY = os.environ.get(\"API_KEY\")\ndef add(a, b):\n    return a + b\n")
  ()
}

fn clear_dirs() -> [proc] Unit {
  let __c := proc.run("bash", ["-c", "rm -rf /tmp/loom-lex-work /tmp/loom-py-work"])
  ()
}

fn findings_of(result :: jv.Json) -> List[jv.Json] {
  match jv.get_field(result, "findings") {
    Some(JList(fs)) => fs,
    _ => [],
  }
}

fn has_severity(findings :: List[jv.Json], sev :: Str) -> Bool {
  list.fold(findings, false, fn (found :: Bool, f :: jv.Json) -> Bool {
    if found {
      true
    } else {
      match jv.get_field(f, "severity") {
        Some(JStr(v)) => v == sev,
        _ => false,
      }
    }
  })
}

fn test_scan_empty_dirs_reports_nothing() -> [io, net, proc] Result[Unit, Str] {
  let __c := clear_dirs()
  let __mk1 := proc.run("bash", ["-c", "mkdir -p /tmp/loom-py-work /tmp/loom-lex-work"])
  let tool := lexskill.make_security_scan_tool()
  match tool.execute(JObj([])) {
    Err(_) => Err("security_scan errored on empty dirs"),
    Ok(result) => if list.is_empty(findings_of(result)) {
      Ok(())
    } else {
      Err("expected zero findings for empty work dirs")
    },
  }
}

fn test_scan_clean_file_reports_nothing() -> [io, net, proc] Result[Unit, Str] {
  let __c := clear_dirs()
  let __s := seed_clean("/tmp/loom-py-work")
  let tool := lexskill.make_security_scan_tool()
  match tool.execute(JObj([])) {
    Err(_) => Err("security_scan errored on a clean file"),
    Ok(result) => if list.is_empty(findings_of(result)) {
      Ok(())
    } else {
      Err("expected zero findings for a clean file using os.environ.get")
    },
  }
}

fn test_scan_dirty_file_reports_all_severities() -> [io, net, proc] Result[Unit, Str] {
  let __c := clear_dirs()
  let __s := seed_dirty("/tmp/loom-py-work")
  let tool := lexskill.make_security_scan_tool()
  match tool.execute(JObj([])) {
    Err(_) => Err("security_scan errored on a dirty file"),
    Ok(result) => {
      let fs := findings_of(result)
      let has_critical := has_severity(fs, "critical")
      let has_high := has_severity(fs, "high")
      let has_medium := has_severity(fs, "medium")
      if has_critical {
        if has_high {
          if has_medium {
            Ok(())
          } else {
            Err("expected a medium finding (debug=True)")
          }
        } else {
          Err("expected a high finding (f-string SQL)")
        }
      } else {
        Err("expected a critical finding (hardcoded secret / os.system)")
      }
    },
  }
}

fn suite() -> [io, net, proc] List[Result[Unit, Str]] {
  [test_scan_empty_dirs_reports_nothing(), test_scan_clean_file_reports_nothing(), test_scan_dirty_file_reports_all_severities()]
}

fn run_all() -> [io, net, proc] Unit {
  let results := suite()
  let __dbg := list.map(results, fn (r :: Result[Unit, Str]) -> [io] Unit {
    match r {
      Ok(_) => (),
      Err(e) => io.print(str.concat("FAIL: ", e)),
    }
  })
  let failures := list.fold(results, 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
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
