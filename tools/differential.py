#!/usr/bin/env python3
"""Run two executables on identical inputs; compare bytes, exit, diagnostics."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import difflib
import json
from pathlib import Path
import subprocess
import tempfile

from differential_corpus import corpus

ROOT = Path(__file__).resolve().parents[1]


def diagnostic(stderr, prefix):
    # The executable's name is the ONLY normalization, never output bytes.
    return stderr.removeprefix(prefix)


def run(binary, template, data, timeout):
    command = [str(binary), "render", str(template)]
    if data is not None:
        command += ["--data", str(data)]
    return subprocess.run(command, capture_output=True, timeout=timeout, check=False)


def compare(case, candidate, oracle, timeout):
    with tempfile.TemporaryDirectory(prefix="2nap-differential-") as work:
        template = Path(work) / "template.knap"
        template.write_bytes(case.template)
        data = None
        if case.data is not None:
            data = Path(work) / "data.json"
            data.write_bytes(case.data)
        try:
            left = run(candidate, template, data, timeout)
            right = run(oracle, template, data, timeout)
        except (OSError, subprocess.TimeoutExpired) as exc:
            return {"name": case.name, "infrastructure_error": str(exc)}
    issues = []
    if left.returncode not in (0, 1) or right.returncode not in (0, 1):
        issues.append("abnormal exit")
    if left.returncode != right.returncode:
        issues.append("exit status")
    if case.expected_status is not None and (
        left.returncode != case.expected_status or right.returncode != case.expected_status
    ):
        issues.append(f"expected exit {case.expected_status}")
    if left.stdout != right.stdout:
        issues.append("stdout bytes")
    if diagnostic(left.stderr, b"knap-textile: error: ") != diagnostic(right.stderr, b"k4o: "):
        issues.append("diagnostic bytes")
    if (left.returncode and left.stdout) or (right.returncode and right.stdout):
        issues.append("partial output on error")
    if not issues:
        return None
    return {
        "name": case.name, "issues": issues,
        "template": case.template.decode("utf-8", "backslashreplace"),
        "data": None if case.data is None else case.data.decode("utf-8", "backslashreplace"),
        "candidate": {"exit": left.returncode, "stdout": repr(left.stdout), "stderr": repr(left.stderr)},
        "oracle": {"exit": right.returncode, "stdout": repr(right.stdout), "stderr": repr(right.stderr)},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, default=ROOT / "zig-out/bin/knap-textile")
    parser.add_argument("--oracle", type=Path, default=ROOT / ".oracle/k4o")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--match", default="", help="case-name substring (default: whole corpus)")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--timeout", type=float, default=10)
    args = parser.parse_args()
    if args.jobs < 1 or args.timeout <= 0:
        parser.error("--jobs and --timeout must be positive")
    for binary in (args.candidate, args.oracle):
        if not binary.is_file():
            parser.error(f"missing executable: {binary}")
    revision = (ROOT / "tools/k4o-revision.txt").read_text().strip()
    if args.oracle.resolve() == (ROOT / ".oracle/k4o").resolve():
        stamp = ROOT / ".oracle/revision.txt"
        if not stamp.is_file() or stamp.read_text().strip() != revision:
            parser.error("stale or unverified oracle; run python3 tools/build_oracle.py")
    cases = [case for case in corpus(ROOT) if args.match in case.name]
    if not cases:
        parser.error("empty corpus selection")
    names = [case.name for case in cases]
    if len(set(names)) != len(names):
        parser.error("duplicate case names")
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(lambda case: compare(
            case, args.candidate.resolve(), args.oracle.resolve(), args.timeout
        ), cases))
    divergences = [result for result in results if result is not None]
    for result in divergences:
        print(f"\nFAIL {result['name']}")
        if "infrastructure_error" in result:
            print(result["infrastructure_error"])
            continue
        print(", ".join(result["issues"]))
        for line in difflib.unified_diff(
            json.dumps(result["oracle"], indent=2).splitlines(),
            json.dumps(result["candidate"], indent=2).splitlines(),
            fromfile="k4o", tofile="2nap", lineterm="",
        ):
            print(line)
    summary = {"oracle_revision": revision, "custom_oracle": args.oracle.resolve() != (ROOT / ".oracle/k4o").resolve(),
               "cases": len(cases), "divergences": len(divergences), "failures": divergences}
    if args.report:
        args.report.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(f"\nDifferential: {len(cases)} cases, {len(divergences)} divergences")
    return 1 if divergences else 0


if __name__ == "__main__":
    raise SystemExit(main())
