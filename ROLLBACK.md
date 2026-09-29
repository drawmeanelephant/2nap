# Rollback note

Restore point: git tag **`restore-point/baseline`** (baseline scaffold: process
docs + .gitignore, no code).

Restore commands:

```sh
cd /Users/tbuddy/dev/z/muse-textile-project
git reset --hard restore-point/baseline   # discard all work after the tag
# or, to inspect without destroying:
git checkout restore-point/baseline -- .
```

Later phases add their own commits; any single phase can be undone with
`git revert <sha>` or by resetting to the tagged baseline. Nothing outside this
directory is modified by this project, so rollback is fully contained here.
