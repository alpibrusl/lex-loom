# web_search.lex — web search for the research roles: numbered results WITH
# their URLs.
#
# Prints one line per result:
#
#     N. <title> -- <snippet> -- <url>
#
# and exits 0. Prints NO_RESULTS or ERROR:<why> on its own (still exit 0) so
# the caller can tell an empty answer from a broken backend.
#
# Backends in order: the Brave API when BRAVE_SEARCH_API_KEY is set (a key is a
# reference, never stored here), then DuckDuckGo html, Yahoo html (redirect
# links decoded back to the real URL), Brave html, then Bing.
#
# THE ORDER IS EVIDENCE, NOT PREFERENCE. Found live in consortium run 1: Bing's
# html page answers a bot with results for the FIRST WORD of the query only
# ("free text date parsing API" -> free online games), and Brave's html
# endpoint returns 429 for hours after a burst, so a run that fell through to
# Bing wrote an honest but worthless report. Yahoo answered the same query with
# the right products. DuckDuckGo began serving this host a bot-check page on
# 2026-09-09 -- 47 occurrences of "anomaly", no results -- and the research
# role had silently been getting "no results found" for every query since.
#
# A report grounded in nothing is what the opportunity gate exists to refuse,
# so a second backend is not optional and every result carries the URL the
# report must cite.
#
# Ported from web_search.py (lex-loom#512). The parsers are PURE functions of
# the response body, which is what makes them testable without a network: the
# Python could only be tested by monkeypatching its own fetch from inside
# another Python process.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.env" as env

import "std.http" as http

import "std.map" as map

import "std.regex" as re

import "std.int" as int

import "std.bytes" as bytes

import "std.crypto" as crypto

type Hit = { title :: Str, snippet :: Str, url :: Str }

fn max_results() -> Int {
  8
}

fn user_agent() -> Str {
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
}

# Where every URL this tool returned is recorded, so the report gate can refuse
# a source the model never read -- check_research_report.lex reads the same
# path. Per company when COMPANY_ID is set, as it is in every bootstrapped run.
fn ledger_path() -> [env] Str {
  match env.get("LOOM_SEARCH_LEDGER") {
    Some(p) => p,
    None => str.join(["/tmp/loom-search-ledger-", match env.get("COMPANY_ID") {
      Some(c) => c,
      None => "default",
    }, ".txt"], ""),
  }
}

fn html_unescape(s :: Str) -> Str {
  let named := list.fold([("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&middot;", "·"), ("&hellip;", "…"), ("&mdash;", "—"), ("&ndash;", "–")], s, fn (acc :: Str, kv :: (Str, Str)) -> Str {
    match kv {
      (from, to) => str.replace(acc, from, to),
    }
  })
  named
}

fn strip_tags(s :: Str) -> Str {
  match re.compile("(?s)<[^>]*>") {
    Err(_) => s,
    Ok(r) => re.replace_all(r, s, ""),
  }
}

fn collapse_ws(s :: Str) -> Str {
  match re.compile("\\s+") {
    Err(_) => s,
    Ok(r) => str.trim(re.replace_all(r, s, " ")),
  }
}

fn clean(s :: Str) -> Str {
  collapse_ws(html_unescape(strip_tags(s)))
}

fn hex_val(c :: Str) -> Int {
  match str.to_int(c) {
    Some(n) => n,
    None => list.fold([("a", 10), ("b", 11), ("c", 12), ("d", 13), ("e", 14), ("f", 15)], -1, fn (acc :: Int, kv :: (Str, Int)) -> Int {
      match kv {
        (h, v) => if str.to_lower(c) == h {
          v
        } else {
          acc
        },
      }
    }),
  }
}

fn percent_decode(s :: Str) -> Str {
  decode_from(s, 0, "")
}

fn decode_from(s :: Str, i :: Int, acc :: Str) -> Str {
  if i >= str.len(s) {
    acc
  } else {
    let c := str.slice(s, i, i + 1)
    if c == "%" and i + 2 < str.len(s) {
      let hi := hex_val(str.slice(s, i + 1, i + 2))
      let lo := hex_val(str.slice(s, i + 2, i + 3))
      if hi >= 0 and lo >= 0 {
        decode_from(s, i + 3, str.concat(acc, match bytes.to_str(bytes.u8(hi * 16 + lo)) {
          Err(_) => "",
          Ok(ch) => ch,
        }))
      } else {
        decode_from(s, i + 1, str.concat(acc, c))
      }
    } else {
      if c == "+" {
        decode_from(s, i + 1, str.concat(acc, " "))
      } else {
        decode_from(s, i + 1, str.concat(acc, c))
      }
    }
  }
}

fn is_unreserved(c :: Str) -> Bool {
  match re.compile("^[A-Za-z0-9._~-]$") {
    Err(_) => false,
    Ok(r) => match re.find(r, c) {
      None => false,
      Some(_) => true,
    },
  }
}

fn percent_encode(s :: Str) -> Str {
  encode_from(s, 0, "")
}

fn encode_from(s :: Str, i :: Int, acc :: Str) -> Str {
  if i >= str.len(s) {
    acc
  } else {
    let c := str.slice(s, i, i + 1)
    if is_unreserved(c) {
      encode_from(s, i + 1, str.concat(acc, c))
    } else {
      if c == " " {
        encode_from(s, i + 1, str.concat(acc, "+"))
      } else {
        encode_from(s, i + 1, str.concat(acc, hex_escape(c)))
      }
    }
  }
}

fn hex_escape(c :: Str) -> Str {
  let bs := bytes.from_str(c)
  list.fold(list.range(0, bytes.len(bs)), "", fn (acc :: Str, i :: Int) -> Str {
    match bytes.u8_at(bs, i) {
      Err(_) => acc,
      Ok(b) => str.join([acc, "%", crypto.hex_encode(bytes.u8(b))], ""),
    }
  })
}

fn query_param(url :: Str, name :: Str) -> Str {
  let after := match list.head(list.tail(str.split(url, "?"))) {
    None => "",
    Some(q) => q,
  }
  list.fold(str.split(after, "&"), "", fn (acc :: Str, kv :: Str) -> Str {
    if not str.is_empty(acc) {
      acc
    } else {
      let parts := str.split(kv, "=")
      match list.head(parts) {
        None => acc,
        Some(k) => if k == name {
          percent_decode(str.join(list.tail(parts), "="))
        } else {
          acc
        },
      }
    }
  })
}

fn matches_of(pattern :: Str, text :: Str) -> List[List[Str]] {
  match re.compile(pattern) {
    Err(_) => [],
    Ok(r) => list.map(re.find_all(r, text), fn (m :: { text :: Str, start :: Int, end :: Int, groups :: List[Str] }) -> List[Str] {
      m.groups
    }),
  }
}

fn group(gs :: List[Str], i :: Int) -> Str {
  if i <= 0 {
    match list.head(gs) {
      None => "",
      Some(g) => g,
    }
  } else {
    group(list.tail(gs), i - 1)
  }
}

fn first_group_of(pattern :: Str, text :: Str, i :: Int) -> Str {
  match list.head(matches_of(pattern, text)) {
    None => "",
    Some(gs) => group(gs, i),
  }
}

# A bot-check page is an ERROR, not an empty answer, so the chain falls through
# to the next backend instead of reporting "nothing found" for a query that was
# never run.
fn parse_duckduckgo(body :: Str) -> Result[List[Hit], Str] {
  if count_occurrences(body, "anomaly") > 5 and not str.contains(body, "result__a") {
    Err("duckduckgo served a bot-check page")
  } else {
    Ok(list.map(matches_of("(?s)class=\"result__a\"[^>]*href=\"([^\"]*)\"[^>]*>(.*?)</a>.*?class=\"result__snippet\"[^>]*>(.*?)</a>", body), fn (gs :: List[Str]) -> Hit {
      let href := html_unescape(group(gs, 0))
      let uddg := query_param(href, "uddg")
      { title: clean(group(gs, 1)), snippet: clean(group(gs, 2)), url: if str.is_empty(uddg) {
        href
      } else {
        uddg
      } }
    }))
  }
}

fn count_occurrences(hay :: Str, needle :: Str) -> Int {
  list.len(str.split(hay, needle)) - 1
}

fn parse_brave(body :: Str) -> Result[List[Hit], Str] {
  Ok(list.map(matches_of("(?s)<div class=\"snippet [^\"]*\" data-pos=\"\\d+\" data-type=\"web\".*?<a href=\"(https?://[^\"]+)\".*?class=\"title [^\"]*\"[^>]*>(.*?)</div>.*?class=\"content [^\"]*\"[^>]*>(.*?)</div>", body), fn (gs :: List[Str]) -> Hit {
    { title: clean(group(gs, 1)), snippet: clean(group(gs, 2)), url: group(gs, 0) }
  }))
}

fn parse_yahoo(body :: Str) -> Result[List[Hit], Str] {
  Ok(list.fold(list.tail(str.split(body, "<div class=\"dd algo")), [], fn (acc :: List[Hit], block :: Str) -> List[Hit] {
    let gs := match list.head(matches_of("(?s)<a[^>]*href=\"([^\"]+)\"[^>]*>.*?<h3[^>]*class=\"title[^\"]*\"[^>]*>(.*?)</h3>", block)) {
      None => [],
      Some(g) => g,
    }
    if list.is_empty(gs) {
      acc
    } else {
      let href := html_unescape(group(gs, 0))
      let ru := first_group_of("/RU=([^/]+)/", href, 0)
      let snippet := first_group_of("(?s)<div class=\"compText[^\"]*\"[^>]*>\\s*<p[^>]*>(.*?)</p>", block, 0)
      list.concat(acc, [{ title: clean(group(gs, 1)), snippet: clean(snippet), url: if str.is_empty(ru) {
        href
      } else {
        percent_decode(ru)
      } }])
    }
  }))
}

# Bing wraps the real URL in a base64url `u=a1<...>` parameter. Without
# decoding it, every cited source is a bing.com redirect, and the report gate
# refuses them all as URLs web_search never returned.
fn parse_bing(body :: Str) -> Result[List[Hit], Str] {
  Ok(list.fold(list.tail(str.split(body, "<li class=\"b_algo\"")), [], fn (acc :: List[Hit], raw :: Str) -> List[Hit] {
    let block := match list.head(str.split(raw, "</li>")) {
      None => raw,
      Some(b) => b,
    }
    let gs := match list.head(matches_of("(?s)<h2[^>]*><a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", block)) {
      None => [],
      Some(g) => g,
    }
    if list.is_empty(gs) {
      acc
    } else {
      let href := html_unescape(group(gs, 0))
      let u := query_param(href, "u")
      let real := if str.starts_with(u, "a1") {
        decode_b64url(str.slice(u, 2, str.len(u)))
      } else {
        href
      }
      let p1 := first_group_of("(?s)<p[^>]*class=\"b_lineclamp[^\"]*\"[^>]*>(.*?)</p>", block, 0)
      let snippet := if str.is_empty(p1) {
        first_group_of("(?s)<p[^>]*>(.*?)</p>", block, 0)
      } else {
        p1
      }
      list.concat(acc, [{ title: clean(group(gs, 1)), snippet: clean(snippet), url: if str.is_empty(real) {
        href
      } else {
        real
      } }])
    }
  }))
}

fn decode_b64url(s :: Str) -> Str {
  match crypto.base64url_decode(s) {
    Err(_) => "",
    Ok(b) => match bytes.to_str(b) {
      Err(_) => "",
      Ok(t) => t,
    },
  }
}

# The User-Agent is not decoration: these endpoints serve a bot-check page or a
# stripped result set to a default client, and that is indistinguishable from
# "no results" at the call site.
fn fetch(url :: Str) -> [net] Result[Str, Str] {
  let req := http.with_timeout_ms(http.with_header(http.with_header({ method: "GET", url: url, headers: map.new(), body: None, timeout_ms: None }, "User-Agent", user_agent()), "Accept-Language", "en"), 15000)
  match http.send(req) {
    Err(e) => Err(http_err(e)),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => Err("response was not text"),
      Ok(t) => Ok(t),
    },
  }
}

fn http_err(e :: HttpError) -> Str {
  match e {
    TimeoutError => "timeout",
    TlsError(m) => str.concat("tls: ", m),
    NetworkError(m) => str.concat("network: ", m),
    DecodeError(m) => str.concat("decode: ", m),
  }
}

type Backend = { name :: Str, url :: Str }

fn backends(q :: Str) -> List[Backend] {
  let e := percent_encode(q)
  [{ name: "duckduckgo", url: str.concat("https://html.duckduckgo.com/html/?q=", e) }, { name: "yahoo", url: str.concat("https://search.yahoo.com/search?p=", e) }, { name: "brave", url: str.concat("https://search.brave.com/search?source=web&q=", e) }, { name: "bing", url: str.join(["https://www.bing.com/search?setlang=en&cc=US&q=", e], "") }]
}

fn parse_for(name :: Str, body :: Str) -> Result[List[Hit], Str] {
  if name == "duckduckgo" {
    parse_duckduckgo(body)
  } else {
    if name == "yahoo" {
      parse_yahoo(body)
    } else {
      if name == "brave" {
        parse_brave(body)
      } else {
        parse_bing(body)
      }
    }
  }
}

fn take(xs :: List[Hit], n :: Int) -> List[Hit] {
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

fn main(query :: Str, only :: Str) -> [net, io, env, fs_read, fs_write] Int {
  let q := str.trim(query)
  if str.is_empty(q) {
    let __ := io.print("ERROR:query is required")
    0
  } else {
    let chain := list.filter(backends(q), fn (b :: Backend) -> Bool {
      str.is_empty(only) or b.name == only
    })
    run_chain(chain, [])
  }
}

fn run_chain(chain :: List[Backend], errors :: List[Str]) -> [net, io, env, fs_read, fs_write] Int {
  match list.head(chain) {
    None => {
      let all_empty := list.fold(errors, true, fn (acc :: Bool, e :: Str) -> Bool {
        acc and str.ends_with(e, "no results")
      })
      let __ := io.print(if all_empty and not list.is_empty(errors) {
        "NO_RESULTS"
      } else {
        str.concat("ERROR:", str.join(errors, "; "))
      })
      0
    },
    Some(b) => match fetch(b.url) {
      Err(e) => run_chain(list.tail(chain), list.concat(errors, [str.join([b.name, ": ", e], "")])),
      Ok(body) => match parse_for(b.name, body) {
        Err(e) => run_chain(list.tail(chain), list.concat(errors, [str.join([b.name, ": ", e], "")])),
        Ok(hits) => if list.is_empty(hits) {
          run_chain(list.tail(chain), list.concat(errors, [str.join([b.name, ": no results"], "")]))
        } else {
          emit(take(hits, max_results()))
        },
      },
    },
  }
}

fn emit(hits :: List[Hit]) -> [io, env, fs_read, fs_write] Int {
  let __led := append_ledger(hits)
  let __out := list.fold(list.enumerate(hits), 0, fn (n :: Int, ih :: (Int, Hit)) -> [io] Int {
    match ih {
      (i, h) => {
        let __ := io.print(str.join([int.to_str(i + 1), ". ", h.title, " -- ", clip(h.snippet, 200), " -- ", h.url], ""))
        n + 1
      },
    }
  })
  0
}

fn append_ledger(hits :: List[Hit]) -> [env, fs_read, fs_write, io] Unit {
  let path := ledger_path()
  let existing := match io.read(path) {
    Err(_) => "",
    Ok(t) => t,
  }
  let added := str.join(list.map(hits, fn (h :: Hit) -> Str {
    h.url
  }), "\n")
  let __ := io.write(path, str.join([existing, added, "\n"], ""))
  ()
}

