# iac_verdict.lex — lex-iac's verdict, as the one line the deploy gate prints.
#
# Three outcomes, and the gate's exit code carries which:
#   IAC_UNAVAILABLE  no verdict to read -- lex-iac did not run or wrote nothing
#   IAC_REFUSED      the plan names an effect the company's grant does not
#   IAC_ADMITTED     admitted, with the plan hash and the audit head
#
# UNAVAILABLE is exit 3 and not exit 1 on purpose: "the gate could not form an
# opinion" must never read as "the gate refused you". A deploy blocked because
# lex-iac is missing is an operator problem; a deploy blocked because the plan
# exceeds its grant is the company's.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "lex-schema/json_value" as jv

fn field_str(j :: jv.Json, name :: Str) -> Str {
  match jv.get_field(j, name) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn refusal_line(r :: jv.Json) -> Str {
  str.join([field_str(r, "effect"), " [", field_str(r, "wall"), "] at ", field_str(r, "address"), ": ", field_str(r, "reason")], "")
}

fn main(path :: Str) -> [fs_read, io] Int {
  match io.read(path) {
    Err(_) => unavailable("lex-iac produced no verdict: cannot read it"),
    Ok(text) => match jv.parse(text) {
      Err(e) => unavailable(str.join(["lex-iac produced no verdict: ", e.message], "")),
      Ok(v) => {
        let refusals := match jv.get_field(v, "refusals") {
          Some(JList(items)) => items,
          _ => [],
        }
        if not list.is_empty(refusals) {
          let __ := io.print(str.concat("IAC_REFUSED ", str.join(list.map(refusals, refusal_line), "; ")))
          1
        } else {
          let __ := io.print(str.join(["IAC_ADMITTED plan=", field_str(v, "plan_sha256"), " head=", field_str(v, "audit_head")], ""))
          0
        }
      },
    },
  }
}

fn unavailable(why :: Str) -> [io] Int {
  let __ := io.print(str.concat("IAC_UNAVAILABLE ", why))
  3
}

