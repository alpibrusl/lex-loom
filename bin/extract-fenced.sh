#!/usr/bin/env bash
# Argument shim for bin/extract_fenced.lex.
#
# `lex run` takes each argument as JSON, so a Str arrives quoted. Doing that
# quoting at four call sites -- three of them inside Lex string literals that
# already escape their own quotes -- is how `""/tmp/goal.txt""` happened to the
# PRD gate and cost a 0/20 measurement. One shim, quoted once, called plainly.
#
# Runs from loom's root because `lex run` resolves packages from the working
# directory, and every caller already invokes it from there.
set -uo pipefail
jsonarg() { printf '"%s"' "$(printf '%s' "${1-}" | sed 's/^"*//; s/"*$//')"; }
exec lex run --allow-effects fs_read,fs_write,io "$(dirname "$0")/extract_fenced.lex" main \
  "$(jsonarg "${1:?artifact path}")" "$(jsonarg "${2:?output dir}")"
