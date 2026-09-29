# knap-textile

A Knap template engine that renders templates to **Textile**, not Markdown.
Template + JSON data in, Textile bytes out. The cult's machinery, bent to serve
Dean Allen's ghost.

- Zig, standard library only. No npm, no network, no wrapping the official knap package.
- CLI: `knap-textile render template.knap --data data.json` → Textile on stdout.
- Non-zero exit with a message on template syntax errors; never emits half-rendered output.

Status: **baseline scaffold** — this file is finalized in phase 8 with the template
subset, the filter→Textile mapping table, and the clean-room session record.
