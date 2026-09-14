#!/usr/bin/env bash
# gc1-iteration-commits.sh -- what an iteration built is in the company's own
# repo, so `[infra] repo` can publish something more than a skeleton.
#
# Until now bootstrap made the ONLY commit a company ever made: after four
# iterations, formcolocal's workspace repo still held "Scaffold formcolocal
# from company.toml" and nothing else (2026-09-14). This proves the other end:
# a company that produced files commits them, with the verdict in the message;
# a company that produced nothing commits nothing; and a goal full of shell
# metacharacters is a commit message, not a command.
#
# Run from the repo root:  bash demo/gc1-iteration-commits.sh
set -uo pipefail
cd "$(dirname "$0")/.."
E="approval,concurrent,crypto,env,fs_read,fs_write,io,llm,net,proc,random,sql,stream,time,vcs"
WS="$(mktemp -d "${TMPDIR:-/tmp}/loom-gc1.XXXXXX")"; trap 'rm -rf "$WS"' EXIT
pass=0; fail=0
ok()  { echo "   OK: $1"; pass=$((pass+1)); }
bad() { echo "   FAIL: $1"; fail=$((fail+1)); }
say() { printf '\n== %s\n' "$*"; }

cat > "$WS/probe.lex" <<'LEX'
import "std.io" as io
import "std.env" as env
import "../src/company" as company

fn get(k :: Str) -> [env] Str {
  match env.get(k) {
    Some(v) => v,
    None => "",
  }
}

fn main() -> [env, io, proc] Unit {
  company.commit_iteration(get("CID"), 2, get("STATUS"), get("GOAL"))
}
LEX
cp "$WS/probe.lex" demo/gc1_probe.lex

say "1. a company that built something commits it, with the verdict in the message"
mkdir -p "$WS/gc1co"
( cd "$WS/gc1co" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "Scaffold gc1co" )
printf 'fn main() -> Unit { () }\n' > "$WS/gc1co/main.lex"
LOOM_WORKSPACE="$WS" CID=gc1co STATUS=passed GOAL='build the form endpoint' lex run --max-steps 0 --allow-effects "$E" demo/gc1_probe.lex main >/dev/null 2>&1
MSG="$(git -C "$WS/gc1co" log --format=%s -1)"
[ "$(git -C "$WS/gc1co" log --oneline | wc -l | tr -d ' ')" = "2" ] && ok "the iteration is a second commit" || bad "no commit was made"
[[ "$MSG" == "iteration 2: passed -- build the form endpoint" ]] && ok "the message names the iteration, the verdict and the goal" || bad "message was: $MSG"
git -C "$WS/gc1co" log -1 --format='%an' | grep -q gc1co && ok "authored as the company, not as whoever runs the machine" || bad "author: $(git -C "$WS/gc1co" log -1 --format='%an')"

say "2. nothing built, nothing committed"
LOOM_WORKSPACE="$WS" CID=gc1co STATUS=failed GOAL='nothing changed' lex run --max-steps 0 --allow-effects "$E" demo/gc1_probe.lex main >/dev/null 2>&1
[ "$(git -C "$WS/gc1co" log --oneline | wc -l | tr -d ' ')" = "2" ] && ok "an iteration with no changes adds no empty commit" || bad "an empty commit was made"

say "3. a goal is a message, not a command"
CANARY="$WS/canary"; : > "$CANARY"
printf 'fn other() -> Unit { () }\n' > "$WS/gc1co/other.lex"
LOOM_WORKSPACE="$WS" CID=gc1co STATUS=passed GOAL="build it\"; rm -f $CANARY; echo \"" lex run --max-steps 0 --allow-effects "$E" demo/gc1_probe.lex main >/dev/null 2>&1
[ -f "$CANARY" ] && ok "the metacharacters in the goal never reached a shell" || bad "the injected command ran"
git -C "$WS/gc1co" log --format=%s -1 | grep -q 'rm -f' && ok "and they are in the commit message, verbatim" || bad "message lost the text: $(git -C "$WS/gc1co" log --format=%s -1)"
[ -f "$WS/gc1co/.loom-commit-msg" ] && bad "the message file was left behind" || ok "the message file is cleaned up"

say "4. a workspace that is not a repo is not an error"
mkdir -p "$WS/plainco"
LOOM_WORKSPACE="$WS" CID=plainco STATUS=passed GOAL='no repo here' lex run --max-steps 0 --allow-effects "$E" demo/gc1_probe.lex main >/dev/null 2>&1
[ $? -eq 0 ] && ok "a non-repo workspace is skipped quietly" || bad "it failed on a workspace with no .git"

rm -f demo/gc1_probe.lex
printf '\n== %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
