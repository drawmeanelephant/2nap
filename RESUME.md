# Resume note

State: **complete**. knap-textile is built, verified (two passes), and
committed. Restore point: tag `restore-point/baseline`.

If you are picking this project up cold:

1. Read PROGRESS.md (ledger) and VERIFICATION.md (raw evidence) first.
2. Toolchain: `zig` 0.16.0 (Homebrew, `/opt/homebrew/bin/zig`), git configured.
3. Build/test: `zig build && zig build test`. Full verification:
   `tools/verify.sh` (release build, suite, CLI checks incl. byte-exactness on
   all fixtures, red-green mutant proof, example renders).
4. Render something:
   `./zig-out/bin/knap-textile render examples/heading.knap --data examples/heading.json`

Clean-room constraint (still binding): the engine derives from knap.md +
obsidianmd/knap README/CHANGELOG only (snapshots + hashes in `.cleanroom/`,
session record in README). The sibling conformance project contributed
**data files only** (`fixtures/`, `examples/`); never read its `src/` or
tests when modifying this engine.

Known-entry points for future work: src/parse.zig (grammar + error positions),
src/engine.zig (evaluation + Textile emission), src/filters.zig (registry),
EXCEPTIONS.md (documented deviations, e.g. `??` and `{% set %}` excluded).
