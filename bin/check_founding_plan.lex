# check_founding_plan.lex — a founding plan before a person is asked to
# approve it.
#
# The first deliverable of a company whose manifest says [policy] founding =
# true: the idea, a monthly budget in euros, the resources it wants, the
# actions only the founder can take, a success metric and a timeline.
#
# The Total row is RECOMPUTED from the item rows. A founder approving a budget
# is approving a number, and a number the plan pasted rather than added is the
# one thing in the document nobody else will check.
#
# Ported from check_founding_plan.py (lex-loom#512).

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.fs" as fs

import "./md" as md

type Section = { attr :: Str, heading :: Str, kind :: Str }

fn sections() -> List[Section] {
  [{ attr: "checkable:idea", heading: "## Idea", kind: "text" }, { attr: "checkable:budget", heading: "## Budget", kind: "budget" }, { attr: "checkable:resources", heading: "## Resources", kind: "bullets" }, { attr: "checkable:human-actions", heading: "## Human actions", kind: "bullets" }, { attr: "checkable:success-metric", heading: "## Success metric", kind: "text" }, { attr: "checkable:timeline", heading: "## Timeline", kind: "text" }]
}

type Budget = { why :: Str, total :: Int }

# Cents throughout. The tolerance is 50 cents, matching the Python's 0.5 euro,
# so rounding in a plan is forgiven and a wrong total is not.
fn budget_of(body :: Str) -> Budget {
  let rows := md.table_rows(body)
  if list.len(rows) < 2 {
    { why: "needs a markdown table: | Item | EUR / month | Notes |, at least one item row and a Total row", total: 0 }
  } else {
    let data := list.tail(rows)
    let items := list.fold(data, [], fn (acc :: List[Int], r :: Str) -> List[Int] {
      let cs := md.cells(r)
      if list.len(cs) < 2 {
        acc
      } else {
        if is_total_row(cs) {
          acc
        } else {
          match md.cents_of(nth(cs, 1)) {
            None => acc,
            Some(v) => list.concat(acc, [v]),
          }
        }
      }
    })
    let totals := list.fold(data, [], fn (acc :: List[Int], r :: Str) -> List[Int] {
      let cs := md.cells(r)
      if list.len(cs) < 2 {
        acc
      } else {
        if is_total_row(cs) {
          match md.cents_of(nth(cs, 1)) {
            None => acc,
            Some(v) => list.concat(acc, [v]),
          }
        } else {
          acc
        }
      }
    })
    if list.is_empty(items) {
      { why: "no item row with a numeric EUR amount", total: 0 }
    } else {
      match list.head(totals) {
        None => { why: "no Total row", total: 0 },
        Some(total) => {
          let s := list.fold(items, 0, fn (a :: Int, v :: Int) -> Int {
            a + v
          })
          let d := if s > total {
            s - total
          } else {
            total - s
          }
          if d > 50 {
            { why: str.join(["Total row says ", md.fmt_cents(total), " but the item rows sum to ", md.fmt_cents(s), ": recompute, do not paste"], ""), total: 0 }
          } else {
            { why: "", total: total }
          }
        },
      }
    }
  }
}

fn is_total_row(cs :: List[Str]) -> Bool {
  str.starts_with(str.to_lower(nth(cs, 0)), "total")
}

fn nth(xs :: List[Str], i :: Int) -> Str {
  if i <= 0 {
    match list.head(xs) {
      None => "",
      Some(x) => x,
    }
  } else {
    nth(list.tail(xs), i - 1)
  }
}

fn check_kind(kind :: Str, body :: Str) -> Budget {
  if str.is_empty(str.trim(body)) {
    { why: "section missing or empty", total: 0 }
  } else {
    if kind == "bullets" {
      if md.has_bullet(body) {
        { why: "", total: 0 }
      } else {
        { why: "needs at least one bullet", total: 0 }
      }
    } else {
      if kind == "budget" {
        budget_of(body)
      } else {
        { why: "", total: 0 }
      }
    }
  }
}

fn find_plan(root :: Str) -> [fs_walk] Str {
  let direct := str.join([root, "/plan.md"], "")
  if fs.exists(direct) {
    direct
  } else {
    let mds := list.filter(match fs.glob(str.join([root, "/**/*.md"], "")) {
      Err(_) => [],
      Ok(g) => g,
    }, fn (p :: Str) -> Bool {
      not str.contains(p, "__pycache__")
    })
    if list.len(mds) == 1 {
      match list.head(mds) {
        None => "",
        Some(p) => p,
      }
    } else {
      ""
    }
  }
}

fn main(root :: Str) -> [fs_read, fs_walk, io] Int {
  let dir := if str.is_empty(root) {
    "."
  } else {
    root
  }
  let path := find_plan(dir)
  if str.is_empty(path) {
    let __ := io.print("check_founding_plan: no plan.md on disk (write the plan as a fenced block labelled plan.md)")
    1
  } else {
    match io.read(path) {
      Err(_) => {
        let __ := io.print("check_founding_plan: no plan.md on disk (write the plan as a fenced block labelled plan.md)")
        1
      },
      Ok(text) => {
        let results := list.map(sections(), fn (s :: Section) -> (Section, Budget) {
          (s, check_kind(s.kind, md.section(text, s.heading)))
        })
        let met := list.filter(results, fn (r :: (Section, Budget)) -> Bool {
          match r {
            (_, b) => str.is_empty(b.why),
          }
        })
        let unmet := list.filter(results, fn (r :: (Section, Budget)) -> Bool {
          match r {
            (_, b) => not str.is_empty(b.why),
          }
        })
        let total := list.fold(results, 0, fn (acc :: Int, r :: (Section, Budget)) -> Int {
          match r {
            (s, b) => if s.kind == "budget" and str.is_empty(b.why) {
              b.total
            } else {
              acc
            },
          }
        })
        let attrs := str.join(list.map(met, fn (r :: (Section, Budget)) -> Str {
          match r {
            (s, _) => s.attr,
          }
        }), " ")
        let __v := io.print(str.concat("FOUNDING_PLAN_VERIFIED ", attrs))
        if list.is_empty(unmet) {
          let __o := io.print(str.concat("FOUNDING_PLAN_OK ", attrs))
          let __t := io.print(str.concat("FOUNDING_PLAN_TOTAL_EUR=", md.fmt_cents(total)))
          0
        } else {
          let __h := io.print("check_founding_plan: the plan does not meet these checkable criteria:\n")
          let __l := list.fold(unmet, 0, fn (n :: Int, r :: (Section, Budget)) -> [io] Int {
            match r {
              (s, b) => {
                let __ := io.print(str.join(["  ", s.attr, "  (", s.heading, "): ", b.why], ""))
                n + 1
              },
            }
          })
          1
        }
      },
    }
  }
}

