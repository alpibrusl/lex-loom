# md.lex — the markdown shapes loom's document gates all ask about.
#
# check_research_report, check_founding_plan and the others each want the same
# four questions answered: what is under this heading, does this section have
# bullets, how many data rows has this table, which URLs does it cite. Each
# Python checker answered them with its own private regex, and they had already
# drifted -- one anchored its heading match case-insensitively, another did
# not, so "## sources" was a section to one gate and missing to the next.
#
# PURE ON PURPOSE. A Lex program's effect row is the union of everything it
# imports, so a helper module that read a file would push fs_read onto every
# gate that wanted to count table rows. Reading is the caller's job; this
# module only looks at strings it is handed.

import "std.str" as str

import "std.list" as list

import "std.regex" as re

import "std.int" as int

# Everything under `## Heading` up to the next `## `. The heading match is
# case-insensitive and tolerates trailing words, because "## Sources and
# references" is the same section a gate means by "## Sources".
fn section(text :: Str, heading :: Str) -> Str {
  collect(str.split(text, "\n"), str.to_lower(heading), false, [])
}

fn collect(lines :: List[Str], want :: Str, inside :: Bool, acc :: List[Str]) -> Str {
  match list.head(lines) {
    None => str.trim(str.join(list.reverse(acc), "\n")),
    Some(line) => {
      let low := str.to_lower(str.trim(line))
      if inside {
        if str.starts_with(low, "## ") {
          str.trim(str.join(list.reverse(acc), "\n"))
        } else {
          collect(list.tail(lines), want, true, list.cons(line, acc))
        }
      } else {
        collect(list.tail(lines), want, str.starts_with(low, want), acc)
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

fn has_bullet(body :: Str) -> Bool {
  matches("(?m)^[ \t]*[-*][ \t]+\\S", body)
}

# Rows of a markdown table, with the `|---|` rule dropped. The header is still
# in here: a caller counting DATA rows subtracts it.
fn table_rows(body :: Str) -> List[Str] {
  list.filter(str.split(body, "\n"), fn (l :: Str) -> Bool {
    let t := str.trim(l)
    str.starts_with(t, "|") and not matches("^\\|[ \t]*-", t)
  })
}

fn data_row_count(body :: Str) -> Int {
  let rows := table_rows(body)
  if list.is_empty(rows) {
    0
  } else {
    list.len(rows) - 1
  }
}

fn cells(row :: Str) -> List[Str] {
  let t := str.trim(row)
  let inner := if str.starts_with(t, "|") {
    str.slice(t, 1, str.len(t))
  } else {
    t
  }
  let body := if str.ends_with(inner, "|") {
    str.slice(inner, 0, str.len(inner) - 1)
  } else {
    inner
  }
  list.map(str.split(body, "|"), fn (c :: Str) -> Str {
    str.trim(c)
  })
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
    if contains(acc, x) {
      acc
    } else {
      list.concat(acc, [x])
    }
  })
}

fn contains(xs :: List[Str], want :: Str) -> Bool {
  list.fold(xs, false, fn (acc :: Bool, x :: Str) -> Bool {
    if acc {
      true
    } else {
      x == want
    }
  })
}

fn first_group(pattern :: Str, s :: Str) -> Str {
  match re.compile(pattern) {
    Err(_) => "",
    Ok(r) => match re.find(r, s) {
      None => "",
      Some(m) => match list.head(m.groups) {
        None => "",
        Some(g) => g,
      },
    },
  }
}

# Money in whole cents, because a budget that is checked by RECOMPUTING it must
# not disagree with itself over binary floating point. "€1,234.50" -> 123450.
# None when the cell carries no number at all, which a caller reports
# differently from a zero.
fn cents_of(cell :: Str) -> Option[Int] {
  let cleaned := str.replace(str.replace(str.replace(cell, "€", ""), ",", ""), " ", "")
  let g := first_group("(-?\\d+(?:\\.\\d+)?)", cleaned)
  if str.is_empty(g) {
    None
  } else {
    let parts := str.split(g, ".")
    let whole := match list.head(parts) {
      None => "0",
      Some(w) => w,
    }
    let frac := if list.len(parts) > 1 {
      match list.head(list.tail(parts)) {
        None => "0",
        Some(f) => f,
      }
    } else {
      "0"
    }
    let pad := str.slice(str.concat(frac, "00"), 0, 2)
    match str.to_int(whole) {
      None => None,
      Some(w) => match str.to_int(pad) {
        None => None,
        Some(f) => Some(if w < 0 {
          w * 100 - f
        } else {
          w * 100 + f
        }),
      },
    }
  }
}

# Python's "%g" on the value these cents came from: no decimal part when the
# amount is whole, two when it is not. The gates print this into an approval a
# founder reads, so "450" must not become "450.00" and "12.5" must not become
# "12.50" -- the Python printed neither.
fn fmt_cents(c :: Int) -> Str {
  let neg := c < 0
  let a := if neg {
    0 - c
  } else {
    c
  }
  let whole := a / 100
  let frac := a - whole * 100
  let sign := if neg {
    "-"
  } else {
    ""
  }
  if frac == 0 {
    str.join([sign, int.to_str(whole)], "")
  } else {
    if frac - frac / 10 * 10 == 0 {
      str.join([sign, int.to_str(whole), ".", int.to_str(frac / 10)], "")
    } else {
      str.join([sign, int.to_str(whole), ".", if frac < 10 {
        str.concat("0", int.to_str(frac))
      } else {
        int.to_str(frac)
      }], "")
    }
  }
}

