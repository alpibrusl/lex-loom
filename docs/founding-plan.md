# The founding-plan gate

A company whose manifest says

```toml
[policy]
founding = true
```

builds nothing until its founder has approved a plan.

1. **Iteration 1 is the plan.** A fixed one-node sprint (`<company>/founding`,
   no Architect) runs the `founder` role, which writes `plan.md`: Idea,
   Budget (a table in EUR per month whose Total is recomputed by
   `bin/check_founding_plan.py`), Resources, Human actions (everything only
   the founder can do: accounts, payments, domains), Success metric,
   Timeline. The checker is the gate; a plan that fails it stops the company.
2. **The company parks.** The passing plan becomes an attention item for the
   oracle `founder` (`board_pending_cmd` lists it under type `founding`;
   loom-cloud shows it as a board decision with the plan as context).
3. **The board decides** through the one decide path:
   `ATTENTION_ID=… VERDICT=approved|rejected REASON='…' RESOLVER_ID=<you>
   attention_resolve_cmd`, or Yes/No in the loom-cloud dashboard.
   - approved: the plan's Total (or `budget_eur=N` in the reason) becomes the
     company's `total` spend envelope, the stage moves Founding → Ideation,
     and the product iterations start on the next run.
   - rejected: the company goes to Sunset with the reason on the trail.
4. **Human actions stay human.** The plan lists them; nothing in loom creates
   an account, pays, or registers a domain.

Trail events: `founding_plan_ready`, `founding_plan_denied`,
`founding_approved` (with the envelope in cents), `founding_rejected`.
