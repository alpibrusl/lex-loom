#!/usr/bin/env bash
# A stand-in for an external service. See bin/fixture_server.lex.
#   FIXTURE_PORT=8099 FIXTURE_PATH=/loom/support FIXTURE_BODY='{"items":[]}' fixture-server.sh &
set -uo pipefail
exec lex run --allow-effects env,net,io,fs_read,fs_write "$(cd "$(dirname "$0")" && pwd)/fixture_server.lex" main
