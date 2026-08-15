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
# variables always override. The value follows the README's recommendation
# for local runs (best tool-calling reliability under loom's 10+-tool
# schemas; see "With Ollama via LiteLLM").

fn model() -> Str
  examples {
    model() => "qwen3-coder:30b"
  }
{
  "qwen3-coder:30b"
}

