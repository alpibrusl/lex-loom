# test_verify.lex — pure-logic tests for the sprint verifier (#47).
# The end-to-end re-derivation (tamper detection) is exercised live; here we lock
# down the artifact-hash extraction and report formatting.

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "../src/verify" as verify

fn test_extracts_artifact_hash() -> Result[Unit, Str] {
  let h := verify.artifact_hash("{\"node\":\"build\",\"artifact\":\"abc123\"}")
  if h == "abc123" {
    Ok(())
  } else {
    Err(str.concat("expected abc123, got ", h))
  }
}

fn test_missing_artifact_field() -> Result[Unit, Str] {
  if str.is_empty(verify.artifact_hash("{\"node\":\"build\"}")) {
    Ok(())
  } else {
    Err("expected empty hash when artifact field absent")
  }
}

fn test_bad_json() -> Result[Unit, Str] {
  if str.is_empty(verify.artifact_hash("not json")) {
    Ok(())
  } else {
    Err("expected empty hash on unparseable data")
  }
}

fn test_report_verified() -> Result[Unit, Str] {
  let j := verify.report_json({ sprint_id: "s1", checked: 3, intact: 3, mismatched: 0, missing: 0, verified: true })
  if str.contains(j, "\"verdict\":\"verified\"") {
    Ok(())
  } else {
    Err(str.concat("expected verified verdict, got ", j))
  }
}

fn test_report_failed() -> Result[Unit, Str] {
  let j := verify.report_json({ sprint_id: "s1", checked: 3, intact: 2, mismatched: 1, missing: 0, verified: false })
  if str.contains(j, "\"verdict\":\"FAILED\"") {
    Ok(())
  } else {
    Err(str.concat("expected FAILED verdict, got ", j))
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_extracts_artifact_hash(), test_missing_artifact_field(), test_bad_json(), test_report_verified(), test_report_failed()]
}

fn run_all() -> Unit {
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

