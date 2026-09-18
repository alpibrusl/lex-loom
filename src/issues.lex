# issues.lex — #521: a loom lex company's backlog as TYPED issues (lex-lang
# #949). A work item is no longer a bare goal string with a status a person
# sets: it is an issue with a declared acceptance oracle, and "done" is a
# proof the lex gate records at the head (`IssueVerified` attestation), never
# a column someone flips.
#
# The binding shells out to the `lex` toolchain, exactly like lex_check /
# lex_run do, against a per-company lex-vcs store:
#   create   -> `lex issue create --store <company store> ...`
#   realize  -> `lex publish <sealed source> --intent-issue <id> ...`
#              (every op the publish emits carries the issue in its Intent)
#   verify   -> `lex issue verify <id>` (the oracle, evaluated at the head)
#
# Role -> shape mapping (this slice): cx proposals carry an optional `kind`,
# `example` and `api`; a failing example is a bug (shape failing_example), an
# api entry is a feature (typed_delta), anything else is free_form — the
# explicit, human-closed fallback. The strategist's own "add" goals are
# free_form until refined. Nothing here decides "done": the verdict is the
# toolchain's, and it is recorded on the trail verbatim.
#
# Leaf module: no loom imports, so company.lex / company_runner.lex can use it
# without a cycle.

import "std.str" as str

import "std.list" as list

import "std.env" as env

import "std.process" as proc

import "lex-schema/json_value" as jv

# A backlog proposal as cx (or the strategist) emits it. `api` entries use the
# `lex issue create --api` form `name:(params) -> Ret[:added|changed|removed]`.
type Proposal = { goal :: Str, theme :: Str, kind :: Str, example :: Str, api :: List[Str] }

# ── Shape rule ────────────────────────────────────────────────────────────────
# The role-to-shape mapping for a cx proposal. A concrete failing example is a
# bug report that IS its acceptance; an api entry is a typed delta; else the
# human-closed shape. `kind` is advisory: a "bug" without an example cannot be
# a failing_example (there is nothing to fail), so it falls through.
fn shape_for(p :: Proposal) -> Str
  examples {
    shape_for({ goal: "g", theme: "t", kind: "bug", example: "submit(\"\") => Err(\"empty\")", api: [] }) => "failing_example",
    shape_for({ goal: "g", theme: "t", kind: "feature", example: "", api: ["export_csv:(id :: Str) -> Str:added"] }) => "typed_delta",
    shape_for({ goal: "g", theme: "t", kind: "bug", example: "", api: [] }) => "free_form",
    shape_for({ goal: "g", theme: "t", kind: "", example: "", api: [] }) => "free_form"
  }
{
  if not str.is_empty(str.trim(p.example)) {
    "failing_example"
  } else {
    if list.is_empty(p.api) {
      "free_form"
    } else {
      "typed_delta"
    }
  }
}

# The toolchain's verdict on an issue at the current head, plus the two ways
# a verdict can be missing: the oracle can't run for this head (e.g. a
# multi-module package, lex-lang#942) or the toolchain call itself failed.
# (Declared here, after shape_for: `lex fmt` drops a comment block that
# directly follows a sum type, lex-lang#755.)
type IssueVerdict = IssueVerified | IssueFailed(Str) | IssueInconclusive(Str) | IssueUnverifiable(Str)

fn plain_proposal(goal :: Str) -> Proposal
  examples {
    plain_proposal("g") => { goal: "g", theme: "", kind: "", example: "", api: [] }
  }
{
  { goal: goal, theme: "", kind: "", example: "", api: [] }
}

# ── Proposal parsing ─────────────────────────────────────────────────────────
# Same contract as company.parse_backlog_proposals (#442): the LAST ```json
# fence wins, malformed yields nothing, empty goals are dropped, at most three
# survive. The typed fields are optional; a proposal without them is exactly
# the old `{goal, theme}` shape.
fn parse_proposals(content :: Str) -> List[Proposal]
  examples {
    parse_proposals("no fence") => [],
    parse_proposals("```json\n{\"backlog\":[{\"goal\":\"Add CSV export\",\"theme\":\"export\"}]}\n```") => [{ goal: "Add CSV export", theme: "export", kind: "", example: "", api: [] }],
    parse_proposals("```json\n{\"backlog\":[{\"goal\":\"Reject empty submissions\",\"theme\":\"validation\",\"kind\":\"bug\",\"example\":\"submit(\\\"\\\") => Err(\\\"empty\\\")\"}]}\n```") => [{ goal: "Reject empty submissions", theme: "validation", kind: "bug", example: "submit(\"\") => Err(\"empty\")", api: [] }],
    parse_proposals("```json\n{\"backlog\":[{\"goal\":\"a\"},{\"goal\":\"b\"},{\"goal\":\"c\"},{\"goal\":\"d\"}]}\n```") => [{ goal: "a", theme: "", kind: "", example: "", api: [] }, { goal: "b", theme: "", kind: "", example: "", api: [] }, { goal: "c", theme: "", kind: "", example: "", api: [] }]
  }
{
  let parts := str.split(content, "```json")
  if list.len(parts) < 2 {
    []
  } else {
    let last := list.fold(parts, "", fn (_acc :: Str, p :: Str) -> Str {
      p
    })
    match list.head(str.split(last, "```")) {
      None => [],
      Some(block) => match jv.parse(str.trim(block)) {
        Err(_) => [],
        Ok(j) => match jv.get_field(j, "backlog") {
          Some(JList(items)) => list.fold(items, [], fn (acc :: List[Proposal], it :: jv.Json) -> List[Proposal] {
            let g := str.trim(field_str(it, "goal"))
            if str.is_empty(g) or list.len(acc) >= 3 {
              acc
            } else {
              list.concat(acc, [{ goal: g, theme: field_str(it, "theme"), kind: field_str(it, "kind"), example: str.trim(field_str(it, "example")), api: field_strs(it, "api") }])
            }
          }),
          _ => [],
        },
      },
    }
  }
}

fn field_str(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

fn field_strs(j :: jv.Json, key :: Str) -> List[Str] {
  match jv.get_field(j, key) {
    Some(JList(items)) => list.fold(items, [], fn (acc :: List[Str], it :: jv.Json) -> List[Str] {
      match it {
        JStr(s) => if str.is_empty(str.trim(s)) {
          acc
        } else {
          list.concat(acc, [str.trim(s)])
        },
        _ => acc,
      }
    }),
    _ => [],
  }
}

# ── Toolchain plumbing ───────────────────────────────────────────────────────
# The company's lex-vcs store: beside its synced product under LOOM_WORKSPACE
# (bootstrap exports it for every company process). Unset means no company
# is running here — tests and ad-hoc `lex run` — so nothing is typed and
# nothing is written outside a workspace. A portfolio track id contains "/",
# which is a path separator — flattened.
fn store_dir(company_id :: Str) -> [env] Option[Str] {
  match env.get("LOOM_WORKSPACE") {
    None => None,
    Some(w) => if str.is_empty(str.trim(w)) {
      None
    } else {
      Some(str.join([str.trim(w), "/", str.replace(company_id, "/", "_"), "/.lex-store"], ""))
    },
  }
}

# Single-quote a value for `bash -c`: the only byte that needs care is `'`.
fn sh_quote(s :: Str) -> Str
  examples {
    sh_quote("plain") => "'plain'",
    sh_quote("it's") => "'it'\\''s'"
  }
{
  str.join(["'", str.replace(s, "'", "'\\''"), "'"], "")
}

# `lex` as loom's other tools resolve it (`${LEX:-lex}`), through bash so the
# same PATH/env conventions apply.
fn run_lex(args :: Str) -> [proc] Result[(Str, Bool), Str] {
  let cmd := str.join(["${LEX:-lex} ", args, " 2>&1; rc=$?; echo; echo \"##EXIT:$rc\""], "")
  match proc.run("bash", ["-c", cmd]) {
    Err(m) => Err(str.concat("lex could not run: ", m)),
    Ok(r) => {
      let out := str.concat(r.stdout, r.stderr)
      match list.head(str.split(out, "##EXIT:")) {
        None => Err("lex produced no output"),
        Some(body) => Ok((str.trim(body), str.contains(out, "##EXIT:0"))),
      }
    },
  }
}

# The `data` half of a `lex --output json` envelope (or the whole value when
# the output isn't an envelope).
fn json_data(out :: Str) -> Option[jv.Json] {
  match jv.parse(out) {
    Err(_) => None,
    Ok(j) => match jv.get_field(j, "data") {
      Some(d) => Some(d),
      None => Some(j),
    },
  }
}

fn is_hex_id(s :: Str) -> Bool
  examples {
    is_hex_id("459c0af1ab1bc6cbcad3fa1d3f139ba99546781f296e3be002e1bea07c0d730f") => true,
    is_hex_id("error: no store") => false,
    is_hex_id("") => false
  }
{
  str.len(s) == 64 and list.is_empty(list.filter(list.range(0, 64), fn (i :: Int) -> Bool {
    not str.contains("0123456789abcdef", str.char_at(s, i))
  }))
}

# ── The three operations ─────────────────────────────────────────────────────
# Create the typed issue for a proposal in the company's store; `project` is
# the company id so the hub's derived board groups a company's work. Returns
# the content-addressed issue id — the same proposal twice yields the same id,
# so re-creating is harmless.
fn create_issue(store :: Str, company_id :: Str, p :: Proposal) -> [proc] Result[Str, Str] {
  let shape := shape_for(p)
  let base := str.join(["issue create --store ", sh_quote(store), " --title ", sh_quote(p.goal), " --shape ", shape, " --project ", sh_quote(company_id)], "")
  let with_example := if shape == "failing_example" {
    str.join([base, " --example ", sh_quote(p.example)], "")
  } else {
    base
  }
  let args := if shape == "typed_delta" {
    list.fold(p.api, with_example, fn (acc :: Str, a :: Str) -> Str {
      str.join([acc, " --api ", sh_quote(a)], "")
    })
  } else {
    with_example
  }
  match run_lex(args) {
    Err(m) => Err(m),
    Ok((out, ok)) => {
      let first := match list.head(str.split(out, "\n")) {
        Some(l) => str.trim(l),
        None => "",
      }
      if ok and is_hex_id(first) {
        Ok(first)
      } else {
        Err(str.slice(out, 0, 400))
      }
    },
  }
}

# The sealed build's primary source file: the non-test .lex files in the work
# dir, preferring main.lex then server.lex, else the first by name. A build
# with several source modules is published by its primary file only; the
# oracle then reports the head as unverifiable if imports can't resolve
# (lex-lang#942 tracks multi-module verification). `modules` says how many
# there were, so the trail shows when that limit applied.
fn primary_source(work_dir :: Str) -> [proc] Result[(Str, Int), Str] {
  let cmd := str.join(["cd ", sh_quote(work_dir), " && ls -1 *.lex 2>/dev/null | grep -v -E '(^test_|_test\\.lex$)'"], "")
  match proc.run("bash", ["-c", cmd]) {
    Err(m) => Err(str.concat("listing the work dir: ", m)),
    Ok(r) => {
      let names := list.filter(str.split(str.trim(r.stdout), "\n"), fn (n :: Str) -> Bool {
        not str.is_empty(str.trim(n))
      })
      if list.is_empty(names) {
        Err("no source .lex file in the work dir")
      } else {
        let pick := if has_name(names, "main.lex") {
          "main.lex"
        } else {
          if has_name(names, "server.lex") {
            "server.lex"
          } else {
            match list.head(names) {
              Some(n) => n,
              None => "",
            }
          }
        }
        Ok((str.join([work_dir, "/", pick], ""), list.len(names)))
      }
    },
  }
}

fn has_name(names :: List[Str], want :: Str) -> Bool
  examples {
    has_name(["a.lex", "main.lex"], "main.lex") => true,
    has_name(["a.lex"], "main.lex") => false
  }
{
  not list.is_empty(list.filter(names, fn (n :: Str) -> Bool {
    n == want
  }))
}

# Publish the sealed source as the realization of `issue_id`: the Intent
# carries the goal, the sprint as session and the issue, so every op links
# back to the work item (provenance the derived board reads as "in
# progress"). Returns the new head op.
fn realize(store :: Str, issue_id :: Str, goal :: Str, sprint_id :: Str, src_file :: Str) -> [proc] Result[Str, Str] {
  let args := str.join(["--output json publish ", sh_quote(src_file), " --store ", sh_quote(store), " --activate --intent-prompt ", sh_quote(goal), " --intent-session ", sh_quote(sprint_id), " --intent-issue ", sh_quote(issue_id)], "")
  match run_lex(args) {
    Err(m) => Err(m),
    Ok((out, ok)) => if ok {
      match json_data(out) {
        Some(d) => match jv.get_field(d, "head_op") {
          Some(JStr(h)) => Ok(h),
          _ => Err(str.concat("publish returned no head_op: ", str.slice(out, 0, 300))),
        },
        None => Err(str.concat("publish output is not JSON: ", str.slice(out, 0, 300))),
      }
    } else {
      Err(str.slice(out, 0, 400))
    },
  }
}

# Evaluate the issue's oracle at the store's head. The toolchain records the
# attestation itself; this only reads the verdict back.
fn verify(store :: Str, issue_id :: Str) -> [proc] IssueVerdict {
  let args := str.join(["--output json issue verify ", sh_quote(issue_id), " --store ", sh_quote(store)], "")
  match run_lex(args) {
    Err(m) => IssueUnverifiable(m),
    Ok((out, _ok)) => match json_data(out) {
      None => IssueUnverifiable(str.slice(out, 0, 300)),
      Some(d) => {
        let detail := field_str(d, "detail")
        match field_str(d, "verdict") {
          "verified" => IssueVerified,
          "failed" => IssueFailed(detail),
          "inconclusive" => IssueInconclusive(detail),
          _ => IssueUnverifiable(str.slice(out, 0, 300)),
        }
      },
    },
  }
}

fn verdict_name(v :: IssueVerdict) -> Str
  examples {
    verdict_name(IssueVerified) => "verified",
    verdict_name(IssueFailed("x")) => "failed",
    verdict_name(IssueInconclusive("x")) => "inconclusive",
    verdict_name(IssueUnverifiable("x")) => "unverifiable"
  }
{
  match v {
    IssueVerified => "verified",
    IssueFailed(_) => "failed",
    IssueInconclusive(_) => "inconclusive",
    IssueUnverifiable(_) => "unverifiable",
  }
}

fn verdict_detail(v :: IssueVerdict) -> Str {
  match v {
    IssueVerified => "",
    IssueFailed(d) => d,
    IssueInconclusive(d) => d,
    IssueUnverifiable(d) => d,
  }
}

