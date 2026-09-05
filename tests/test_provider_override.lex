# test_provider_override.lex — LOOM_PROVIDER must decide the provider (#318).
#
# Merely having ~/.credentials/opencode/key on disk made a local ollama run
# impossible: run-company.sh loads that file into OPENCODE_API_KEY whenever the
# variable is unset, and provider selection then preferred opencode whenever it
# was non-empty. There was no override, so "run this on the local model" could
# only be expressed by moving the operator's credential file — which is not
# something a tool should require of its operator.
#
# These assert the DECISION. std.env is read-only, so a test going through
# make_provider could only observe whatever this machine happens to have
# configured, and would report a different result on a machine without a key.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "../src/roles" as roles

fn case(name :: Str, override :: Str, key :: Str, want :: Str) -> Result[Unit, Str] {
  let got := roles.choose_provider(override, key)
  if got == want {
    Ok(())
  } else {
    Err(str.join([name, ": wanted ", want, ", got ", got], ""))
  }
}

# The point of the change: a key on disk must not override an explicit choice.
fn test_override_beats_a_present_key() -> Result[Unit, Str] {
  case("LOOM_PROVIDER=ollama with a key present", "ollama", "sk-a-key-that-is-present", "ollama")
}

fn test_override_can_also_force_opencode() -> Result[Unit, Str] {
  case("LOOM_PROVIDER=opencode with no key", "opencode", "", "opencode")
}

# An addition, not a replacement: with no override the old behaviour must be
# untouched in BOTH directions, since every existing run depends on it.
fn test_no_override_keeps_the_key_behaviour() -> Result[Unit, Str] {
  match case("no override, key set", "", "sk-a-key-that-is-present", "opencode") {
    Err(e) => Err(e),
    Ok(_) => case("no override, no key", "", "", "ollama"),
  }
}

# A whitespace-only or empty key is not a key. run-company.sh writes the file
# contents through verbatim, so a blank credentials file must not silently
# select a provider that will then fail on every call.
fn test_a_blank_key_is_not_a_key() -> Result[Unit, Str] {
  case("no override, whitespace key", "", "   ", "ollama")
}

# An unrecognised value must defer to the keys rather than silently meaning
# something, and that must be the documented behaviour rather than an accident
# of the match arms.
fn test_an_unknown_value_defers_to_the_keys() -> Result[Unit, Str] {
  match case("unknown override, key set", "not-a-provider", "sk-a-key-that-is-present", "opencode") {
    Err(e) => Err(e),
    Ok(_) => case("unknown override, no key", "not-a-provider", "", "ollama"),
  }
}

# Operators type what they see in docs and shells, so the value must not be
# case- or whitespace-sensitive.
fn test_the_value_is_forgiving_about_case_and_spacing() -> Result[Unit, Str] {
  match case("uppercase", "OLLAMA", "sk-a-key-that-is-present", "ollama") {
    Err(e) => Err(e),
    Ok(_) => case("padded", "  ollama  ", "sk-a-key-that-is-present", "ollama"),
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_override_beats_a_present_key(), test_override_can_also_force_opencode(), test_no_override_keeps_the_key_behaviour(), test_a_blank_key_is_not_a_key(), test_an_unknown_value_defers_to_the_keys(), test_the_value_is_forgiving_about_case_and_spacing()]
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

