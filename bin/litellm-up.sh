#!/usr/bin/env bash
# litellm-up.sh — start the default provider: LiteLLM in front of the host's
# ollama. No Docker required.
#
# Docker was never doing anything for us here, and it was actively causing
# problems. Compose derives its project name from the containing DIRECTORY, and
# lex-code has a litellm/ directory too, so both projects were named "litellm":
# `docker compose up -d` in this repo silently ADOPTED lex-code's already
# running container and served ITS config. Measurements taken through that
# proxy — including a whole "LiteLLM is broken for local models" conclusion —
# were measuring another repo's configuration.
#
# The container also reached ollama through host.docker.internal, which is its
# own failure mode (the compose file forgot to pass OLLAMA_BASE_URL, so every
# ollama route resolved to the container's own localhost and failed). As a host
# process, localhost:11434 is simply correct.
#
# Usage:
#   bin/litellm-up.sh                 # port 4000, config.local.yaml
#   LITELLM_PORT=4010 bin/litellm-up.sh
#   LITELLM_CONFIG=litellm/config.yaml bin/litellm-up.sh   # the full roster
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${LITELLM_PORT:-4000}"
CONFIG="${LITELLM_CONFIG:-litellm/config.local.yaml}"
export OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://localhost:11434}"

if ! command -v litellm >/dev/null 2>&1; then
  echo "litellm is not on PATH. Install it as a standalone tool:" >&2
  echo "  uv tool install 'litellm[proxy]'      # or: pipx install 'litellm[proxy]'" >&2
  exit 1
fi

# Refuse rather than fight over the port: something already listening is
# usually another project's proxy, and quietly using it is how the wrong config
# gets measured.
if lsof -ti "tcp:$PORT" >/dev/null 2>&1; then
  holder=$(ps -o comm= -p "$(lsof -ti "tcp:$PORT" | head -1)" 2>/dev/null | tr -d ' ')
  echo "port $PORT is already held by '$holder'." >&2
  echo "If that is another project's LiteLLM, it may be configured differently —" >&2
  echo "check it serves tool calls (bin/check-company-env.sh does), or pick another:" >&2
  echo "  LITELLM_PORT=4010 bin/litellm-up.sh" >&2
  exit 1
fi

if [ ! -f "$CONFIG" ]; then
  echo "no config at $CONFIG" >&2
  exit 1
fi

LOG="${TMPDIR:-/tmp}/loom-litellm-$PORT.log"
nohup litellm --config "$CONFIG" --port "$PORT" > "$LOG" 2>&1 &
pid=$!
echo "[litellm] pid $pid, port $PORT, config $CONFIG, ollama $OLLAMA_BASE_URL"
echo "[litellm] log: $LOG"

for _ in $(seq 1 40); do
  if curl -sf -m 3 "http://localhost:$PORT/health/readiness" >/dev/null 2>&1; then
    echo "[litellm] ready on http://localhost:$PORT"
    exit 0
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "[litellm] exited during startup — last lines of $LOG:" >&2
    tail -15 "$LOG" >&2
    exit 1
  fi
  sleep 3
done
echo "[litellm] did not become ready; see $LOG" >&2
exit 1
