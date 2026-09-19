# test_lex_check_refuses_empty.lex — lex-loom#525: lex_check refuses empty
# code. Live failure: after a bounce the build called lex_check with "" for
# main.lex; `lex check` passes an empty file, the build was accepted, and
# launch found no entry point — four denials and another bounce.
#
#   1. empty / whitespace-only code is refused BEFORE anything is written
#      (the file on disk is untouched);
#   2. real code still writes and checks as before;
#   3. delete:true with no code still deletes (the one legitimate empty call).

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.process" as proc

import "lex-schema/json_value" as jv

import "../src/lex_skill" as lexskill

fn sprint() -> Str {
  "lexcheck-refuses-empty"
}

fn work_dir() -> Str {
  str.join(["/tmp/loom-lex-work-", sprint()], "")
}

fn clean() -> [proc] Unit {
  let __ := proc.run("bash", ["-c", str.join(["rm -rf '", work_dir(), "'"], "")])
  ()
}

fn ran_ok(out :: jv.Json) -> Bool {
  match jv.get_field(out, "ok") {
    Some(JStr(v)) => v == "true",
    _ => false,
  }
}

fn output_of(out :: jv.Json) -> Str {
  match jv.get_field(out, "output") {
    Some(JStr(v)) => v,
    _ => "",
  }
}

fn file_size(name :: Str) -> [proc] Int {
  match proc.run("bash", ["-c", str.join(["wc -c < '", work_dir(), "/", name, "' 2>/dev/null || echo -1"], "")]) {
    Err(_) => -1,
    Ok(r) => match str.to_int(str.trim(r.stdout)) {
      Some(n) => n,
      None => -1,
    },
  }
}

fn test_empty_code_is_refused_and_nothing_is_written() -> [net, io, proc] Result[Unit, Str] {
  let __c := clean()
  let check := lexskill.make_lex_check_tool("", sprint())
  match check.execute(JObj([("filename", JStr("main.lex")), ("code", JStr("   \n"))])) {
    Err(_) => Err("lex_check tool call failed"),
    Ok(out) => {
      let txt := output_of(out)
      let size := file_size("main.lex")
      let __c2 := clean()
      if ran_ok(out) {
        Err("empty code reported ok")
      } else {
        if str.contains(txt, "refused") and str.contains(txt, "empty") and size == -1 {
          Ok(())
        } else {
          Err(str.join(["expected a refusal with no file written; output=", str.slice(txt, 0, 120), " size=", if size == -1 {
            "none"
          } else {
            "written"
          }], ""))
        }
      }
    },
  }
}

fn test_real_code_still_writes_and_checks() -> [net, io, proc] Result[Unit, Str] {
  let __c := clean()
  let check := lexskill.make_lex_check_tool("", sprint())
  match check.execute(JObj([("filename", JStr("ok.lex")), ("code", JStr("fn one() -> Int {\n  1\n}\n"))])) {
    Err(_) => Err("lex_check tool call failed"),
    Ok(out) => {
      let size := file_size("ok.lex")
      let __c2 := clean()
      if ran_ok(out) and size > 0 {
        Ok(())
      } else {
        Err(str.concat("real code did not write+check: ", str.slice(output_of(out), 0, 160)))
      }
    },
  }
}

fn test_delete_with_no_code_still_deletes() -> [net, io, proc] Result[Unit, Str] {
  let __c := clean()
  let check := lexskill.make_lex_check_tool("", sprint())
  match check.execute(JObj([("filename", JStr("probe.lex")), ("code", JStr("fn p() -> Int {\n  2\n}\n"))])) {
    Err(_) => Err("lex_check tool call failed"),
    Ok(_) => match check.execute(JObj([("filename", JStr("probe.lex")), ("code", JStr("")), ("delete", JBool(true))])) {
      Err(_) => Err("delete call failed"),
      Ok(out) => {
        let size := file_size("probe.lex")
        let __c2 := clean()
        if ran_ok(out) and size == -1 {
          Ok(())
        } else {
          Err("delete:true with empty code was refused or did not delete")
        }
      },
    },
  }
}

fn suite() -> [net, io, proc] List[Result[Unit, Str]] {
  [test_empty_code_is_refused_and_nothing_is_written(), test_real_code_still_writes_and_checks(), test_delete_with_no_code_still_deletes()]
}

fn run_all() -> [net, io, proc] Unit {
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
    io.print("ok   3 lex_check refuses-empty tests")
  } else {
    let __force_fail := 1 / 0
    ()
  }
}

