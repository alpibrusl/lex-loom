# toml_get.lex — the manifest fields loom's shell scripts read.
#
# Deliberately a FIXED set of paths, not a generic dotted-path reader, because
# std.toml decodes into a typed record and an `Option` field cannot be
# expressed at all: absent raises "missing field", present arrives unwrapped
# and panics a `Some` match (alpibrusl/lex-lang#905). Every path here is a
# REQUIRED field, which is exactly the set that works today -- and, as it
# happens, every path the one-liners actually read: `identity.mission` twelve
# times and `stack.path` three.
#
# When #905 lands this grows a generic reader and bootstrap-company.sh's
# 110-line tomllib program can follow. Until then, promising more than this
# would mean a checker that works on a full manifest and dies on a sparse one.

import "std.str" as str

import "std.io" as io

import "std.toml" as toml

import "std.list" as list

import "std.map" as map

import "std.int" as int

type Identity = { id :: Str, mission :: Str }

type Stack = { path :: Str, model :: Str }

type Manifest = { identity :: Identity, stack :: Stack }

# An OPTIONAL field, read by trying a parse that requires it. std.toml cannot
# express Option (lex-lang#905): a missing key fails the whole parse. So the
# failure IS the answer -- parse with a record that demands the field, and an
# Err means "absent, use the caller's default". One extra parse of the same
# text per optional field, which is the honest price until #905 lands, and it
# is correct rather than clever.
type PolicyMax = { max_iterations :: Int }

type WithPolicy = { policy :: PolicyMax }

type RolesPacks = { packs :: List[Str] }

type WithRoles = { roles :: RolesPacks }

type WithModels = { models :: Map[Str, Str] }

fn optional(text :: Str, field :: Str, fallback :: Str) -> Str {
  if field == "policy.max_iterations" {
    let r :: Result[WithPolicy, Str] := toml.parse(text)
    match r {
      Err(_) => fallback,
      Ok(m) => int.to_str(m.policy.max_iterations),
    }
  } else {
    if field == "roles.packs" {
      let r :: Result[WithRoles, Str] := toml.parse(text)
      match r {
        Err(_) => fallback,
        Ok(m) => str.join(m.roles.packs, ","),
      }
    } else {
      if field == "models" {
        let r :: Result[WithModels, Str] := toml.parse(text)
        match r {
          Err(_) => fallback,
          Ok(m) => str.join(list.map(map.keys(m.models), fn (k :: Str) -> Str {
            match map.get(m.models, k) {
              None => "",
              Some(v) => str.join([k, ":", v], ""),
            }
          }), ","),
        }
      } else {
        fallback
      }
    }
  }
}

fn main(path :: Str, field :: Str, fallback :: Str) -> [fs_read, io] Int {
  match io.read(path) {
    Err(_) => 1,
    Ok(text) => {
      let parsed :: Result[Manifest, Str] := toml.parse(text)
      match parsed {
        Err(_) => 1,
        Ok(m) => {
          let v := if field == "identity.id" {
            m.identity.id
          } else {
            if field == "identity.mission" {
              m.identity.mission
            } else {
              if field == "stack.path" {
                m.stack.path
              } else {
                if field == "stack.model" {
                  m.stack.model
                } else {
                  optional(text, field, fallback)
                }
              }
            }
          }
          if str.is_empty(v) {
            if str.is_empty(fallback) {
              1
            } else {
              let __d := io.print(fallback)
              0
            }
          } else {
            let __ := io.print(v)
            0
          }
        },
      }
    },
  }
}

