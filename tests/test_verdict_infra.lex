# test_verdict_infra.lex -- a QA FAIL that cites loom's own pipeline is not a
# verdict about the product (#372). tzc19 iter 3 failed a launched, 13-tests-
# green build twice because QA tried to run $LOOM_ROOT/bin/check_derived_values.py
# inside its sandbox and treated the missing script as FAIL "per instructions".

import "std.str" as str

import "std.list" as list

import "../src/orchestrator" as orch

import "../src/roles" as roles

fn infra_fail() -> Str {
  "{\"verdict\":\"FAIL\",\"reason\":\"Step 2 (derived-value gate) failed: LOOM_ROOT is empty and bin/check_derived_values.py does not exist, so the mandated hardcoding check could not be executed\"}"
}

fn product_fail() -> Str {
  "{\"verdict\":\"FAIL\",\"reason\":\"POST /convert returns 500 on a valid body\"}"
}

fn test_a_fail_citing_the_pipeline_is_not_final() -> Result[Unit, Str] {
  if orch.verdict_fail_is_final("spec json-verdict-pass", infra_fail()) {
    Err("a FAIL about LOOM_ROOT / check_derived_values was treated as a product verdict -- tzc19 iter 3 bounced a correct build on it")
  } else {
    Ok(())
  }
}

fn test_a_fail_about_the_product_is_still_final() -> Result[Unit, Str] {
  if orch.verdict_fail_is_final("spec json-verdict-pass", product_fail()) {
    Ok(())
  } else {
    Err("a real product FAIL is no longer final -- the QA node would be retried into recanting")
  }
}

fn test_the_infra_reason_names_the_cause() -> Result[Unit, Str] {
  if orch.fail_cites_pipeline_infra(infra_fail()) and not orch.fail_cites_pipeline_infra(product_fail()) and str.contains(orch.pipeline_infra_fail_reason(), "not yours to run") {
    Ok(())
  } else {
    Err("fail_cites_pipeline_infra misclassifies, or the retry reason does not tell QA why")
  }
}

fn test_qa_and_pm_prompts_keep_the_pipeline_out_of_the_product() -> Result[Unit, Str] {
  if str.contains(roles.py_qa_system_prompt(), "NOT YOURS TO RUN") and str.contains(roles.pm_system_prompt(), "Never make loom's own pipeline gates") {
    Ok(())
  } else {
    Err("the QA or PM prompt no longer says that pipeline gates are not the product's acceptance criteria")
  }
}

# #382: tzc21 iter 3 -- QA failed 8 passing tests because a criterion said
# `pytest tests/` and the suite sat at the root; launch used PORT=8000
# because the goal said "binds to 0.0.0.0:8000". Paths and ports are the
# pipeline's, not the spec's.
fn test_prompts_keep_paths_and_ports_out_of_the_spec() -> Result[Unit, Str] {
  let qa_ok := str.contains(roles.py_qa_system_prompt(), "JUDGE BEHAVIOUR, NOT LAYOUT") and str.contains(roles.qa_system_prompt(), "JUDGE BEHAVIOUR, NOT LAYOUT")
  let pm_ok := str.contains(roles.pm_system_prompt(), "no port numbers")
  let launch_ok := str.contains(roles.launch_system_prompt("t/iter-1"), "NOT FROM THE GOAL")
  if qa_ok and pm_ok and launch_ok {
    Ok(())
  } else {
    Err(str.join(["a prompt no longer keeps layout out of the spec: qa=", if qa_ok {
      "ok"
    } else {
      "MISSING"
    }, " pm=", if pm_ok {
      "ok"
    } else {
      "MISSING"
    }, " launch=", if launch_ok {
      "ok"
    } else {
      "MISSING"
    }], ""))
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_a_fail_citing_the_pipeline_is_not_final(), test_a_fail_about_the_product_is_still_final(), test_the_infra_reason_names_the_cause(), test_qa_and_pm_prompts_keep_the_pipeline_out_of_the_product(), test_prompts_keep_paths_and_ports_out_of_the_spec()]
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

