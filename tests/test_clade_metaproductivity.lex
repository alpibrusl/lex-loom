# test_clade_metaproductivity.lex — the improver forks from the agent whose
# LINEAGE performs, not the one whose own score is highest.
#
# arXiv 2510.21614 (Huxley-Godel Machine, ICLR 2026) names the failure it is
# avoiding: the Metaproductivity-Performance Mismatch. An agent with the best
# immediate benchmark score is often not the one whose descendants go on to
# perform, so a search that always expands the current leader keeps forking
# from a dead end. HGM scores a candidate by the aggregated performance of its
# whole clade and expands that instead; DGM, which expanded on immediate score,
# needed more CPU-hours to do worse.
#
# loom was answering "who does the work" and "who is worth forking from" with
# one number, attestation_count. Execution still takes the best performer. The
# improver now takes the best clade, walking agent_pool.parent_id (#487).
#
# The scoring is pure, so the mismatch can be set up exactly rather than hoped
# for: a high scorer with no descendants against a mediocre agent whose
# children did well.

import "std.str" as str

import "std.list" as list

import "std.io" as io

import "../src/improver" as improver

fn agent(id :: Str, parent :: Str, count :: Int) -> improver.PoolAgent {
  { id: id, parent_id: parent, attestation_count: count }
}

fn seed_of(agents :: List[improver.PoolAgent]) -> Str {
  match improver.best_seed(agents) {
    None => "",
    Some(id) => id,
  }
}

# The mismatch itself: `flashy` outscores everyone and has left nothing behind;
# `dull` scored less but its two children are the ones carrying the role.
fn test_the_best_seed_is_not_the_best_scorer() -> Result[Unit, Str] {
  let pool := [agent("flashy", "", 9), agent("dull", "", 2), agent("kid-a", "dull", 5), agent("kid-b", "dull", 4)]
  let chosen := seed_of(pool)
  if chosen == "dull" {
    Ok(())
  } else {
    Err(str.join(["forked from ", chosen, " -- clade(dull)=11 beats clade(flashy)=9, so the leader was expanded instead of the productive line"], ""))
  }
}

# With no lineage recorded at all -- every pool before #487 -- the clade of an
# agent is its own score, so the choice is exactly what it always was.
fn test_a_pool_with_no_lineage_behaves_as_before() -> Result[Unit, Str] {
  let pool := [agent("top", "", 7), agent("mid", "", 3), agent("low", "", 0 - 2)]
  let chosen := seed_of(pool)
  if chosen == "top" {
    Ok(())
  } else {
    Err(str.concat("a flat pool no longer forks from its best agent; it chose ", chosen))
  }
}

# A lineage that went bad must not drag its ancestor up: a clade is a sum, so
# negative descendants count against the seed.
fn test_a_bad_lineage_counts_against_its_seed() -> Result[Unit, Str] {
  let pool := [agent("steady", "", 4), agent("forked", "", 5), agent("bad-kid", "forked", 0 - 6)]
  let chosen := seed_of(pool)
  if chosen == "steady" {
    Ok(())
  } else {
    Err(str.join(["forked from ", chosen, " -- clade(forked)=-1 should lose to clade(steady)=4"], ""))
  }
}

# Descendants count at every depth, not just children.
fn test_a_grandchild_counts_toward_the_clade() -> Result[Unit, Str] {
  let pool := [agent("other", "", 6), agent("root", "", 1), agent("child", "root", 1), agent("grandchild", "child", 5)]
  let chosen := seed_of(pool)
  if chosen == "root" {
    Ok(())
  } else {
    Err(str.join(["forked from ", chosen, " -- clade(root)=7 including its grandchild should beat 6"], ""))
  }
}

# A parent_id cycle is corrupt data, not a reason to hang a company.
fn test_a_cycle_terminates() -> Result[Unit, Str] {
  let pool := [agent("a", "b", 1), agent("b", "a", 1)]
  let chosen := seed_of(pool)
  if str.is_empty(chosen) {
    Err("a cyclic pool returned no seed at all")
  } else {
    Ok(())
  }
}

fn test_an_empty_pool_has_no_seed() -> Result[Unit, Str] {
  match improver.best_seed([]) {
    None => Ok(()),
    Some(id) => Err(str.concat("an empty pool produced a seed: ", id)),
  }
}

fn run_all() -> [io] Int {
  let results := [("the best seed is not the best scorer", test_the_best_seed_is_not_the_best_scorer()), ("a pool with no lineage behaves as before", test_a_pool_with_no_lineage_behaves_as_before()), ("a bad lineage counts against its seed", test_a_bad_lineage_counts_against_its_seed()), ("a grandchild counts toward the clade", test_a_grandchild_counts_toward_the_clade()), ("a cycle terminates", test_a_cycle_terminates()), ("an empty pool has no seed", test_an_empty_pool_has_no_seed())]
  list.fold(results, 0, fn (fails :: Int, r :: (Str, Result[Unit, Str])) -> [io] Int {
    match r {
      (name, Ok(_)) => {
        let __ := io.print(str.concat("ok   ", name))
        fails
      },
      (name, Err(e)) => {
        let __ := io.print(str.join(["FAIL ", name, ": ", e], ""))
        fails + 1
      },
    }
  })
}

