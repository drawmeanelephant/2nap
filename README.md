# knap-textile

A Knap template engine that renders templates to **Textile**, not Markdown.
Template + JSON data in, Textile bytes out. The cult's machinery, bent to serve
Dean Allen's ghost.

- Zig 0.16, standard library only. No npm, no network at build or run time,
  no wrapping the official knap package.
- CLI: `knap-textile render template.knap --data data.json` → Textile on stdout.
- Non-zero exit with a message on template syntax errors; never emits
  half-rendered output (the render is fully buffered; stdout is written only
  after complete success).

## CLI

```
knap-textile render <template.knap> [--data <data.json>]
```

- stdout: the rendered Textile bytes, exactly (no added trailing newline).
- exit 0 on success.
- exit 1 with one `knap-textile: error: …` line on stderr for: usage errors,
  unreadable files, invalid JSON, template syntax errors (with line/column),
  unknown filters, filter misuse, render-time failures.
- `--data` is optional; it defaults to an empty object. The template is parsed
  *before* data is loaded, so syntax errors surface without a data file.

## Template subset

Documented from Knap's user-facing docs (see clean-room record below), pinned
exactly by the fixture corpus:

- **Interpolation** `{{ value }}` — whitespace inside braces is optional;
  names may contain spaces (`{{ First name }}`).
- **Paths** — dotted (`author.name`), bracket index (`authors[0].name`),
  bracket key (`metadata["article:section"]`). Missing values render as empty
  text and are falsy in conditions.
- **Filters** — `{{ value | filter }}` and `{{ value | filter:arg }}`; chains
  run left to right; at most one argument (quoted string, number, or bare
  word). String literals may flow through filters (`{{ "Sections" | h2 }}`).
- **Logic** — `{% if %} / {% elseif %} / {% else %} / {% endif %}` with
  `== != < <= > >= contains and/&& or/|| not/!` and parentheses. Truthiness:
  `false`, `null`, undefined, `""`, `0`, `[]` are false; everything else true.
- **Loops** — `{% for item in array %}…{% endfor %}` (non-array is an error)
  with `loop.index` (1-based), `loop.index0`, `loop.first`, `loop.last`,
  `loop.length`. Loops nest; each level shadows `loop`.
- **Comments** — `{# … #}`, single or multi-line: removed from output, never
  evaluated, end at the first `#}`, do not nest, unclosed is a syntax error.
- **Whitespace rule** (pinned by the corpus) — one newline immediately after
  an opening block tag (`if/elseif/else/for`) is consumed; a newline before a
  closing tag is body text; loop iterations are concatenated without a
  separator.
- **Literals** in expressions — `"strings"`, numbers, `true`, `false`, `null`.

## Filter registry → Textile mapping

Upstream Knap's filters emit Markdown. knap-textile registers the same filter
names and emits **Textile**:

| Filter | Input | Textile emitted | Example |
|---|---|---|---|
| `h1` … `h6` | text | `h1. text` … `h6. text` | `{{ title \| h1 }}` → `h1. The Machine Stops` |
| `blockquote` | text (per line) | `bq. ` prefix on every line | `bq. To be, or not to be.` |
| `bold` | single-line text | `*text*` | `*watch out*` |
| `italic` | single-line text | `_text_` | `_very_` |
| `list` | array | `* item` lines; nested arrays deepen (`**`, `***`, max 3) | `* one` / `** two` |
| `numbered` | array | `# item` lines; nesting as above | `# one` / `## two` |
| `link` | text + required URL arg | `"text":url` | `"Example":https://example.com/` |
| `table` | array of rows | header `\|_. a\|_. b\|`, data rows `\|a\|b\|`, no padding | `\|_. name\|_. age\|` |
| `code` | single-line text | `@text@` | `@zig build@` |
| `codeblock` (alias `code_block`) | text | `bc. ` with the first line on the same line | `bc. puts say` |

Notes:

- `code` accepts an optional argument (upstream shows `code:"typescript"`) and
  ignores it — Textile's inline `@…@` has no language annotation.
- `link` refuses `javascript:`, `data:` and `vbscript:` destinations (upstream
  0.4.0 URL-scheme hardening, carried over).
- `bold`, `italic`, `code` and `link`'s link text must be single-line;
  multi-line input is a render error (`codeblock` exists for blocks).
- Non-string filter input is serialized first (numbers as text, objects as
  compact JSON). A rendered object interpolates as compact JSON:
  `{"k":1,"s":"x"}`.
- Data is inserted verbatim; Textile-significant characters inside data
  (`*`, `_`, `|`, …) can alter how a Textile renderer reads the result. No
  escaping layer is attempted — a documented limitation.

## Out of scope (honestly listed)

- **Async resolvers** — the engine is synchronous; a static binary has no
  event loop.
- **DOM-dependent filters** (`html_to_json`, `remove_html`) — a static Zig
  binary has no DOM. A feature, not a gap.
- **Markdown-only filters** (`escape_md`, `wikilink`, `callout`, `image`,
  `embed`, `yaml`, `footnote`, …) — no Textile counterpart in scope.
- **`{% set %}`**, the **`??` fallback operator**, whitespace-control
  (`{%- -%}`), variable-bearing bracket expressions (`ts[loop.index0]`),
  includes/inheritance, batch/CSV rendering, regex arguments.
- **Textile escaping of data** — see the note above.

## Fixtures and testing

The fixture corpus in `fixtures/` (41 output triples, 16 error cases) and
`examples/` is reused **as data** from the sibling conformance project; it is
the ground truth for the filter→Textile mapping. See EXCEPTIONS.md for the
one vestigial file.

Three layers, all in `zig build test`:

1. **Byte-exact** — every triple renders to its expected Textile bytes; every
   error case produces its pinned diagnostic (message, line, column).
2. **Anti-passthrough** — expected output differs from the template bytes in
   every fixture, so an engine that echoes the template fails everything.
3. **Anti-Markdown** — no expected output contains unambiguous Markdown
   syntax (`**bold**`, `](url`, fences, `> ` quotes, `~~`, `__`), and every
   filter fixture's output carries its Textile family marker. (Line-initial
   `** `/`## ` is Textile nested-list syntax and deliberately allowed;
   `bc.` content may legitimately contain `#`.)

`tools/verify.sh` runs the release build, the suite, CLI-level checks (exit
codes, empty stdout on error), example renders, and a **red-green proof**:
it corrupts one expected file with its raw template and another with Markdown,
shows the suite fail in both cases, restores the corpus via git, and shows it
green again — so "fail against passthrough" is demonstrated, not assumed.

## Clean-room session record

- **Date:** 2026-09-28
- **Rule:** the engine was written from Knap's user-facing documentation only.
  The parser source of Knap (obsidianmd/knap package internals) was never
  read, and no knap implementation code was consulted.
- **Boundary with the conformance project:** the sibling repository
  (conformance/ground-truth holder) contributed **data files only** —
  `fixtures/` and `examples/` triplets. Its sources (`src/`, `tests`) were
  never opened, so even the corpus reuse keeps the implementation clean-room.
- **Sources consulted** (snapshots in `.cleanroom/`, hashed as fetched):

| Source | Revision | sha256 |
|---|---|---|
| github.com/obsidianmd/knap `README.md` | `6395cb8b5432b3c3495eab43c10b0d637e021592` | `558b4f44…335a61556` |
| github.com/obsidianmd/knap `CHANGELOG.md` | same | `33d9c144…58cdcda7` |
| knap.md/variables (HTML as served) | fetched 2026-09-28 | `444ddb1f…d63eb30c48` |
| knap.md/filters (HTML as served) | fetched 2026-09-28 | `6c0108a9…2a94a0a802` |
| knap.md/logic (HTML as served) | fetched 2026-09-28 | `ccdc5aa6…6c74203e8` |
| github.com/textile/textile-spec `README.textile` | `a0615116ddf341bd57f54564af96e018bd5b9731` | `5f07d62f…1e1a76f03a` |
| textile-spec `phrase_modifiers.yaml` | same | `76ba245b…0252616483019` |
| textile-spec `paragraph_text.yaml` | same | `68f90160…cb48bd3601b` |

Full sha256 values are reproducible via `shasum -a 256 .cleanroom/*`.
Doc-derived rules the corpus then pinned harder: exact whitespace handling,
`codeblock` spelling (docs say `code_block`), error messages/columns, list
nesting depth 3, single-line scope of `bold`.

## Repository layout

```
build.zig          exe + test steps, no dependencies
src/main.zig       CLI shell (arg parsing, buffering, exit codes)
src/parse.zig      template → AST, parse-time validation, diagnostics
src/engine.zig     AST + JSON data → Textile bytes
src/filters.zig    filter registry (names, arity)
src/diag.zig       diagnostic type + line/column formatting
tests.zig          fixture harness + invariants + unit checks
fixtures/          ground-truth corpus (reused data)
examples/          heading / list / table demos
tools/verify.sh    full verification incl. red-green proof
.cleanroom/        hashed doc snapshots (provenance evidence)
```

## Build and verify

```
zig build                                  # debug binary in zig-out/bin
zig build -Doptimize=ReleaseSafe           # release binary
zig build test                             # fixture suite
tools/verify.sh                            # everything, with red-green proof
```

Process documents: PROGRESS.md (ledger), RESUME.md (cold-start note),
VERIFICATION.md (raw check output), EXCEPTIONS.md (deviations),
ROLLBACK.md (restore point).
