# evals

Node-level accept rates, measured against a stored baseline.

## Why this exists

Every quality claim in this project was made from whole-company runs, and
nearly all of them were wrong. tzc6 → tzc7 → tzc8 went 18/2 → 13/4 → 10/4
while real defects were being fixed, with a confound in each comparison
(provider path, then a QA change). A single run of a stochastic pipeline
cannot separate a regression from variance, so "did that fix help?" was
answered from memory of the last number.

Worse, whole-company runs are 1.5–2.5 hours each and mix dozens of nodes
together, so a narrow question arrives confounded with everything else that
went wrong on the way. The launch bug took four "fixes" that each verified
fine and changed nothing, because each was checked by rebuilding the entire
company around it. Four probe samples then found the real cause in minutes.

## Running

    bin/eval-suite.sh              # measure, compare against the baseline
    bin/eval-suite.sh --update     # accept the current numbers as the baseline

Results land in `evals/results/`, one tab-separated file per run, recording
the model, provider and commit alongside the rates — because a rate without
those is not comparable to anything.

## What the baseline is not

It is not a target. A role at 3/5 is not a failing grade; it is a number to
notice when it moves. The suite fails only when a role drops MORE than the
tolerance below its baseline, because sampling noise at n=5 is large and a
suite that cries regression at every wobble gets ignored.
