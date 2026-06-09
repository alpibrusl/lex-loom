#!/usr/bin/env bash
# proc_cmd Scribe agent — outputs a deterministic Sprint 1 Digest JSON.
#
# The tightened spec targets the "build" role with gate "spec contains EMAIL_REGEX".
# Sprint 2's Architect receives this via specs_context and sets that gate on its
# Build node — so Sprint 2 Build is checked BEFORE QA even runs.
set -euo pipefail

cat <<'EOF'
{
  "summary": "Sprint 1 delivered a Python Flask user registration API with email/password authentication. The implementation initially lacked email format validation — QA caught the gap with run_code assertions, rejecting strings like 'notanemail' without error. The build agent corrected the omission on its first retry, adding an EMAIL_REGEX check that returns HTTP 422 for malformed addresses. The final API is correct, with proper status codes and duplicate-email detection.",
  "lessons": "Email fields require a regex format gate at the Build stage, not just at QA. The one-retry bounce was avoidable: had the Build node's gate checked for EMAIL_REGEX presence, the defect would have been caught before QA ran.",
  "tightened_specs": [
    {
      "node_role": "build",
      "spec_src": "spec contains EMAIL_REGEX",
      "reason": "Sprint 1 QA bounce: build output lacked email format validation. Gate fires at the Build stage — before QA — preventing the same defect from reaching review in future sprints."
    }
  ],
  "seed_graph": {
    "id": "demo-sprint-1-next-seed",
    "phase": "Intake",
    "nodes": [
      {"id": "build", "role": "build", "gate": "spec contains EMAIL_REGEX"},
      {"id": "qa",    "role": "qa",    "gate": "spec json-verdict-pass"}
    ],
    "edges": [
      {"from": "build", "to": "qa", "handoff": "schema {}"}
    ]
  }
}
EOF
