#!/usr/bin/env bash
# hb3_slow_cat.sh — proc executor for demo/hb3-concurrency-roundtrip.sh.
# Echoes its prompt (passing "spec non-empty") after a short delay, so a
# layer of nodes takes long enough that BOTH workers demonstrably claim
# and execute jobs concurrently.
sleep 0.4
cat
