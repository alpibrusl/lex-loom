#!/usr/bin/env python3
# Extract fenced code blocks from an artifact into a directory, for the sprint
# verifier (#47 P0.5) to re-run a node's grounded gate, and for the Company
# layer's project-dir sync (company.sync_project_dir). Handles the fence forms
# agents emit: ```<filename.ext>  and  ```<language> (lex/python/py/...). In the
# language case, the filename is looked for, in order: an explicit
# "# filename.ext" comment on the next line; then a markdown heading/table-row
# naming the file on one of the few lines immediately BEFORE the fence (e.g.
# "### `app.py`" or "| `app.py` | ... |") — some models label a file this way
# instead of on the fence line itself, and missing this caused real files to
# fall back to generic file1.py/file2.py names, which then silently mismatch
# whatever a later step (e.g. a Dockerfile's COPY) expects by real filename.
import sys
import re
import os

txt = open(sys.argv[1]).read()
d = sys.argv[2]
os.makedirs(d, exist_ok=True)

LANG_EXT = {
    "lex": "lex", "python": "py", "py": "py", "sh": "sh", "bash": "sh",
    "javascript": "js", "js": "js", "html": "html", "css": "css",
    "json": "json", "yaml": "yml", "yml": "yml", "toml": "toml",
}

# Fence tags that are themselves the canonical, extension-less filename a real
# tool looks for (docker build wants a file literally named "Dockerfile", not
# "file1.txt"). Without this, `spec sh "docker build ..."` on a devops node's
# ```Dockerfile fence always misses since "dockerfile" has no "." and isn't in
# LANG_EXT, so it fell through to the generic file1.txt name (#21).
NO_EXT_FILENAME = {
    "dockerfile": "Dockerfile", "makefile": "Makefile", "procfile": "Procfile",
}

# A filename appearing backtick-quoted or as a lone heading/table-cell token,
# e.g. "### `app.py`", "**app.py**", "| `app.py` | ... |", "# app.py".
HEADING_NAME_RE = re.compile(r"[`*#|]\s*([A-Za-z0-9_./-]+\.[A-Za-z0-9]+)\s*[`*|]?")

LOOKBACK_LINES = 5


def find_heading_name(lines, fence_idx):
    for j in range(fence_idx - 1, max(-1, fence_idx - 1 - LOOKBACK_LINES), -1):
        candidate = lines[j].strip()
        if not candidate:
            continue
        m = HEADING_NAME_RE.search(candidate)
        if m:
            return m.group(1)
        # A non-empty, non-heading-like line breaks the lookback — the
        # filename label (if any) is always right above the fence, not
        # buried further up in unrelated prose.
        if not candidate.startswith(("#", "*", "|", "-")):
            break
    return None


f = None
counter = 0
lines = txt.split("\n")
for i, ln in enumerate(lines):
    s = ln.strip()
    if s.startswith("```") and len(s) > 3:
        tag = s[3:].strip()
        if "." in tag:
            name = re.sub(r"[^A-Za-z0-9._/-]", "", tag)        # a filename
        elif tag.lower() in NO_EXT_FILENAME:
            name = NO_EXT_FILENAME[tag.lower()]                 # e.g. ```Dockerfile
        else:
            ext = LANG_EXT.get(tag.lower(), "txt")              # a language tag
            counter += 1
            name = "file%d.%s" % (counter, ext)
            if i + 1 < len(lines):                              # prefer "# name.ext"
                m = re.match(r"^[#/ ]*([A-Za-z0-9_./-]+\.[A-Za-z0-9]+)\s*$", lines[i + 1].strip())
                if m:
                    name = re.sub(r"[^A-Za-z0-9._/-]", "", m.group(1))
                else:
                    heading_name = find_heading_name(lines, i)
                    if heading_name:
                        name = re.sub(r"[^A-Za-z0-9._/-]", "", heading_name)
        if name:
            p = os.path.join(d, name)
            os.makedirs(os.path.dirname(p) or d, exist_ok=True)
            f = open(p, "w")
    elif s == "```":
        f = None
    elif f is not None:
        f.write(ln + "\n")
