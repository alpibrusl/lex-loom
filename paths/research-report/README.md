# research-report path

A vetted path for a company whose deliverable is a document, not software:
the consortium's ResearchCo (docs/consortium-freeze.md). No build, no
server, no test suite. The `opportunity_research` role writes a fenced
`report.md`, the gate `bin/check_research_report.py` verifies every
checkable criterion by name, and the passing report is synced here as
`report.md` at the end of the iteration.

Nothing in this skeleton is executed. It exists so bootstrap has a vetted
path to lay down and so the workspace has a README naming what lands in it.
