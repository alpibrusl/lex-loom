# ld1_probe.lex — drive the lex_docs tool and the role grants offline, the way
# a node would: build the real Tool, call its handler, print what came back.

import "std.io" as io

import "std.env" as env

import "std.str" as str

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-llm/src/tool" as t

import "../src/lex_skill" as lexskill

import "../src/roles" as roles

fn get_env(key :: Str, fallback :: Str) -> [env] Str {
  match env.get(key) {
    Some(v) => v,
    None => fallback,
  }
}

# What each role really ends up holding: the policy row, after the role's own
# operator preset has had its say (roles.tools_of_role does both).
fn grants_cmd() -> [env, io] Unit {
  let __r := list.map(["build", "test_author", "qa", "py_build"], fn (role :: Str) -> [env, io] Unit {
    let names := list.map(roles.tools_of_role(role, "", "ld1"), fn (tool :: t.Tool) -> Str {
      tool.name
    })
    io.print(str.join([role, ": ", str.join(names, ", ")], ""))
  })
  ()
}

fn docs_cmd() -> [env, io, net, proc] Unit {
  let package := get_env("PACKAGE", "lex-web")
  let module := get_env("MODULE", "")
  let args := JObj([("package", JStr(package)), ("module", JStr(module))])
  let tool := lexskill.make_lex_docs_tool()
  match tool.execute(args) {
    Err(_) => io.print("tool call failed"),
    Ok(j) => match jv.get_field(j, "docs") {
      Some(JStr(v)) => io.print(v),
      _ => io.print("no docs field"),
    },
  }
}

