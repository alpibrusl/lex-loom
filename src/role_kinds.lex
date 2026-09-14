# role_kinds.lex — the castable role vocabulary, as a leaf module.
#
# Extracted from roles.lex (ORG2, lex-loom#217) so modules that must not
# import roles.lex (org.lex, and through it agent/runner.lex — roles imports
# runner, so org -> roles from the runner side would be a cycle) can still
# validate role names. roles.known_kinds() re-exports this; keep the list in
# sync with roles.for_role's if-chain until ORG5 (#220) makes both
# data-driven.

import "std.str" as str

fn known_kinds() -> List[Str] {
  ["pm", "architect", "build", "py_build", "ts_build", "qa", "py_qa", "ts_qa", "test_author", "py_test_author", "ts_test_author", "devops", "docs", "security", "ux_designer", "brand_designer", "content_designer", "fe_build", "launch", "deploy", "demo", "brand_strategist", "copywriter", "content_creator", "seo_specialist", "analytics", "ops", "release_manager", "data_protection", "lifecycle", "community", "finance", "legal", "cx", "research", "opportunity_research", "monetization_handoff", "scribe", "founder"]
}

# The language a stack path builds in.
#
# The operator picks the path in the manifest's [stack]; everything downstream
# follows from it -- which build roles a graph may cast (metaspec), which
# capability a company offers (economy_binding), and which language the
# prompts name (roles). It lives in this leaf because those three must all
# read it and none of them may import the others.
#
# An unrecognised path yields "", which every caller reads as "no opinion":
# a new skeleton is never blocked, or lied about, by this function.
fn language_of_path(path :: Str) -> Str {
  if str.starts_with(path, "python-") {
    "python"
  } else {
    if str.starts_with(path, "lex-") {
      "lex"
    } else {
      if str.starts_with(path, "node-") or str.starts_with(path, "nextjs") or str.starts_with(path, "web-") or str.starts_with(path, "rn-") {
        "node"
      } else {
        ""
      }
    }
  }
}

