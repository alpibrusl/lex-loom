# test_provider_override.lex — the provider is a named decision, never an
# ambient one (#318, #427).
#
# #318: merely having ~/.credentials/opencode/key on disk made a local run
# impossible, because provider selection preferred opencode whenever that
# key was non-empty. LOOM_PROVIDER was added so the operator could name the
# provider outright.
#
# #427: the same flaw one layer down. With no LOOM_PROVIDER, selection fell
# through Vertex, Anthropic, OpenAI, Google and Mistral keys before reaching
# the LiteLLM default. The production runner's shell exported
# MISTRAL_API_KEY for an unrelated tool; the company the founder queued for
# the local model went to Mistral with a model id Mistral does not route,
# every call returned HTTP 400, and the dashboard said "unparseable
# strategist reply" three seconds in. Now: an explicit LOOM_PROVIDER, an
# MLX_URL (an endpoint, which is the operator naming a server), or the
# LiteLLM default. No credential decides anything.
#
# These assert the DECISION. std.env is read-only, so a test going through
# make_provider could only observe whatever this machine happens to have
# configured, and would report a different result on a machine with a key.

import "std.str" as str

import "std.list" as list

import "../src/roles" as roles

fn case(name :: Str, override :: Str, mlx_url :: Str, want :: Str) -> Result[Unit, Str] {
  let got := roles.choose_provider(override, mlx_url)
  if got == want {
    Ok(())
  } else {
    Err(str.join([name, ": wanted ", want, ", got ", got], ""))
  }
}

# The DEFAULT is LiteLLM in front of the local model. It used to be
# ollama-direct, which meant a run with nothing configured quietly executed
# against whatever local model happened to be installed instead of saying
# it was unconfigured; the preflight in run-company.sh now proves the
# default answers before a company starts.
fn test_the_default_is_litellm() -> Result[Unit, Str] {
  case("nothing configured", "", "", "litellm")
}

# The point of #318: an explicit choice wins over everything.
fn test_override_names_the_provider() -> Result[Unit, Str] {
  match case("LOOM_PROVIDER=ollama", "ollama", "", "ollama") {
    Err(e) => Err(e),
    Ok(_) => match case("LOOM_PROVIDER=opencode", "opencode", "", "opencode") {
      Err(e) => Err(e),
      Ok(_) => case("LOOM_PROVIDER=litellm with an MLX_URL present", "litellm", "http://localhost:8082", "litellm"),
    },
  }
}

# The point of #427: every vendor is reachable, but only by name. The
# decision takes no vendor key at all, so there is nothing an ambient
# credential could influence; this pins the names the operator may use.
fn test_vendors_are_explicit_only() -> Result[Unit, Str] {
  let vendors := ["vertex", "anthropic", "openai", "google", "mistral", "mlx"]
  list.fold(vendors, Ok(()), fn (acc :: Result[Unit, Str], v :: Str) -> Result[Unit, Str] {
    match acc {
      Err(e) => Err(e),
      Ok(_) => case(str.concat("LOOM_PROVIDER=", v), v, "", v),
    }
  })
}

# Case and whitespace in the variable are not a different provider.
fn test_override_is_normalised() -> Result[Unit, Str] {
  case("LOOM_PROVIDER=' Mistral '", " Mistral ", "", "mistral")
}

# MLX_URL names an endpoint, which is the operator saying "this local
# server"; it selects MLX when nothing is named, and loses to a name.
fn test_mlx_url_selects_mlx_unless_named_otherwise() -> Result[Unit, Str] {
  match case("no override, MLX_URL set", "", "http://localhost:8082", "mlx") {
    Err(e) => Err(e),
    Ok(_) => case("no override, blank MLX_URL", "", "   ", "litellm"),
  }
}

# An unrecognised value must defer to the default rather than silently
# meaning something, and the startup line then shows what was chosen.
fn test_an_unknown_value_defers_to_the_default() -> Result[Unit, Str] {
  match case("unknown override", "not-a-provider", "", "litellm") {
    Err(e) => Err(e),
    Ok(_) => case("unknown override, MLX_URL set", "not-a-provider", "http://localhost:8082", "mlx"),
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_the_default_is_litellm(), test_override_names_the_provider(), test_vendors_are_explicit_only(), test_override_is_normalised(), test_mlx_url_selects_mlx_unless_named_otherwise(), test_an_unknown_value_defers_to_the_default()]
}

fn run_all() -> Unit {
  let failures := list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
  if failures == 0 {
    ()
  } else {
    let __force_fail := 1 / 0
    ()
  }
}

