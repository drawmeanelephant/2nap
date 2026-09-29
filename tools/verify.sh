#!/bin/bash
# knap-textile verification harness.
#
# Runs, in order:
#   1. toolchain record
#   2. release build (zig build -Doptimize=ReleaseSafe)
#   3. full fixture test suite (zig build test)
#   4. CLI-level checks: example renders byte-identical, error cases exit
#      non-zero with empty stdout
#   5. red-green proof: a passthrough mutant and a Markdown mutant must both
#      make the test suite FAIL (proving the tests bite), with git restoring
#      the corpus afterwards
#
# Run from the repository root: tools/verify.sh

set -u
cd "$(dirname "$0")/.."

pass=0
fail=0

ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }
section() { echo; echo "=== $1 ==="; }

BIN=zig-out/bin/knap-textile

section "1. toolchain"
echo "zig: $(zig version)"
echo "git: $(git --version)"

section "2. release build"
if zig build -Doptimize=ReleaseSafe 2>&1; then
    ok "zig build -Doptimize=ReleaseSafe (clean)"
else
    bad "release build"
fi

section "3. fixture test suite (zig build test)"
if zig build test 2>&1; then
    ok "zig build test: corpus + invariants + units"
else
    bad "zig build test"
fi

section "4. CLI checks"
for ex in heading list table; do
    if "$BIN" render "examples/$ex.knap" --data "examples/$ex.json" > "/tmp/kt-$ex.out" 2>"/tmp/kt-$ex.err" \
        && cmp -s "/tmp/kt-$ex.out" "examples/$ex.textile"; then
        ok "examples/$ex renders byte-identical to examples/$ex.textile"
    else
        bad "examples/$ex render mismatch (see /tmp/kt-$ex.out)"
    fi
done

# syntax error: non-zero exit, EMPTY stdout, pinned message on stderr
"$BIN" render fixtures/errors/err-unclosed-if.knap > /tmp/kt-e.out 2> /tmp/kt-e.err
rc=$?
exp_msg=$(cat fixtures/errors/err-unclosed-if.error)
got_msg=$(cat /tmp/kt-e.err)
if [ "$rc" -ne 0 ] && [ ! -s /tmp/kt-e.out ] && [ "$got_msg" = "knap-textile: error: $exp_msg" ]; then
    ok "syntax error: exit $rc, stdout empty, stderr = 'knap-textile: error: $exp_msg'"
else
    bad "syntax error handling (rc=$rc stdout=$(wc -c < /tmp/kt-e.out) bytes stderr='$got_msg')"
fi

# bad data: non-zero exit
printf '{ broken' > /tmp/kt-bad.json
"$BIN" render examples/heading.knap --data /tmp/kt-bad.json > /tmp/kt-bad.out 2> /tmp/kt-bad.err
rc=$?
if [ "$rc" -ne 0 ] && [ ! -s /tmp/kt-bad.out ] && grep -q "invalid JSON data" /tmp/kt-bad.err; then
    ok "invalid JSON: exit $rc, stdout empty, message '$(cat /tmp/kt-bad.err)'"
else
    bad "invalid JSON handling"
fi

section "5. red-green proof (tests must fail against mutants)"

# 5a. passthrough mutant: expected file replaced by the raw template
git checkout -q -- fixtures
cp fixtures/filter-h1-basic.knap fixtures/filter-h1-basic.textile
if zig build test > /tmp/kt-mutant1.log 2>&1; then
    bad "passthrough mutant did NOT fail the suite"
else
    ok "passthrough mutant fails the suite (engine returning template unchanged is caught)"
fi
git checkout -q -- fixtures

# 5b. Markdown mutant: expected file replaced by Markdown rendering
printf '**The Machine Stops**\n' > fixtures/filter-h1-basic.textile
if zig build test > /tmp/kt-mutant2.log 2>&1; then
    bad "Markdown mutant did NOT fail the suite"
else
    ok "Markdown mutant fails the suite (Markdown-emitting filters are caught)"
fi
git checkout -q -- fixtures

# 5c. corpus must be pristine again and the suite green
if [ -z "$(git status --porcelain fixtures examples)" ] && zig build test > /dev/null 2>&1; then
    ok "corpus restored, suite green again"
else
    bad "corpus not restored or suite still red"
fi

section "6. example renders (raw stdout)"
for ex in heading list table; do
    echo "--- $ex: knap-textile render examples/$ex.knap --data examples/$ex.json"
    "$BIN" render "examples/$ex.knap" --data "examples/$ex.json"
    echo "--- (exit $?)"
done

echo
echo "=== verify summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
