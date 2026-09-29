# Changelog

## 0.6.0

This release makes filter chains preserve semantic value types. Review templates that serialize transformed values to YAML or depend on the exact text produced by collection filters.

### Breaking changes

- `yaml` and `yaml_property` now quote all strings, including `"null"`, `"true"`, and `"123"`. Typed nulls, booleans, and numbers remain unquoted. Templates that intentionally store JSON text can decode it with `parse_json` before serialization.
- `calc`, `round`, and `length` now return numbers instead of numeric text. Downstream assignments and serializers preserve that type, so YAML such as `price: "42.57"` becomes `price: 42.57`. `number_format` continues to return text.
- Numeric parsing is stricter. Blank `calc` input and partially numeric `round` input such as `"42abc"` are preserved with a warning instead of being coerced. Non-finite arithmetic results preserve the original input rather than emitting `Infinity` or `null`.
- `round` preserves collection structure and converts successfully rounded numeric-string members to numbers.
- `length` counts singleton arrays as collections, so `[42] | length` changes from `2` to `1`.
- `first` and `last` preserve the selected value's type. Selected objects and nested arrays now render as JSON, and empty arrays return `null` instead of `[]`.
- `nth` returns a typed subset array. A singleton primitive result now unwraps during interpolation and before downstream text filters, so `[1, 2] | nth:2` renders as `2` instead of `[2]`.
- The exported `applyFiltersWithRegistry` helper now renders a final `null` result as empty text instead of `"null"`, matching template interpolation.

## 0.5.1

- Attach ready-to-install VS Code and Sublime Text syntax packages to tagged GitHub releases.

## 0.5.0

- Add optional Prism, CodeMirror, and highlight.js adapters, with the website using the shared CodeMirror stream parser.
- Add VS Code and Sublime Text syntax packages for Knap Markdown, with shared generated grammars, template comments, and snippets.

## 0.4.2

- Add `{# ... #}` template comments, including multiline comments, with syntax errors for unclosed comments.

## 0.4.1

- Add offline CLI help for syntax, filters, and logic tags, with per-filter and per-tag examples and help hints in template diagnostics.
- Add `knap validate` to check template syntax and static filter arguments without data or rendering.

## 0.4.0

- Add `knap batch` to render CSV rows, JSON arrays, or folders of JSON objects into individual files, with filename templates, explicit input formats, CSV piping, dry-run previews, and explicit overwrite support. Reject filename templates that produce empty or separator-only basenames, or leading whitespace.
- Add a `knap render` CLI with file, inline, and stdin template inputs; JSON variables from files, inline data, or stdin; repeatable string overrides; and file or stdout output with automatic parent-directory creation. The existing library entry points remain available.
- Add configurable limits for template size, output size, intermediate values, work operations, and nesting. Engines apply finite defaults, export `defaultRenderLimits`, and return `LIMIT_EXCEEDED` with empty output when a limit is reached.
- Add `allowRegex: false` to make `split` use literal separators and disable regex searches in `replace`. Native regex matching remains enabled by default for compatibility and requires worker or process isolation for untrusted input.
- Resolve only own data properties when reading template variables and filter paths, skipping inherited values and getters. Assign variables without invoking prototype setters.
- Escape literal link labels, image alt text, and Markdown destination delimiters. Omit `javascript:`, `vbscript:`, and `data:` destinations while preserving relative links and application protocols.
- Require literal tag names in `replace_tags`.
- Check opened batch output files before truncating them and avoid following final-path symlinks where supported.

## 0.3.2

- Support dot property access after array indexing, including chained paths such as `cast[0].details.name` and keys that share a keyword name.
- Merge through `merge` using the original array value rather than its serialized form, and treat a single comma-separated argument as a list.
- Preserve regular expression escapes such as `\s` in filter arguments while still decoding escaped quotes and backslashes.
- Remove the extra output line before standalone conditional closing tags, preserving intentional blank lines.
- Preserve intentional blank lines between loop iterations, including separate Markdown tables.
- Skip loop iterations that render nothing so a false condition cannot leave a blank separator or a trailing empty item.
- Apply whitespace control from an `if` tag when an `elseif` or `else` branch is taken.

## 0.3.0

- Revise `truncate` so its suffix counts toward the character limit, and add `truncatewords` for word-based truncation.
- Add property shorthand to `map`, plus `where` for typed property filtering and `sum` for collection totals.
- Expose evaluated filter arguments as `context.rawArguments` while preserving the existing serialized filter parameter string.
- Add `yaml_property` to serialize named properties with automatic block indentation and safe key formatting.
- Preserve singleton arrays through `yaml`, `wikilink`, and `embed`, and preserve typed null values through `yaml`.
- Extend `yaml` to serialize arrays and objects in block style by default, with `yaml:flow` for compact inline collections.
- Add `indent` to indent each non-empty line by a configurable number of spaces (two by default).

## 0.2.3

- Fix parsing of `nth` offset expressions such as `n+3`.

## 0.2.2

- Add the `yaml` standard filter for formatting YAML-safe scalar values.

## 0.2.1

- Rename the npm package from `@obsidianmd/knap` to `knap`.

## 0.1.0

- Extract the shared template tokenizer, parser, AST interpreter, and standard filters from Obsidian Web Clipper.
- Add engine-scoped custom filter registries, asynchronous filters, and asynchronous variable resolution.
- Add structured parse, validation, resolution, filter, and render errors plus non-fatal runtime filter warnings.
- Deduplicate repeated warnings and report runtime filter errors at the filter expression that produced them.
- Add the opt-in `@obsidianmd/knap/html` filter preset.
- Publish ESM, CommonJS, and TypeScript declaration builds.
