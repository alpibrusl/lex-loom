#!/usr/bin/env python3
# Extract fenced code blocks from an artifact into a directory, for the sprint
# verifier (#47 P0.5) to re-run a node's grounded gate. Handles BOTH fence forms
# agents emit: ```<filename.ext>  and  ```<language> (lex/python/py/...), and in
# the language case prefers an explicit "# filename.ext" comment on the next line.
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

f = None
counter = 0
lines = txt.split("\n")
for i, ln in enumerate(lines):
    s = ln.strip()
    if s.startswith("```") and len(s) > 3:
        tag = s[3:].strip()
        if "." in tag:
            name = re.sub(r"[^A-Za-z0-9._/-]", "", tag)        # a filename
        else:
            ext = LANG_EXT.get(tag.lower(), "txt")              # a language tag
            counter += 1
            name = "file%d.%s" % (counter, ext)
            if i + 1 < len(lines):                              # prefer "# name.ext"
                m = re.match(r"^[#/ ]*([A-Za-z0-9_./-]+\.[A-Za-z0-9]+)\s*$", lines[i + 1].strip())
                if m:
                    name = re.sub(r"[^A-Za-z0-9._/-]", "", m.group(1))
        if name:
            p = os.path.join(d, name)
            os.makedirs(os.path.dirname(p) or d, exist_ok=True)
            f = open(p, "w")
    elif s == "```":
        f = None
    elif f is not None:
        f.write(ln + "\n")
