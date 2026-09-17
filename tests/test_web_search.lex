# test_web_search.lex — the search backends parse real result HTML.
#
# These fixtures are the ones demo/rr1 carried, and they moved here because the
# port made them testable properly. The Python could only be exercised by
# loading bin/web_search.lex through importlib from inside another Python
# process and monkeypatching its `fetch` — so the test depended on the module's
# private shape, and any refactor broke the test rather than the code.
#
# The Lex parsers are pure functions of the response body, so a test just calls
# them. That is not a stylistic win: it is why "does bing still decode its
# redirect" is answerable without a network, and consortium run 1 lost a day to
# a report whose sources were all bing.com redirects.
#
# Every fixture here is a real failure that cost something:
#   duckduckgo  the uddg= redirect, and the bot-check page that must be an
#               ERROR rather than an empty answer (2026-09-09: 47 "anomaly"
#               occurrences, and the research role silently got "no results"
#               for every query)
#   bing        the base64url `u=a1...` wrapper -- without decoding it every
#               cited source is a bing.com link the report gate then refuses
#   yahoo       the /RU=<percent-encoded>/ redirect
#   brave       the ordinary case, which still has to keep working

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "std.env" as env

import "../bin/web_search" as ws

fn brave_html() -> Str {
  "<div class=\"snippet svelte-x\" data-pos=\"0\" data-type=\"web\" data-keynav=\"true\"><div><a href=\"https://example.com/a\" target=\"_self\" class=\"l1\"><div class=\"title search-snippet-title line-clamp-1 svelte-y\">Example <b>A</b></div></a><div class=\"content desktop-default-regular t-primary line-clamp-2 svelte-z\"><!---->Snippet of A</div></div></div>"
}

fn bing_html() -> Str {
  "<li class=\"b_algo\"><h2><a href=\"https://www.bing.com/ck/a?!&amp;&amp;p=x&amp;u=a1aHR0cHM6Ly9leGFtcGxlLmNvbS9i&amp;ntb=1\" h=\"ID\">Example B</a></h2><div><p class=\"b_lineclamp2\">Snippet of B</p></div></li>"
}

fn ddg_html() -> Str {
  "<a rel=\"nofollow\" class=\"result__a\" href=\"//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fc&amp;rut=1\">Example C</a><a class=\"result__snippet\" href=\"x\">Snippet of C</a>"
}

fn yahoo_html() -> Str {
  "<div class=\"dd algo algo-sr Sr\"><div class=\"compTitle\"><a class=\"x\" href=\"https://r.search.yahoo.com/_ylt=A;_ylu=B/RV=2/RE=1/RO=10/RU=https%3a%2f%2fexample.com%2fd/RK=2/RS=z\"><div>example.com</div><h3 class=\"title fc-2015C2-imp\"><span>Example <b>D</b></span></h3></a></div><div class=\"compText aAbs\"><p class=\"fc-dustygray\"><span>Aug 9, 2025 · </span> Snippet of D</p></div></div>"
}

fn one(r :: Result[List[ws.Hit], Str]) -> Result[ws.Hit, Str] {
  match r {
    Err(e) => Err(e),
    Ok(hits) => match list.head(hits) {
      None => Err("the parser returned no results from its fixture"),
      Some(h) => Ok(h),
    },
  }
}

fn expect(name :: Str, r :: Result[List[ws.Hit], Str], title :: Str, snippet :: Str, url :: Str) -> Result[Unit, Str] {
  match one(r) {
    Err(e) => Err(str.join([name, ": ", e], "")),
    Ok(h) => if h.title == title and h.snippet == snippet and h.url == url {
      Ok(())
    } else {
      Err(str.join([name, ": got (", h.title, "|", h.snippet, "|", h.url, "), wanted (", title, "|", snippet, "|", url, ")"], ""))
    },
  }
}

fn test_brave_parses_title_snippet_and_url() -> Result[Unit, Str] {
  expect("brave", ws.parse_brave(brave_html()), "Example A", "Snippet of A", "https://example.com/a")
}

# Without the base64url decode every cited source is a bing.com redirect, and
# check_research_report then refuses all of them as URLs web_search never
# returned -- a correct report failed for the search tool's bug.
fn test_bing_decodes_its_base64_redirect() -> Result[Unit, Str] {
  expect("bing", ws.parse_bing(bing_html()), "Example B", "Snippet of B", "https://example.com/b")
}

fn test_duckduckgo_decodes_its_uddg_redirect() -> Result[Unit, Str] {
  expect("duckduckgo", ws.parse_duckduckgo(ddg_html()), "Example C", "Snippet of C", "https://example.com/c")
}

fn test_yahoo_decodes_its_ru_redirect() -> Result[Unit, Str] {
  expect("yahoo", ws.parse_yahoo(yahoo_html()), "Example D", "Aug 9, 2025 · Snippet of D", "https://example.com/d")
}

# A bot-check page must be an ERROR, not an empty answer. Empty means "this
# query has no results" and stops the chain being useful; error means "ask the
# next backend". The research role spent weeks on the wrong side of that
# distinction.
fn test_a_bot_check_page_is_an_error_not_an_empty_answer() -> Result[Unit, Str] {
  match ws.parse_duckduckgo(str.join(list.map(list.range(0, 40), fn (i :: Int) -> Str {
    "anomaly "
  }), "")) {
    Err(_) => Ok(()),
    Ok(_) => Err("a bot-check page parsed as an empty result set, so the chain reports 'no results' for a query nobody ran"),
  }
}

# Order is evidence, not preference: bing answers a bot with results for the
# query's FIRST WORD only, and brave's html endpoint 429s for hours after a
# burst. Yahoo answered the query both of them got wrong.
fn test_yahoo_is_tried_before_brave_and_bing() -> Result[Unit, Str] {
  let names := list.map(ws.backends("q"), fn (b :: ws.Backend) -> Str {
    b.name
  })
  if names == ["duckduckgo", "yahoo", "brave", "bing"] {
    Ok(())
  } else {
    Err(str.join(["the fallback order is ", str.join(names, ", "), "; a blocked duckduckgo must fall to yahoo, not to the engines that fail live"], ""))
  }
}

# The ledger is what makes a cited source checkable at all: check_research_report
# refuses any URL web_search never returned. A tool that finds results and
# records none of them turns every correct citation into a refusal.
fn test_every_returned_url_is_recorded_in_the_ledger() -> [io, env, fs_read, fs_write] Result[Unit, Str] {
  let path := ws.ledger_path()
  let __clear := io.write(path, "")
  let __emit := ws.emit([{ title: "R", snippet: "S", url: "https://example.com/recorded" }])
  match io.read(path) {
    Err(_) => Err(str.join(["the tool wrote no ledger at ", path], "")),
    Ok(t) => if str.contains(t, "https://example.com/recorded") {
      Ok(())
    } else {
      Err(str.join(["the ledger does not carry the URL the tool returned; it holds: ", str.trim(t)], ""))
    },
  }
}

fn run_all() -> [io, env, fs_read, fs_write] Int {
  let results := [("brave parses title, snippet and url", test_brave_parses_title_snippet_and_url()), ("bing decodes its base64 redirect", test_bing_decodes_its_base64_redirect()), ("duckduckgo decodes its uddg redirect", test_duckduckgo_decodes_its_uddg_redirect()), ("yahoo decodes its RU redirect", test_yahoo_decodes_its_ru_redirect()), ("a bot-check page is an error, not an empty answer", test_a_bot_check_page_is_an_error_not_an_empty_answer()), ("yahoo is tried before brave and bing", test_yahoo_is_tried_before_brave_and_bing()), ("every returned url is recorded in the ledger", test_every_returned_url_is_recorded_in_the_ledger())]
  list.fold(results, 0, fn (fails :: Int, r :: (Str, Result[Unit, Str])) -> [io] Int {
    match r {
      (name, Ok(_)) => {
        let __ := io.print(str.concat("ok   ", name))
        fails
      },
      (name, Err(e)) => {
        let __ := io.print(str.join(["FAIL ", name, ": ", e], ""))
        fails + 1
      },
    }
  })
}

