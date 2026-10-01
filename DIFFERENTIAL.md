# Black-box conformance decisions

Oracle: `drawmeanelephant/k4o` at
`942ebf32ed89eca8d195b04068118a9ee62706c6`, Zig 0.16.0.
Evidence: its public README and executable responses to the cases in
`tools/differential_corpus.py`. No k4o source was read.

The original `fixtures/` and `examples/` remain unchanged. Differences were
closed in 2nap, not removed from the corpus.

## Documented behavior corrected

- Empty objects are truthy; empty arrays are false.
- Bare filter arguments resolve against the **data root**, not loop locals.
  An absent key falls back to the word; a present null/array/object is an
  argument error. Quoted arguments never resolve.
- Text filters reject arrays/objects. Headings and blockquotes, like other
  phrase filters, reject LF. Only `codeblock` accepts multiline text.
- Links reject quotes in their text, empty URLs, URL whitespace/quotes,
  and case-insensitive script schemes. Diagnostics preserve the input's
  scheme spelling.
- Tables reject empty dimensions, non-array rows, structured cells, pipes,
  and LF. Lists accept scalar items and nested arrays, but not object items.
- Integer/integer equality and ordering retain all 64 bits, rather than
  converting to a float and collapsing adjacent integers above $2^{53}$.
- Closing tags reject trailing text, including in branches not taken.

## Ambiguities settled by executable observations

| Question | Decision matching the pinned oracle | Case family |
| --- | --- | --- |
| Is a backslash escape JSON-like in a template string? | No. It quotes the next byte: `\n` becomes `n`, `\q` becomes `q`. JSON input is separate and decodes normally. | `literal`, `expression/edge`, `link/literal` |
| Does a lone CR after an opening block count as a newline? | No. LF and CRLF are consumed once; bare CR is preserved. | `whitespace` |
| Can LF/CR appear inside a logic tag? | Yes, as whitespace. | `syntax/edge` |
| May there be space before a path's dot or bracket? | No. Space after a dot and inside brackets is accepted. Spaced property names remain supported. | `expression/edge`, `path` |
| Can the loop iterator be named `loop`? | Yes. The iterator shadows metadata, just as it shadows other names. | `structure/7` |
| Is a bare CR rejected by single-line filters or table cells? | No. The oracle's single-line check rejects LF only. | `filter`, `collection/table` |
| Are multiline list items escaped or split into additional markers? | No. Scalar text is inserted verbatim. | `collection/list`, `collection/numbered` |
| Are scientific-notation template literals accepted? | No. Decimal literals only; JSON numbers may use exponents. | `expression/edge`, `syntax/edge`, `number` |
| Which error wins when a table cell contains both a pipe and LF? | The pipe error. | `collection/table` |

No escaping layer or new syntax was inferred from implementation details.
Diagnostic kind, location, and text are compared after removing only the two
program-specific stderr envelopes. Successful Textile output is never
normalized.

## Reproducing a failure

```sh
python3 tools/build_oracle.py
zig build -Doptimize=ReleaseSafe
python3 tools/differential.py --report differential-report.json
python3 tools/differential.py --match 'expression/edge'
```

The JSON report includes each failed template, JSON input, statuses, and
byte representations of both streams. A timeout or failed launch is an
infrastructure failure, never a skipped case. An oracle update requires
changing the explicit revision pin and rebuilding it; failures must be
investigated with more black-box tests, never source inspection.
