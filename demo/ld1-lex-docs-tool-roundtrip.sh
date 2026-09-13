#!/usr/bin/env bash
# ld1-lex-docs-tool-roundtrip.sh -- the lex_docs tool, offline (no LLM):
# a Lex package describes itself, and the roles that write Lex are the ones
# holding the tool.
#
#   1. the tool is granted to build / test_author / qa and to nobody else,
#      and survives their operator preset (a tool stripped by the preset is
#      a tool the agent never sees -- #444's analytics bug);
#   2. package alone returns the module INDEX of a really-installed package;
#   3. package+module returns that module's real API, with functions the
#      package actually exports;
#   4. package='stdlib' returns the stdlib index;
#   5. a made-up package/module answers with what IS available, never an
#      empty result;
#   6. an injection attempt in either name is refused, and the shell never
#      runs it.
#
# Run from the repo root:  bash demo/ld1-lex-docs-tool-roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export MODEL="${MODEL:-qwen3.8:27b-mlx}"
E="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,stream,time,vcs"
WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-ld1.XXXXXX")"; trap 'rm -rf "$WS"' EXIT
pass=0; fail=0
say() { printf '\n== %s\n' "$*"; }
ok()  { echo "   OK: $*"; pass=$((pass+1)); }
bad() { echo "   FAIL: $*"; fail=$((fail+1)); }

say "1. the tool is granted to the roles that write Lex, and survives their preset"
OUT="$(lex run --max-steps 0 --allow-effects "$E" demo/ld1_probe.lex grants_cmd 2>&1)"
for r in build test_author qa; do
  echo "$OUT" | grep -q "^$r: .*lex_docs" && ok "$r holds lex_docs after its preset" || bad "$r lost lex_docs: $OUT"
done
echo "$OUT" | grep -q '^py_build: .*lex_docs' && bad "a Python role was granted a Lex tool" || ok "py_build was not granted it"

say "2. package alone: the module index of an installed package"
OUT="$(PACKAGE=lex-web lex run --max-steps 0 --allow-effects "$E" demo/ld1_probe.lex docs_cmd 2>&1)"
echo "$OUT" | grep -q 'MODULES IN lex-web' && ok "answers with the module index" || bad "no index: $(echo "$OUT" | head -3)"
echo "$OUT" | grep -qE 'router \([0-9]+ fn\)' && ok "names router with its function count" || bad "router missing from the index"
echo "$OUT" | grep -q 'call lex_docs again with module=' && ok "tells the agent how to narrow" || bad "no narrowing hint"

say "3. package+module: the module's real API"
OUT="$(PACKAGE=lex-web MODULE=body lex run --max-steps 0 --allow-effects "$E" demo/ld1_probe.lex docs_cmd 2>&1)"
echo "$OUT" | grep -q 'API docs for lex-web' && ok "answers with the package's own API docs" || bad "no API docs: $(echo "$OUT" | head -3)"
echo "$OUT" | grep -q 'form_body' && ok "carries form_body -- a real lex-web function" || bad "form_body missing"
OUT="$(PACKAGE=lex-web MODULE=body.lex lex run --max-steps 0 --allow-effects "$E" demo/ld1_probe.lex docs_cmd 2>&1)"
echo "$OUT" | grep -q 'API docs for lex-web' && ok "a module written 'body.lex' resolves too" || bad "body.lex not accepted"

say "4. stdlib -- including the way an agent actually asks for it"
OUT="$(PACKAGE=std.str lex run --max-steps 0 --allow-effects "$E" demo/ld1_probe.lex docs_cmd 2>&1)"
# The live run asked for package="std.str" / "std.list" / "std.map" and was
# told "no package is installed", which is true and useless: std is not a
# package, and that is the tool's problem, not the agent's.
{ echo "$OUT" | grep -q 'SIGNATURES IN std.str' && echo "$OUT" | grep -q 'str.split'; } && ok "package='std.str' answers with str's real signatures" || bad "std.str not understood: $(echo "$OUT" | head -2)"
OUT="$(PACKAGE=std.nosuch lex run --max-steps 0 --allow-effects "$E" demo/ld1_probe.lex docs_cmd 2>&1)"
echo "$OUT" | grep -q 'call lex_docs with package=stdlib' && ok "an unknown std module points at the index" || bad "unknown std module unhelpful: $OUT"

OUT="$(PACKAGE=stdlib lex run --max-steps 0 --allow-effects "$E" demo/ld1_probe.lex docs_cmd 2>&1)"
echo "$OUT" | grep -q 'std.str' && ok "stdlib index returned" || bad "no stdlib index: $(echo "$OUT" | head -3)"

say "5. an unknown name answers with what IS available"
OUT="$(PACKAGE=lex-fastapi lex run --max-steps 0 --allow-effects "$E" demo/ld1_probe.lex docs_cmd 2>&1)"
{ echo "$OUT" | grep -q "no package 'lex-fastapi' is installed" && echo "$OUT" | grep -q 'lex-web'; } && ok "unknown package lists the installed ones" || bad "unhelpful miss: $(echo "$OUT" | head -3)"
OUT="$(PACKAGE=lex-web MODULE=nosuchmodule lex run --max-steps 0 --allow-effects "$E" demo/ld1_probe.lex docs_cmd 2>&1)"
{ echo "$OUT" | grep -q "no module 'nosuchmodule'" && echo "$OUT" | grep -q 'router'; } && ok "unknown module lists the real ones" || bad "unhelpful module miss: $(echo "$OUT" | head -3)"

say "6. injection is refused, not escaped"
CANARY="$WS/canary"; : > "$CANARY"
OUT="$(PACKAGE="lex-web'; rm -f $CANARY; echo '" lex run --max-steps 0 --allow-effects "$E" demo/ld1_probe.lex docs_cmd 2>&1)"
echo "$OUT" | grep -q 'must be a bare package name' && ok "a quoted package name is refused" || bad "injection not refused: $(echo "$OUT" | head -3)"
[ -f "$CANARY" ] && ok "the injected command never ran" || bad "the shell ran the injected command"
OUT="$(PACKAGE=lex-web MODULE='../../../../etc/passwd' lex run --max-steps 0 --allow-effects "$E" demo/ld1_probe.lex docs_cmd 2>&1)"
echo "$OUT" | grep -q 'must be a bare module name' && ok "path traversal in module is refused" || bad "traversal not refused: $(echo "$OUT" | head -3)"

say "7. a second read of the same module costs one line, not 20 KB"
SP="ld1-$$"
rm -f "/tmp/loom-lexdocs-$SP.txt"
FIRST="$(SPRINT=$SP PACKAGE=lex-web MODULE=body lex run --max-steps 0 --allow-effects "$E" demo/ld1_probe.lex docs_cmd 2>&1)"
SECOND="$(SPRINT=$SP PACKAGE=lex-web MODULE=body lex run --max-steps 0 --allow-effects "$E" demo/ld1_probe.lex docs_cmd 2>&1)"
echo "$FIRST" | grep -q 'API docs for lex-web' && ok "the first read is the real API" || bad "first read wrong: $(echo "$FIRST" | head -2)"
echo "$SECOND" | grep -q 'You already read lex-web/body in this node' && ok "the second says so instead of repeating itself" || bad "the second read repeated the docs"
[ "$(printf '%s' "$SECOND" | wc -c)" -lt "$(printf '%s' "$FIRST" | wc -c)" ] && ok "and it is far shorter ($(printf '%s' "$SECOND" | wc -c | tr -d ' ') vs $(printf '%s' "$FIRST" | wc -c | tr -d ' ') bytes)" || bad "the repeat was not shorter"
OTHER="$(SPRINT=$SP PACKAGE=lex-web MODULE=router lex run --max-steps 0 --allow-effects "$E" demo/ld1_probe.lex docs_cmd 2>&1)"
echo "$OTHER" | grep -q 'API docs for lex-web' && ok "a different module still reads in full" || bad "a new module was suppressed"
NEWNODE="$(SPRINT=ld1-other-$$ PACKAGE=lex-web MODULE=body lex run --max-steps 0 --allow-effects "$E" demo/ld1_probe.lex docs_cmd 2>&1)"
echo "$NEWNODE" | grep -q 'API docs for lex-web' && ok "and another node starts fresh" || bad "the memo leaked across nodes"
rm -f "/tmp/loom-lexdocs-$SP.txt" "/tmp/loom-lexdocs-ld1-other-$$.txt"

printf '\n== %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
