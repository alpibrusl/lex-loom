# check_research_report.lex — an opportunity report against the run-1
# checkable criteria (docs/consortium-freeze.md §5).
#
# Every criterion here is one the freeze document calls CHECKABLE, and each is
# named by the attr lex-economy's evidence items carry. The human's criterion
# -- "would you fund it?" -- is deliberately absent: the machine never answers
# it, and a checker that pretended to would be making the one judgement the
# consortium reserves for a person.
#
# Ported from check_research_report.py (lex-loom#512), differentially verified
# against it before the Python was deleted.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.fs" as fs

import "std.env" as env

import "std.regex" as re

import "std.int" as int

type Criterion = { attr :: Str, heading :: Str, kind :: Str }

fn criteria() -> List[Criterion] {
  [{ attr: "checkable:problem-statement", heading: "## Problem", kind: "" }, { attr: "checkable:target-user", heading: "## Target user", kind: "" }, { attr: "checkable:three-alternatives", heading: "## Alternatives", kind: "table3" }, { attr: "checkable:implementation-estimate", heading: "## Implementation estimate", kind: "hours" }, { attr: "checkable:dependencies", heading: "## Dependencies", kind: "bullet" }, { attr: "checkable:two-sources", heading: "## Sources", kind: "urls2" }, { attr: "checkable:sources-grounded", heading: "## Sources", kind: "grounded" }, { attr: "checkable:confidence", heading: "## Confidence", kind: "percent" }, { attr: "checkable:recommendation", heading: "## Recommendation", kind: "" }]
}

fn ledger_path() -> [env] Str {
  match env.get("LOOM_SEARCH_LEDGER") {
    Some(p) => p,
    None => str.join(["/tmp/loom-search-ledger-", match env.get("COMPANY_ID") {
      Some(c) => c,
      None => "default",
    }, ".txt"], ""),
  }
}

# Scheme and host lowercased, a trailing slash off the path, fragment dropped,
# query kept. Two spellings of one URL must not read as two sources, and a
# citation must not escape the ledger on a capital letter.
fn norm_url(raw :: Str) -> Str {
  let u := str.trim(raw)
  let trimmed := trim_trailing(u, [".", ",", ";", ")"])
  let nofrag := match list.head(str.split(trimmed, "#")) {
    None => trimmed,
    Some(h) => h,
  }
  let parts := str.split(nofrag, "://")
  if list.len(parts) < 2 {
    str.to_lower(nofrag)
  } else {
    let scheme := str.to_lower(match list.head(parts) {
      None => "",
      Some(s) => s,
    })
    let rest := str.join(list.tail(parts), "://")
    let slash := match str.find(rest, "/", 0) {
      None => -1,
      Some(i) => i,
    }
    if slash < 0 {
      str.join([scheme, "://", str.to_lower(rest)], "")
    } else {
      let host := str.to_lower(str.slice(rest, 0, slash))
      let tail := str.slice(rest, slash, str.len(rest))
      let qparts := str.split(tail, "?")
      let path := match list.head(qparts) {
        None => tail,
        Some(p) => p,
      }
      let query := if list.len(qparts) > 1 {
        str.join(["?", str.join(list.tail(qparts), "?")], "")
      } else {
        ""
      }
      str.join([scheme, "://", host, strip_trailing_slash(path), query], "")
    }
  }
}

fn strip_trailing_slash(p :: Str) -> Str {
  if str.len(p) > 1 and str.ends_with(p, "/") {
    strip_trailing_slash(str.slice(p, 0, str.len(p) - 1))
  } else {
    p
  }
}

fn trim_trailing(s :: Str, chars :: List[Str]) -> Str {
  let trimmed := list.fold(chars, s, fn (acc :: Str, c :: Str) -> Str {
    if str.len(acc) > 0 and str.ends_with(acc, c) {
      str.slice(acc, 0, str.len(acc) - 1)
    } else {
      acc
    }
  })
  if trimmed == s {
    s
  } else {
    trim_trailing(trimmed, chars)
  }
}

fn urls_in(body :: Str) -> List[Str] {
  match re.compile("https?://[^\\s)>\\]]+") {
    Err(_) => [],
    Ok(r) => list.map(re.find_all(r, body), fn (m :: { text :: Str, start :: Int, end :: Int, groups :: List[Str] }) -> Str {
      m.text
    }),
  }
}

fn unique(xs :: List[Str]) -> List[Str] {
  list.fold(xs, [], fn (acc :: List[Str], x :: Str) -> List[Str] {
    if contains_str(acc, x) {
      acc
    } else {
      list.concat(acc, [x])
    }
  })
}

fn contains_str(xs :: List[Str], want :: Str) -> Bool {
  list.fold(xs, false, fn (acc :: Bool, x :: Str) -> Bool {
    if acc {
      true
    } else {
      x == want
    }
  })
}

# Every cited URL must be one web_search actually returned in this run. The
# first live probe (2026-09-09) cited 21 sources of which 13 had never appeared
# in any result: real-looking products recalled from memory. The tool records
# what it returns; a citation outside that record is refused BY NAME, so the
# author can see which ones it invented.
fn grounded(body :: Str) -> [fs_read, fs_walk, env, io] Str {
  let path := ledger_path()
  if not fs.exists(path) {
    str.join(["no search ledger at ", path, ": web_search was never called in this run, so no source can be grounded"], "")
  } else {
    match io.read(path) {
      Err(_) => str.join(["no search ledger at ", path, ": web_search was never called in this run, so no source can be grounded"], ""),
      Ok(led) => {
        let seen := list.map(list.filter(str.split(led, "\n"), fn (l :: Str) -> Bool {
          not str.is_empty(str.trim(l))
        }), norm_url)
        let bad := list.filter(unique(urls_in(body)), fn (u :: Str) -> Bool {
          not contains_str(seen, norm_url(u))
        })
        if list.is_empty(bad) {
          ""
        } else {
          str.join(["cited but never returned by web_search (copy URLs verbatim from the results): ", str.join(bad, ", ")], "")
        }
      },
    }
  }
}

# Heading match is case-insensitive and tolerates trailing text on the heading
# line, because "## Sources and references" is the same section.
fn section(text :: Str, heading :: Str) -> Str {
  let want := str.to_lower(heading)
  let lines := str.split(text, "\n")
  collect_section(lines, want, false, [])
}

fn collect_section(lines :: List[Str], want :: Str, inside :: Bool, acc :: List[Str]) -> Str {
  match list.head(lines) {
    None => str.trim(str.join(list.reverse(acc), "\n")),
    Some(line) => {
      let low := str.to_lower(str.trim(line))
      if inside {
        if str.starts_with(low, "## ") {
          str.trim(str.join(list.reverse(acc), "\n"))
        } else {
          collect_section(list.tail(lines), want, true, list.cons(line, acc))
        }
      } else {
        if str.starts_with(low, want) {
          collect_section(list.tail(lines), want, true, acc)
        } else {
          collect_section(list.tail(lines), want, false, acc)
        }
      }
    },
  }
}

fn matches(pattern :: Str, s :: Str) -> Bool {
  match re.compile(pattern) {
    Err(_) => false,
    Ok(r) => match re.find(r, s) {
      None => false,
      Some(_) => true,
    },
  }
}

# The first row of a markdown table is the header and the second is the rule,
# so three ALTERNATIVES means three rows after those.
fn data_rows(body :: Str) -> Int {
  let rows := list.filter(str.split(body, "\n"), fn (l :: Str) -> Bool {
    let t := str.trim(l)
    str.starts_with(t, "|") and not matches("^\\|[ \t]*-", t)
  })
  if list.is_empty(rows) {
    0
  } else {
    list.len(rows) - 1
  }
}

fn percent_ok(body :: Str) -> Bool {
  match re.compile("\\b(\\d{1,3})[ \t]*%?") {
    Err(_) => false,
    Ok(r) => match re.find(r, body) {
      None => false,
      Some(m) => match list.head(m.groups) {
        None => false,
        Some(g) => match str.to_int(g) {
          None => false,
          Some(n) => n >= 0 and n <= 100,
        },
      },
    },
  }
}

fn check_kind(kind :: Str, body :: Str) -> [fs_read, fs_walk, env, io] Str {
  if str.is_empty(str.trim(body)) {
    "section missing or empty"
  } else {
    if kind == "table3" {
      let n := data_rows(body)
      if n >= 3 {
        ""
      } else {
        str.join(["needs a markdown table with at least 3 alternatives (found ", int.to_str(n), ")"], "")
      }
    } else {
      if kind == "hours" {
        if matches("(?i)\\b\\d+(\\.\\d+)?[ \t]*(hours?|h)\\b", body) {
          ""
        } else {
          "needs an estimate in hours (e.g. '40 hours')"
        }
      } else {
        if kind == "bullet" {
          if matches("(?m)^[ \t]*[-*][ \t]+\\S", body) {
            ""
          } else {
            "needs at least one bulleted dependency"
          }
        } else {
          if kind == "urls2" {
            let n := list.len(unique(urls_in(body)))
            if n >= 2 {
              ""
            } else {
              str.join(["needs at least 2 distinct http(s) sources (found ", int.to_str(n), ")"], "")
            }
          } else {
            if kind == "grounded" {
              grounded(body)
            } else {
              if kind == "percent" {
                if percent_ok(body) {
                  ""
                } else {
                  "needs a confidence figure between 0 and 100"
                }
              } else {
                ""
              }
            }
          }
        }
      }
    }
  }
}

fn find_report(root :: Str) -> [fs_read, fs_walk] Str {
  let direct := str.join([root, "/report.md"], "")
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

# The VERIFIED line prints on BOTH paths. A buyer building evidence from this
# output needs to know which criteria a refused report still met -- one unmet
# criterion is a 50% settlement, not a rejection.
fn main(root :: Str) -> [fs_read, fs_walk, io, env] Int {
  let path := find_report(if str.is_empty(root) {
    "."
  } else {
    root
  })
  if str.is_empty(path) {
    let __ := io.print("check_research_report: no report.md on disk (write the report as a fenced block labelled report.md)")
    1
  } else {
    match io.read(path) {
      Err(_) => {
        let __ := io.print("check_research_report: no report.md on disk (write the report as a fenced block labelled report.md)")
        1
      },
      Ok(text) => {
        let results := list.map(criteria(), fn (c :: Criterion) -> [fs_read, fs_walk, env, io] (Criterion, Str) {
          (c, check_kind(c.kind, section(text, c.heading)))
        })
        let met := list.filter(results, fn (r :: (Criterion, Str)) -> Bool {
          match r {
            (_, why) => str.is_empty(why),
          }
        })
        let unmet := list.filter(results, fn (r :: (Criterion, Str)) -> Bool {
          match r {
            (_, why) => not str.is_empty(why),
          }
        })
        let attrs := str.join(list.map(met, fn (r :: (Criterion, Str)) -> Str {
          match r {
            (c, _) => c.attr,
          }
        }), " ")
        let __v := io.print(str.concat("RESEARCH_REPORT_VERIFIED ", attrs))
        if list.is_empty(unmet) {
          let __ok := io.print(str.concat("RESEARCH_REPORT_OK ", attrs))
          0
        } else {
          let __h := io.print("check_research_report: the report does not meet these checkable criteria:\n")
          let __l := list.fold(unmet, 0, fn (n :: Int, r :: (Criterion, Str)) -> [io] Int {
            match r {
              (c, why) => {
                let __ := io.print(str.join(["  ", c.attr, "  (", c.heading, "): ", why], ""))
                n + 1
              },
            }
          })
          let __f := io.print("\nEach section above is required, with the content named. The human's question is not yours to answer.")
          1
        }
      },
    }
  }
}

