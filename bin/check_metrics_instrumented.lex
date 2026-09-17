# check_metrics_instrumented.lex — every success metric the PM defined is
# actually instrumented.
#
# The analytics role exists because a metric written in a PRD and never
# measured cannot decide anything. A company that ships without this can answer
# "did it build" but never "did it work", which is the question the next
# iteration turns on.
#
# GROUNDED, NOT A JUDGE. It reads the metrics the PRD states and refuses unless
# each names an event the workspace REALLY emits -- the name has to appear in a
# source file, not only in the measurement plan. A plan citing an event nobody
# fires is the exact failure here, and it reads identically to a real one until
# someone looks.
#
# Ported from check_metrics_instrumented.py (lex-loom#512).

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.fs" as fs

import "std.regex" as re

import "std.int" as int

import "./md" as md

fn metric_headings() -> List[Str] {
  ["## Success metrics", "## Metrics"]
}

fn plan_headings() -> List[Str] {
  ["## Measurement plan", "## Instrumentation"]
}

fn source_suffixes() -> List[Str] {
  [".py", ".ts", ".js", ".tsx", ".jsx", ".lex", ".go", ".rb", ".java", ".rs", ".sql"]
}

# An event NAMED in prose: quoted or backticked.
fn event_pattern() -> Str {
  "[`\"']([a-z][a-z0-9_.]{2,63})[`\"']"
}

# An event EMITTED in code: the same name, but as the first argument of a call
# that plausibly records it. Matching bare quoted strings instead would let any
# dict key anywhere in the source satisfy a metric -- a metric citing "users"
# would pass against an unrelated {"users": ...}, which is precisely the false
# pass this gate exists to prevent.
fn emit_pattern() -> Str {
  "\\b(?:track|emit|capture|record|log_event|logEvent|trackEvent|(?:analytics|posthog|mixpanel|amplitude|segment|telemetry)[ \t]*\\.[ \t]*\\w+)[ \t]*\\([ \t]*[`\"']([a-z][a-z0-9_.]{2,63})[`\"']"
}

fn groups_matching(pattern :: Str, text :: Str) -> List[Str] {
  match re.compile(pattern) {
    Err(_) => [],
    Ok(r) => list.fold(re.find_all(r, text), [], fn (acc :: List[Str], m :: { text :: Str, start :: Int, end :: Int, groups :: List[Str] }) -> List[Str] {
      match list.head(m.groups) {
        None => acc,
        Some(g) => list.concat(acc, [g]),
      }
    }),
  }
}

fn first_section(text :: Str, headings :: List[Str]) -> Str {
  list.fold(headings, "", fn (acc :: Str, h :: Str) -> Str {
    if not str.is_empty(acc) {
      acc
    } else {
      md.section(text, h)
    }
  })
}

fn bullets(block :: Str) -> List[Str] {
  list.filter(list.map(list.filter(str.split(block, "\n"), fn (l :: Str) -> Bool {
    let t := str.trim(l)
    str.starts_with(t, "-") or str.starts_with(t, "*")
  }), fn (l :: Str) -> Str {
    strip_bullet(str.trim(l))
  }), fn (b :: Str) -> Bool {
    not str.is_empty(b)
  })
}

fn strip_bullet(s :: Str) -> Str {
  let t := str.trim(s)
  if str.starts_with(t, "-") or str.starts_with(t, "*") {
    strip_bullet(str.slice(t, 1, str.len(t)))
  } else {
    t
  }
}

fn is_source(path :: Str) -> Bool {
  let skipped := list.fold([".git/", "node_modules/", "__pycache__/", ".venv/"], false, fn (acc :: Bool, part :: Str) -> Bool {
    if acc {
      true
    } else {
      str.contains(path, part)
    }
  })
  if skipped {
    false
  } else {
    list.fold(source_suffixes(), false, fn (acc :: Bool, sfx :: Str) -> Bool {
      if acc {
        true
      } else {
        str.ends_with(path, sfx)
      }
    })
  }
}

fn files_under(root :: Str) -> [fs_walk] List[Str] {
  match fs.glob(str.join([root, "/**/*"], "")) {
    Err(_) => [],
    Ok(g) => g,
  }
}

fn emitted_events(root :: Str) -> [fs_walk, fs_read, io] List[Str] {
  md.unique(list.fold(list.filter(files_under(root), is_source), [], fn (acc :: List[Str], p :: Str) -> [fs_read, io] List[Str] {
    match io.read(p) {
      Err(_) => acc,
      Ok(t) => list.concat(acc, groups_matching(emit_pattern(), t)),
    }
  }))
}

fn any_shared(a :: List[Str], b :: List[Str]) -> Bool {
  list.fold(a, false, fn (acc :: Bool, x :: Str) -> Bool {
    if acc {
      true
    } else {
      md.contains(b, x)
    }
  })
}

fn take(xs :: List[Str], n :: Int) -> List[Str] {
  if n <= 0 {
    []
  } else {
    match list.head(xs) {
      None => [],
      Some(x) => list.cons(x, take(list.tail(xs), n - 1)),
    }
  }
}

fn clip(s :: Str, n :: Int) -> Str {
  if str.len(s) > n {
    str.slice(s, 0, n)
  } else {
    s
  }
}

type Unmet = { attr :: Str, metric :: Str, cites :: Str }

fn main(root :: Str) -> [fs_read, fs_walk, io] Int {
  let dir := if str.is_empty(root) {
    "."
  } else {
    root
  }
  let docs := list.filter(files_under(dir), fn (p :: Str) -> Bool {
    str.ends_with(p, ".md")
  })
  if list.is_empty(docs) {
    let __ := io.print("check_metrics_instrumented: no markdown found; expected the PRD and a measurement plan")
    1
  } else {
    let texts := list.fold(docs, [], fn (acc :: List[Str], d :: Str) -> [fs_read, io] List[Str] {
      match io.read(d) {
        Err(_) => acc,
        Ok(t) => list.concat(acc, [t]),
      }
    })
    let metrics_block := list.fold(texts, "", fn (acc :: Str, t :: Str) -> Str {
      if not str.is_empty(acc) {
        acc
      } else {
        first_section(t, metric_headings())
      }
    })
    let plan_block := list.fold(texts, "", fn (acc :: Str, t :: Str) -> Str {
      if not str.is_empty(acc) {
        acc
      } else {
        first_section(t, plan_headings())
      }
    })
    let metrics := bullets(metrics_block)
    if list.is_empty(metrics) {
      let __a := io.print("check_metrics_instrumented: no '## Success metrics' section with bullets found in any .md")
      let __b := io.print("  The PM defines the metrics; this role instruments them. Without them there is nothing to check.")
      1
    } else {
      let emitted := emitted_events(dir)
      let plan_events := md.unique(groups_matching(event_pattern(), plan_block))
      let judged := list.map(list.enumerate(metrics), fn (im :: (Int, Str)) -> (Str, Bool, Unmet) {
        match im {
          (i, metric) => {
            let attr := str.join(["checkable:metric-", int.to_str(i + 1), "-instrumented"], "")
            let cited := md.unique(groups_matching(event_pattern(), metric))
            let names := if list.is_empty(cited) {
              plan_events
            } else {
              cited
            }
            (attr, any_shared(names, emitted), { attr: attr, metric: clip(metric, 90), cites: if list.is_empty(names) {
              "(no event named)"
            } else {
              str.join(take(names, 4), ", ")
            } })
          },
        }
      })
      let met := list.filter(judged, fn (j :: (Str, Bool, Unmet)) -> Bool {
        match j {
          (_, ok, _) => ok,
        }
      })
      let unmet := list.filter(judged, fn (j :: (Str, Bool, Unmet)) -> Bool {
        match j {
          (_, ok, _) => not ok,
        }
      })
      let attrs := str.join(list.map(met, fn (j :: (Str, Bool, Unmet)) -> Str {
        match j {
          (a, _, _) => a,
        }
      }), " ")
      let __v := io.print(str.concat("METRICS_VERIFIED ", attrs))
      if list.is_empty(unmet) {
        let __o := io.print(str.concat("METRICS_OK ", attrs))
        0
      } else {
        let __h := io.print("check_metrics_instrumented: these metrics are not traceable to an event the code emits:\n")
        let __l := list.fold(unmet, 0, fn (n :: Int, j :: (Str, Bool, Unmet)) -> [io] Int {
          match j {
            (_, _, u) => {
              let __ := io.print(str.join(["  ", u.attr, ": ", u.metric, "\n      cites: ", u.cites], ""))
              n + 1
            },
          }
        })
        let __e := io.print(str.join(["\n  events actually emitted by the workspace: ", if list.is_empty(emitted) {
          "(none)"
        } else {
          str.join(sorted(emitted), ", ")
        }], ""))
        let __f := io.print("\nName the event in the metric or the measurement plan, AND emit it from the product.")
        1
      }
    }
  }
}

fn sorted(xs :: List[Str]) -> List[Str] {
  list.sort_by(xs, fn (a :: Str) -> Str {
    a
  })
}

