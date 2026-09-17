#!/usr/bin/env bash
# One required field out of a company.toml. Replaces
# `python3 -c 'import tomllib,sys; print(tomllib.load(open(...,"rb"))["a"]["b"])'`.
#
#   toml-get.sh <manifest> identity.mission
#   toml-get.sh <manifest> policy.max_iterations 3      # optional, with default
#
# Required: identity.id, identity.mission, stack.path, stack.model.
# Optional (a third argument is the default): policy.max_iterations,
# roles.packs, models.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_jsonarg.inc"
run_lex lex run --allow-effects fs_read,io "$HERE/toml_get.lex" main \
  "$(jsonarg "${1:?manifest path}")" "$(jsonarg "${2:?field}")" "$(jsonarg "${3-}")"
