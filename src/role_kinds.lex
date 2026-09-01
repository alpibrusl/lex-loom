# role_kinds.lex — the castable role vocabulary, as a leaf module.
#
# Extracted from roles.lex (ORG2, lex-loom#217) so modules that must not
# import roles.lex (org.lex, and through it agent/runner.lex — roles imports
# runner, so org -> roles from the runner side would be a cycle) can still
# validate role names. roles.known_kinds() re-exports this; keep the list in
# sync with roles.for_role's if-chain until ORG5 (#220) makes both
# data-driven.

fn known_kinds() -> List[Str] {
  ["pm", "architect", "build", "py_build", "ts_build", "qa", "py_qa", "ts_qa", "test_author", "py_test_author", "ts_test_author", "devops", "docs", "security", "ux_designer", "brand_designer", "content_designer", "fe_build", "launch", "deploy", "demo", "brand_strategist", "copywriter", "content_creator", "seo_specialist", "finance", "legal", "cx", "research", "monetization_handoff", "scribe"]
}

