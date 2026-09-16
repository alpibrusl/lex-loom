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

# lex run takes each argument as JSON, so a Str argument arrives quoted. A gate
# string that ALSO quotes it produces `""/tmp/goal.txt""` and lex refuses the
# argument -- which the harness reports as "gate command failed", i.e. as a
# refusal of the ROLE. The pm scored 0/20 that way while the same artifacts
# accepted 46/46 by hand.
#
# Stripping stray quotes here rather than fixing one gate string: the quoting
# lives in a prompt, an architect can emit either form, and every checker
# ported under lex-loom#512 inherits the same trap. A wrapper that only works
# for one spelling of its own call is a wrapper that will be called the other
# way.
jsonarg() { printf '"%s"' "$(printf '%s' "${1-}" | sed 's/^"*//; s/"*$//')"; }

out=$(lex run --allow-effects fs_read,io "$(dirname "$0")/check_prd.lex" main \
        "$(jsonarg "${1:?prd path}")" "$(jsonarg "${2-}")" 2>&1)
echo "$out"
grep -q '^ACCEPT' <<<"$out"
