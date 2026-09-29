# Verification report

Raw check output, captured verbatim. Pass 1 ran after the implementation
milestone; pass 2 is the second pass (clean caches, fresh rebuild, full
re-verification) run before calling the work done.

## Pass 1 — 2026-09-28

```

=== 1. toolchain ===
zig: 0.16.0
git: git version 2.54.0 (Apple Git-157)

=== 2. release build ===
PASS: zig build -Doptimize=ReleaseSafe (clean)

=== 3. fixture test suite (zig build test) ===
PASS: zig build test: corpus + invariants + units

=== 4. CLI checks ===
PASS: examples/heading renders byte-identical to examples/heading.textile
PASS: examples/list renders byte-identical to examples/list.textile
PASS: examples/table renders byte-identical to examples/table.textile
PASS: syntax error: exit 1, stdout empty, stderr = 'knap-textile: error: syntax error at line 1, column 1: unclosed if block (missing '{% endif %}')'
PASS: invalid JSON: exit 1, stdout empty, message 'knap-textile: error: invalid JSON data in '/tmp/kt-bad.json': SyntaxError'

=== 5. red-green proof (tests must fail against mutants) ===
PASS: passthrough mutant fails the suite (engine returning template unchanged is caught)
PASS: Markdown mutant fails the suite (Markdown-emitting filters are caught)
PASS: corpus restored, suite green again

=== 6. example renders (raw stdout) ===
--- heading: knap-textile render examples/heading.knap --data examples/heading.json
h1. The Machine Stops

_A reading note_
--- (exit 0)
--- list: knap-textile render examples/list.knap --data examples/list.json
h2. Sections

* The Air-Ship
* The Mending Apparatus
* The Homeless
--- (exit 0)
--- table: knap-textile render examples/table.knap --data examples/table.json
|_. name|_. age|
|Walter|5|
|Florence|6|
--- (exit 0)

=== verify summary: 10 passed, 0 failed ===
```

