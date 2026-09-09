#!/usr/bin/env python3
"""Web search for the research roles: numbered results WITH their URLs.

Reads the query from argv (or stdin), prints one line per result:

    N. <title> -- <snippet> -- <url>

and exits 0. Prints NO_RESULTS or ERROR:<why> on its own (still exit 0) so the
caller distinguishes an empty answer from a broken backend.

Backends, in order: the Brave Search API when BRAVE_SEARCH_API_KEY is set
(a key is a reference, never stored here), DuckDuckGo's html endpoint,
Yahoo's html search (redirect links decoded back to the real URL), Brave's
html search, then Bing. Found live in consortium run 1: Bing's html page
answers a bot with results for the FIRST WORD of the query only ("free text
date parsing API" -> free online games), and Brave's html endpoint returns
429 for hours after a burst, so a run that fell through to Bing wrote an
honest but worthless report. Yahoo answered the same query with the right
products.
DuckDuckGo started answering every request from this host with a bot-check
page on 2026-09-09 (47 occurrences of "anomaly" in the body, no results);
the research role had silently been getting "no results found" for every
query since. A report grounded in nothing is what the opportunity gate exists
to refuse, so a second backend is not optional, and every result carries the
URL the report must cite.
"""
import html
import os
import re
import sys
import urllib.parse
import urllib.request

def ledger_path() -> str:
    """Where every URL this tool returned is recorded, so the report gate can
    refuse a source the model never read (bin/check_research_report.py reads
    the same path). Per company when COMPANY_ID is set, as it is in every
    bootstrapped run; a probe shares one default file."""
    return os.environ.get("LOOM_SEARCH_LEDGER") or "/tmp/loom-search-ledger-%s.txt" % (os.environ.get("COMPANY_ID") or "default")


UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
MAX = 8


def fetch(url: str, data: bytes | None = None) -> str:
    req = urllib.request.Request(url, data=data, headers={"User-Agent": UA, "Accept-Language": "en"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.read().decode("utf-8", "replace")


def clean(s: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]*>", "", s))).strip()


def duckduckgo(q: str):
    body = fetch("https://html.duckduckgo.com/html/?" + urllib.parse.urlencode({"q": q}))
    if body.count("anomaly") > 5 and "result__a" not in body:
        raise RuntimeError("duckduckgo served a bot-check page")
    out = []
    for m in re.finditer(r'class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>.*?class="result__snippet"[^>]*>(.*?)</a>', body, re.S):
        href = m.group(1)
        uddg = urllib.parse.parse_qs(urllib.parse.urlparse(href).query).get("uddg")
        url = uddg[0] if uddg else href
        out.append((clean(m.group(2)), clean(m.group(3)), url))
    return out


def brave(q: str):
    body = fetch("https://search.brave.com/search?" + urllib.parse.urlencode({"q": q, "source": "web"}))
    out = []
    for m in re.finditer(r'<div class="snippet [^"]*" data-pos="\d+" data-type="web".*?<a href="(https?://[^"]+)".*?class="title [^"]*"[^>]*>(.*?)</div>.*?class="content [^"]*"[^>]*>(.*?)</div>', body, re.S):
        out.append((clean(m.group(2)), clean(m.group(3)), m.group(1)))
    return out


def yahoo(q: str):
    body = fetch("https://search.yahoo.com/search?" + urllib.parse.urlencode({"p": q}))
    out = []
    for block in re.split(r'<div class="dd algo', body)[1:]:
        a = re.search(r'<a[^>]*href="([^"]+)"[^>]*>.*?<h3[^>]*class="title[^"]*"[^>]*>(.*?)</h3>', block, re.S)
        if not a:
            continue
        href = html.unescape(a.group(1))
        m = re.search(r"/RU=([^/]+)/", href)
        url = urllib.parse.unquote(m.group(1)) if m else href
        p = re.search(r'<div class="compText[^"]*"[^>]*>\s*<p[^>]*>(.*?)</p>', block, re.S)
        out.append((clean(a.group(2)), clean(p.group(1)) if p else "", url))
    return out


def brave_api(q: str):
    key = os.environ.get("BRAVE_SEARCH_API_KEY", "")
    if not key:
        raise RuntimeError("BRAVE_SEARCH_API_KEY not set")
    import json
    req = urllib.request.Request("https://api.search.brave.com/res/v1/web/search?" + urllib.parse.urlencode({"q": q, "count": MAX}), headers={"Accept": "application/json", "X-Subscription-Token": key})
    with urllib.request.urlopen(req, timeout=15) as r:
        data = json.loads(r.read().decode("utf-8", "replace"))
    return [(clean(x.get("title", "")), clean(x.get("description", "")), x.get("url", "")) for x in (data.get("web") or {}).get("results", [])]


def bing(q: str):
    body = fetch("https://www.bing.com/search?" + urllib.parse.urlencode({"q": q, "setlang": "en", "cc": "US"}))
    out = []
    for block in re.split(r'<li class="b_algo"', body)[1:]:
        block = block.split("</li>")[0]
        a = re.search(r'<h2[^>]*><a[^>]*href="([^"]+)"[^>]*>(.*?)</a>', block, re.S)
        if not a:
            continue
        href = html.unescape(a.group(1))
        u = urllib.parse.parse_qs(urllib.parse.urlparse(href).query).get("u")
        if u and u[0].startswith("a1"):
            import base64
            raw = u[0][2:]
            href = base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)).decode("utf-8", "replace")
        p = re.search(r'<p[^>]*class="b_lineclamp[^"]*"[^>]*>(.*?)</p>', block, re.S) or re.search(r"<p[^>]*>(.*?)</p>", block, re.S)
        out.append((clean(a.group(2)), clean(p.group(1)) if p else "", href))
    return out


def main() -> int:
    q = " ".join(a for a in sys.argv[1:] if not a.startswith("--backend=")).strip() or sys.stdin.read().strip()
    if not q:
        print("ERROR:query is required")
        return 0
    errors = []
    wanted = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1].startswith("--backend=") else ""
    chain = [("brave_api", brave_api)] if os.environ.get("BRAVE_SEARCH_API_KEY") else []
    chain += [("duckduckgo", duckduckgo), ("yahoo", yahoo), ("brave", brave), ("bing", bing)]
    backends = [b for b in chain if not wanted or b[0] == wanted[10:]]
    for name, backend in backends:
        try:
            results = backend(q)
        except Exception as e:  # noqa: BLE001 - every failure is reported, none hides the next backend
            errors.append(f"{name}: {e}")
            continue
        if results:
            with open(ledger_path(), "a") as ledger:
                for _, _, url in results[:MAX]:
                    ledger.write(url + "\n")
            for i, (title, snip, url) in enumerate(results[:MAX], 1):
                print(f"{i}. {title} -- {snip[:200]} -- {url}")
            return 0
        errors.append(f"{name}: no results")
    print("NO_RESULTS" if all(e.endswith("no results") for e in errors) else "ERROR:" + "; ".join(errors))
    return 0


if __name__ == "__main__":
    sys.exit(main())
