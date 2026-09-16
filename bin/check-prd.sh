#!/usr/bin/env bash
# Exit-code shim for bin/check_prd.lex.
#
# `lex run` exits 0 whatever main returns -- a checker written in Lex can print
# its refusal but cannot BE a refusal (lex-lang issue filed). A `spec sh` gate
# signals through exit status, so the verdict has to become one here. When lex
# run propagates an Int main, this file collapses to the lex run line.
#
# Deliberately three lines: everything a reviewer needs to reason about is in
# the .lex file, where lex check --strict, lex fmt and lex test reach it. None
# of the ten bin/check_*.py checkers -- 1502 lines -- are reached by any of them.
set -uo pipefail
out=$(lex run --allow-effects fs_read,io "$(dirname "$0")/check_prd.lex" main "\"${1:?prd path}\"" "\"${2-}\"" 2>&1)
echo "$out"
grep -q '^ACCEPT' <<<"$out"
