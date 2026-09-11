# gp1_probe.lex — read a role's tool row and operator preset for the gp1 demo.

import "std.io" as io

import "std.env" as env

import "std.str" as str

import "../src/role_tools" as role_tools

import "../src/manifests" as manifests

fn role() -> [env] Str {
  match env.get("ROLE") {
    Some(r) => r,
    None => "",
  }
}

fn tools_cmd() -> [env, io] Unit {
  io.print(str.join(role_tools.tools_for(role()), ","))
}

fn preset_cmd() -> [env, io] Unit {
  io.print(manifests.preset_name_for_kind(role()))
}

