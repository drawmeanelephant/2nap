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

## Pass 2 (second pass) — 2026-09-28 — clean caches, fresh rebuild

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
PASS: CLI byte-exact on all 41 positive fixtures
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

=== verify summary: 11 passed, 0 failed ===
```

## Binary shape

```
$ file zig-out/bin/knap-textile   (native macOS build)
zig-out/bin/knap-textile: Mach-O 64-bit executable arm64
$ otool -L zig-out/bin/knap-textile
\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1359.0.0)

$ zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe
$ file zig-out/bin/knap-textile
zig-out/bin/knap-textile: ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV), statically linked, with debug_info
```

The musl cross-build is statically linked — proof the engine has zero
dependencies beyond the Zig standard library. The native macOS binary
links only the unavoidable system libSystem.

## Acceptance-criteria audit (second pass)

| # | Criterion | Evidence |
|---|---|---|
| 1 | zig build clean; all tests pass; fail-against-passthrough verified | Pass 2: ReleaseSafe build clean; `zig build test` 11/11; red-green proof lines in both passes (passthrough + Markdown mutants fail the suite) |
| 2 | Report shows three rendered examples from JSON data | Pass 1/Pass 2 section 6: heading (`h1. The Machine Stops`), list (`* The Air-Ship`…), table (`\|_. name\|_. age\|`) — raw stdout |
| 3 | README documents subset, mapping table, clean-room session | README: "Template subset", "Filter registry → Textile mapping", "Clean-room session record" |
| 4 | Conformance project Textile fixtures are ground truth, reused | fixtures/ (41 triples) + fixtures/errors/ (16 cases) + examples/ copied as data only; boundary recorded in README clean-room section |
| 5 | Verified, not merely produced; undoable; second pass happened | This report (raw output, two passes); ROLLBACK.md names tag `restore-point/baseline`; every phase committed |

