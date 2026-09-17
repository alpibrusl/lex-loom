#!/usr/bin/env bash
# Argument shim for bin/check_research_report.lex — see bin/extract-fenced.sh
# for why the quoting lives here and not at the call site.
set -uo pipefail
# `lex run` prints main's Int return on its own line after the program's own
# output. For a checker whose stdout IS the message a role has to act on, that
# stray "0"/"1" is noise appended to the refusal. Drop a trailing bare integer;
# every checker here ends its real output with prose.
drop_rc() { sed -e '$ { /^[0-9][0-9]*$/d; }'; }
jsonarg() { printf '"%s"' "$(printf '%s' "${1-}" | sed 's/^"*//; s/"*$//')"; }
out=$(lex run --allow-effects env,fs_read,fs_walk,io "$(dirname "$0")/check_research_report.lex" main \
        "$(jsonarg "${1-.}")" 2>&1)
printf '%s\n' "$out" | drop_rc
grep -q '^RESEARCH_REPORT_OK' <<<"$out"
