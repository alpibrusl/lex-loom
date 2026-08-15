#!/usr/bin/env bash
# org3_reviewer.sh — the demo's eng_manager verdict, as a proc executor.
#
# Reads the review prompt on stdin (task + the report's submitted artifact).
# A first attempt is returned with notes; a resubmission — whose artifact
# visibly carries the REWORK frame the drain adds on rework rounds — is
# accepted. Deterministic and offline, so the demo can prove the full
# return -> rework -> accept-the-redo cycle without an LLM.
if grep -q "REWORK:" -; then
  echo '{"verdict": "accept", "notes": "the rework addressed my notes"}'
else
  echo '{"verdict": "return", "notes": "first draft too thin - add usage examples"}'
fi
