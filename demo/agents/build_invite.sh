#!/usr/bin/env bash
# proc_cmd Build agent for Sprint 2 (team invite API).
#
# Always returns the invite API which contains EMAIL_REGEX — satisfies the
# tightened gate inherited from Sprint 1's Digest on the first attempt.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cat "$DEMO_DIR/code/invite_api.py"
