# pack_names.lex — the role-pack vocabulary, as a leaf module.
#
# Extracted from role_registry.lex for the same reason role_kinds.lex was
# extracted from roles.lex: reaching one pure list through role_registry drags
# in company.lex's whole effect footprint (sql, fs_write, random, crypto, proc,
# vcs), because a Lex program's effect row is the union of everything it
# imports. The cloud runner only wants to tell the cloud which packs exist; it
# should not have to grant itself the right to spawn processes and touch a
# repo to ask.
#
# role_registry.pack_names() re-exports this, so there is still one list.

import "std.list" as list

fn pack_registry() -> List[(Str, List[Str])] {
  [("core", ["pm", "architect", "build", "py_build", "ts_build", "qa", "py_qa", "ts_qa", "test_author", "py_test_author", "ts_test_author", "devops", "docs", "demo", "scribe", "launch", "deploy", "founder"]), ("web", ["fe_build", "ux_designer"]), ("content", ["brand_designer", "content_designer", "brand_strategist", "copywriter", "content_creator", "seo_specialist"]), ("finance", ["finance", "monetization_handoff"]), ("governance", ["legal", "cx"]), ("research", ["research", "opportunity_research"]), ("security", ["security"]), ("ops", ["analytics"])]
}

fn pack_names() -> List[Str] {
  list.map(pack_registry(), fn (p :: (Str, List[Str])) -> Str {
    match p {
      (name, _) => name,
    }
  })
}

