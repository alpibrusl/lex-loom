# needs.lex — what a company depends on that only the founder can provide,
# checked before the iteration that needs it. The smallest honest slice of
# docs/needs-ledger.md: no catalogue, no probes, no checklist UI -- just the
# rule that a missing credential parks the company on a board decision that
# names it, instead of being discovered by an agent hours in, wearing the
# agent's name, when the deploy node finds HETZNER_HOST empty.
#
# The manifest declares them: [needs] env = ["DEPLOY_DOMAIN@5", "EMAIL_API_KEY"].
# "VAR@k" means required from iteration k; a bare "VAR" means from the first.
# Values never leave the runner machine: only NAMES travel to the cloud, and
# readiness is computed here, on the machine that holds the environment.

import "std.env" as env

import "std.list" as list

import "std.str" as str

type Need = { name :: Str, required_by :: Int }

fn parse_one(spec :: Str) -> Need
  examples {
    parse_one("DEPLOY_DOMAIN@5") => { name: "DEPLOY_DOMAIN", required_by: 5 },
    parse_one("EMAIL_API_KEY") => { name: "EMAIL_API_KEY", required_by: 1 },
    parse_one(" HETZNER_HOST @ 3 ") => { name: "HETZNER_HOST", required_by: 3 }
  }
{
  let parts := str.split(str.trim(spec), "@")
  let name := match list.head(parts) {
    Some(n) => str.trim(n),
    None => str.trim(spec),
  }
  let last := list.fold(parts, "", fn (acc :: Str, p :: Str) -> Str {
    p
  })
  if list.len(parts) >= 2 {
    match str.to_int(str.trim(last)) {
      Some(i) => { name: name, required_by: i },
      None => { name: name, required_by: 1 },
    }
  } else {
    { name: name, required_by: 1 }
  }
}

fn parse_needs(spec :: Str) -> List[Need]
  examples {
    parse_needs("") => [],
    parse_needs("A@2, B") => [{ name: "A", required_by: 2 }, { name: "B", required_by: 1 }]
  }
{
  list.map(list.filter(str.split(spec, ","), fn (s :: Str) -> Bool {
    not str.is_empty(str.trim(s))
  }), parse_one)
}

# Needs required by iteration k whose variable is unset or empty on this
# machine. Order preserved, so the first one is the one the founder is asked
# about first.
fn missing_at(needs :: List[Need], k :: Int) -> [env] List[Str] {
  list.map(list.filter(needs, fn (n :: Need) -> [env] Bool {
    n.required_by <= k and str.is_empty(str.trim(match env.get(n.name) {
      Some(v) => v,
      None => "",
    }))
  }), fn (n :: Need) -> Str {
    n.name
  })
}

