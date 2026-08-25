# defaults.lex — the ONE place loom's fallback model lives (#242).
#
# Before this, the default model was scattered and inconsistent: main.lex
# said gemma4:latest, worker.lex said claude-haiku-4-5-20251001,
# run-company.sh said gemma4:latest, and the README recommended
# qwen3-coder:30b. A worker falling back to a DIFFERENT model than the
# orchestrator that enqueued the job is exactly the kind of silent drift a
# single source prevents.
#
# The default only matters for bare invocations — every bootstrapped company
# carries its model in company.toml, every enqueued node-job carries the
# sprint's model in its payload, and the MODEL / OLLAMA_MODEL environment
# variables always override. The value is the current local recommendation
# (see the README's model table) — it must name a model that actually exists,
# since a bare invocation has nothing else to fall back to.

import "std.env" as env

import "std.str" as str

fn get_env(key :: Str, default :: Str) -> [env] Str {
  match env.get(key) {
    None => default,
    Some(v) => if str.is_empty(v) {
      default
    } else {
      v
    },
  }
}

fn model() -> Str
  examples {
    model() => "qwen3.8:27b-mlx"
  }
{
  "qwen3.8:27b-mlx"
}

# The ONE resolution chain for a bare invocation's model: MODEL, then the
# legacy OLLAMA_MODEL, then the fallback above. main.lex's three entry
# points and dump-config (#247) all call this — the dump explains the very
# resolution the runtime performs, because it IS the runtime's resolution.
fn resolved_model() -> [env] Str {
  get_env("MODEL", get_env("OLLAMA_MODEL", model()))
}

# The one resolution for EXEC_MODE ("inline" unless the environment says
# otherwise) — shared by run_sprint_cmd, the company iteration loop, and
# dump-config (#247).
fn resolved_exec_mode() -> [env] Str {
  get_env("EXEC_MODE", "inline")
}

