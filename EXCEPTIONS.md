# Exception-path note

Numbered deviations from the approved spec and corpus-forced clarifications,
each with a reason.

1. **`??` fallback operator not implemented.** Documented upstream
   (knap.md/logic) but outside the approved subset and unexercised by the
   fixture corpus. Listed in README as out of scope.
2. **`{% set %}` not implemented.** Same rationale as (1).
3. **Variable-bearing bracket expressions** (`timestamps[loop.index0]`,
   shown on knap.md/variables) not implemented; constant index/key brackets
   are supported. Corpus does not exercise the variable form.
4. **Filter registry is narrower than upstream.** Only the Textile-mappable
   names are registered (`h1`–`h6`, `bold`, `italic`, `blockquote`, `code`,
   `codeblock`/`code_block`, `link`, `list`, `numbered`, `table`). Upstream
   Markdown-emitting extras (wikilink, callout, yaml, escape_md, …) and
   plain-text/collection helpers are omitted — the approved spec adds plain
   helpers only if the corpus requires them; it does not.
5. **`code` accepts an optional argument and ignores it.** Upstream documents
   `code:"typescript"`; Textile inline `@…@` carries no language annotation.
   Documented in the README mapping table.
6. **`codeblock` spelling.** knap.md documents `code_block`; the corpus uses
   `codeblock`. Both names are registered to the same filter; the corpus
   spelling is primary.
7. **`bad-data.json` (fixtures/errors) is vestigial.** It ships with neither a
   `.knap` nor an `.error` counterpart, so the harness cannot execute it as a
   fixture. Invalid-JSON handling is instead demonstrated in verify.sh with a
   generated bad file (exit 1, empty stdout, `invalid JSON data in …`).
8. **Corpus-silent behaviors chosen deliberately** (none pinned by any
   original fixture; the 2026-09-30 differential corpus supersedes the choices
   below where noted):
   - `item_index` loop variable not implemented (ambiguous doc wording,
     untested).
   - Floats serialize via shortest round-trip form; integers as decimal.
   - Ordering comparisons (`< <= > >=`) across mismatched types are false
     rather than errors; `contains` outside string/array pairs is false.
   - `code` and `link` link-text enforce single-line like `bold`.
   - `h1`–`h6` now require single-line scalar text, matching the black-box oracle.
   - `link` refuses `javascript:`/`data:`/`vbscript:` destinations (upstream
     0.4.0 hardening spirit); no fixture exercises this.
9. **CLI error prefix.** The CLI wraps every pinned diagnostic as
   `knap-textile: error: <message>`; the fixture harness matches the pinned
   message itself. The prefix identifies the binary in shell use.
10. **Whitespace rule made normative by the corpus** rather than the docs
    alone: exactly one newline after an opening block tag is consumed, the
    newline before a closing tag is preserved, and iterations concatenate
    with no separator (loop-nested produces trailing blank lines this way).
11. **`--data` made optional.** Ten error fixtures ship without a `.json`
    file; template parsing therefore happens before data loading, and the
    harness invokes those cases with an implicit empty object. The task's
    invocation form (`--data data.json`) remains the documented primary use.
12. **Black-box parity clarifications (2026-09-30).** `DIFFERENTIAL.md` records
    README-derived rules and executable observations that supersede earlier
    corpus-silent choices. Existing fixtures are unchanged. Stderr's
    program-specific envelope is the only differential normalization;
    stdout is always compared byte-for-byte.
