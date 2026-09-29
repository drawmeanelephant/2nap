# Progress ledger

| Phase | Deliverable | Status | Evidence |
|---|---|---|---|
| 0 | Restore point (`restore-point/baseline`) | done | commit b120aed + tag |
| 1 | Fixture corpus copied (data only) + inventory | done | commit 9ed73a1; 41 triples + 16 error cases + 3 examples |
| 2 | Clean-room doc pinning (revisions + sha256) | done | README session table; `.cleanroom/` snapshots |
| 3 | build.zig + CLI shell + diagnostics | done | commit f477b61; zig build clean |
| 4 | Lexer/parser → AST; syntax-error fixtures green | done | `zig build test`: error corpus green |
| 5 | Engine (eval, logic, loops, whitespace) green | done | `zig build test`: var/logic/loop fixtures green |
| 6 | Textile filter registry green | done | `zig build test`: filter fixtures green |
| 7 | Harness + invariant guards + verify.sh red-green | done | commit f477b61; VERIFICATION.md pass 1 (10/10) |
| 8 | README + examples + VERIFICATION.md | done | commit 358e2d1 |
| 9 | Second pass: clean rebuild, acceptance audit | done | VERIFICATION.md pass 2 (11/11) + audit table |

Rules: a phase moves to `done` only with evidence committed alongside it.

Final state: `zig build test` 11/11; `tools/verify.sh` 11/11 including
CLI byte-exactness on all 41 positive fixtures and the red-green mutant
proof. Both passes ran against clean builds (pass 2 after `rm -rf
.zig-cache zig-out`).
