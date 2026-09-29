# Resume note

State at baseline: empty scaffold, restore point tagged `restore-point/baseline`.

To resume work on this project from a cold start:

1. Read PROGRESS.md to find the current phase, then the matching commit.
2. Toolchain: `zig` 0.16.0 (Homebrew, `/opt/homebrew/bin/zig`), git configured.
3. Build/test: `zig build && zig build test`. Full verification: `tools/verify.sh`.
4. Clean-room constraint: the engine is written from knap.md + obsidianmd/knap
   README/CHANGELOG only. Never read `/Users/tbuddy/dev/z/knap-oliver/src/` or its
   `tests.zig`; that project's `fixtures/` and `examples/` are the only things
   reused, as ground-truth data.
