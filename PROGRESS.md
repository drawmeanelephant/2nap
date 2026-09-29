# Progress ledger

| Phase | Deliverable | Status | Evidence |
|---|---|---|---|
| 0 | Restore point (`restore-point/baseline`) | done | this commit + tag |
| 1 | Fixture corpus copied (data only) + inventory | pending | fixtures/ inventory |
| 2 | Clean-room doc pinning (revisions + sha256) | pending | README session table |
| 3 | build.zig + CLI shell + diagnostics | pending | zig build output |
| 4 | Lexer/parser → AST; syntax-error fixtures green | pending | zig build test |
| 5 | Engine (eval, logic, loops, whitespace) green | pending | zig build test |
| 6 | Textile filter registry green | pending | zig build test |
| 7 | Harness + invariant guards + verify.sh red-green | pending | tools/verify.sh transcript |
| 8 | README + examples + VERIFICATION.md | pending | docs |
| 9 | Second pass: clean rebuild, acceptance audit | pending | VERIFICATION.md |

Rules: a phase moves to `done` only with evidence committed alongside it.
