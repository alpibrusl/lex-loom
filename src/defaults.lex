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

# The ONE resolution chain for a bare invocation's model: MODEL, then the
# legacy OLLAMA_MODEL, then NOTHING. There is deliberately no fallback model
# here any more. A default meant that forgetting to set MODEL did not fail --
# it quietly ran somebody else's model, billed somebody's key, on a name the
# operator never chose. That is the same failure #427 removed for providers
# (an ambient MISTRAL_API_KEY sent prod ResearchCo to Mistral), and the model
# deserves the same rule: it is a named decision or it is nothing.
#
# The empty string means "not chosen". Callers must refuse rather than
# substitute; bin/run-company.sh and bin/bootstrap-company.sh refuse first,
# before any Lex runs, so the usual paths never reach here unset.
fn resolved_model() -> [env] Str {
  get_env("MODEL", get_env("OLLAMA_MODEL", ""))
}

fn model_is_set(m :: Str) -> Bool
  examples {
    model_is_set("kimi-k2.7-code") => true,
    model_is_set("") => false
  }
{
  not str.is_empty(m)
}

# The one resolution for EXEC_MODE ("inline" unless the environment says
# otherwise) — shared by run_sprint_cmd, the company iteration loop, and
# dump-config (#247).
fn resolved_exec_mode() -> [env] Str {
  get_env("EXEC_MODE", "inline")
}

