# deploy_plan.lex — the deploy's plan, Terraform-plan-shaped, for lex-iac to
# gate.
#
# loom's Hetzner deploy is rsync + docker on one host. Before it runs, what it
# is ABOUT TO DO is written down as resource changes under the provider
# `registry.terraform.io/alpibrusl/loom`, so `lex-iac check` can hold it
# against the company's grant with the same mechanics it applies to a real
# Terraform plan: every effect named, creates needing their verb in the grant,
# deletes and replaces of the host refused unless granted, the provider's
# identity checked, the verdict on a hash-chained audit log.
#
# DETERMINISTIC CODE, NEVER MODEL OUTPUT. The same inputs give the same JSON,
# so the gate reasons about what the tool WILL do rather than about what an
# agent said it would.
#
# Ported from deploy_plan.py (lex-loom#512). Flags are parsed by
# bin/deploy-plan.sh, which is what every caller invokes; this takes the five
# values positionally.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.regex" as re

import "std.int" as int

import "lex-schema/json_value" as jv

fn provider() -> Str {
  "registry.terraform.io/alpibrusl/loom"
}

# A resource address has to be stable and safe to read back, so anything that
# is not [a-z0-9] collapses to an underscore -- and a name that collapses to
# nothing becomes "x" rather than an empty address.
fn slug(s :: Str) -> Str {
  let lowered := str.to_lower(s)
  let subbed := match re.compile("[^a-z0-9]+") {
    Err(_) => lowered,
    Ok(r) => re.replace_all(r, lowered, "_"),
  }
  let trimmed := trim_underscores(subbed)
  if str.is_empty(trimmed) {
    "x"
  } else {
    trimmed
  }
}

fn trim_underscores(s :: Str) -> Str {
  let front := if str.starts_with(s, "_") {
    trim_underscores(str.slice(s, 1, str.len(s)))
  } else {
    s
  }
  if str.ends_with(front, "_") and str.len(front) > 0 {
    trim_underscores(str.slice(front, 0, str.len(front) - 1))
  } else {
    front
  }
}

fn change(address :: Str, kind :: Str, name :: Str, actions :: List[Str], before :: jv.Json, after :: jv.Json) -> jv.Json {
  JObj([("address", JStr(address)), ("mode", JStr("managed")), ("type", JStr(kind)), ("name", JStr(name)), ("provider_name", JStr(provider())), ("change", JObj([("actions", JList(list.map(actions, fn (a :: Str) -> jv.Json {
    JStr(a)
  }))), ("before", before), ("after", after)]))])
}

fn plan_json(host :: Str, service :: Str, port :: Int, domain :: Str, release :: Str) -> jv.Json {
  let hostslug := slug(host)
  let base := [change(str.concat("hetzner_host.", hostslug), "hetzner_host", hostslug, ["update"], JObj([("host", JStr(host))]), JObj([("host", JStr(host)), ("release", JStr(release))])), change(str.concat("docker_compose.", slug(service)), "docker_compose", slug(service), ["create"], JNull, JObj([("service", JStr(service)), ("host", JStr(host))])), change(str.join(["host_port.p", int.to_str(port)], ""), "host_port", str.concat("p", int.to_str(port)), ["create"], JNull, JObj([("port", JInt(port)), ("host", JStr(host))]))]
  let changes := if str.is_empty(domain) {
    base
  } else {
    list.concat(base, [change(str.concat("caddy_site.", slug(domain)), "caddy_site", slug(domain), ["create"], JNull, JObj([("domain", JStr(domain)), ("upstream_port", JInt(port))]))])
  }
  JObj([("format_version", JStr("1.2")), ("terraform_version", JStr("loom-deploy")), ("resource_changes", JList(changes))])
}

fn main(host :: Str, service :: Str, port_s :: Str, domain :: Str, release :: Str) -> [io] Int {
  match str.to_int(port_s) {
    None => {
      let __ := io.print("deploy_plan: --port must be an integer")
      2
    },
    Some(port) => {
      let __ := io.print(jv.stringify(plan_json(host, service, port, domain, release)))
      0
    },
  }
}

