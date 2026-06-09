#!/usr/bin/env bash
# proc_cmd Build agent for Sprint 1 (registration API).
#
# First invocation returns code WITHOUT email validation to trigger QA bounce.
# Second invocation (retry) returns code WITH EMAIL_REGEX — passes QA.
#
# Sentinel file tracks which attempt this is.
set -euo pipefail

SENTINEL="/tmp/loom_demo_reg_tried"
DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ -f "$SENTINEL" ]; then
    cat "$DEMO_DIR/code/good_registration_api.py"
else
    touch "$SENTINEL"
    cat "$DEMO_DIR/code/bad_registration_api.py"
fi
