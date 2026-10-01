"""Tests of the harness's fail-closed contract, not of the oracle internals."""

from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from differential import ROOT, compare, diagnostic, main
from differential_corpus import Case, corpus


def result(code=0, stdout=b"text", stderr=b""):
    return subprocess.CompletedProcess([], code, stdout, stderr)


class DifferentialTests(unittest.TestCase):
    def check_pair(self, left, right, expected=None):
        with patch("differential.run", side_effect=[left, right]):
            return compare(Case("test", b"{{ x }}", b'{"x":"text"}', expected),
                           Path("/candidate"), Path("/oracle"), 1)

    def test_identical_success(self):
        self.assertIsNone(self.check_pair(result(), result(), 0))

    def test_bytes_are_not_trimmed_or_decoded(self):
        for changed in (b"text\n", b"text\r\n", b"text ", b"\xfftext", b"text\x00"):
            with self.subTest(changed=changed):
                self.assertIn("stdout bytes", self.check_pair(result(stdout=changed), result())["issues"])

    def test_exit_status_matters(self):
        self.assertIn("exit status", self.check_pair(result(1, b""), result())["issues"])

    def test_matching_errors_do_not_satisfy_success_case(self):
        self.assertIn("expected exit 0", self.check_pair(result(1, b""), result(1, b""), 0)["issues"])

    def test_matching_success_does_not_satisfy_error_case(self):
        self.assertIn("expected exit 1", self.check_pair(result(), result(), 1)["issues"])

    def test_only_known_cli_envelopes_are_removed(self):
        message = b"syntax error at line 1, column 1: bad\n"
        self.assertIsNone(self.check_pair(result(1, b"", b"knap-textile: error: " + message),
                                         result(1, b"", b"k4o: " + message), 1))
        self.assertEqual(diagnostic(b"xk4o: bad", b"k4o: "), b"xk4o: bad")
        self.assertIn("diagnostic bytes", self.check_pair(result(stderr=b"warning\n"), result())["issues"])
        self.assertIn("diagnostic bytes", self.check_pair(
            result(1, b"", b"knap-textile: error: " + message),
            result(1, b"", b"k4o: " + message.replace(b"column 1", b"column 2")))["issues"])

    def test_partial_output_is_failure_even_when_identical(self):
        self.assertIn("partial output on error", self.check_pair(result(1), result(1))["issues"])

    def test_crash_is_failure_even_when_identical(self):
        self.assertIn("abnormal exit", self.check_pair(result(-11, b""), result(-11, b""))["issues"])

    def test_timeout_and_launch_failure_are_not_skipped(self):
        for error in (subprocess.TimeoutExpired("oracle", 1), FileNotFoundError("missing binary")):
            with patch("differential.run", side_effect=error):
                self.assertIn("infrastructure_error", compare(
                    Case("test", b""), Path("/candidate"), Path("/oracle"), 1))

    def test_whole_corpus_is_stable_and_includes_every_fixture(self):
        cases = list(corpus(ROOT))
        self.assertEqual(cases, list(corpus(ROOT)))
        self.assertGreater(len(cases), 2400)
        names = [case.name for case in cases]
        self.assertEqual(len(names), len(set(names)))
        for directory in ("fixtures", "fixtures/errors", "examples"):
            for template in (ROOT / directory).glob("*.knap"):
                self.assertIn(template.relative_to(ROOT).as_posix(), names)

    def test_cli_returns_failure_and_writes_report_then_returns_green(self):
        with tempfile.TemporaryDirectory() as work:
            binary = Path(work) / "binary"
            binary.touch()
            report = Path(work) / "report.json"
            argv = ["differential", "--candidate", str(binary), "--oracle", str(binary),
                    "--report", str(report), "--jobs", "1"]
            with patch("sys.argv", argv), patch("differential.corpus", return_value=[Case("test", b"{{ x }}")]):
                with patch("differential.run", side_effect=[result(stdout=b"wrong\n"), result()]), redirect_stdout(io.StringIO()):
                    self.assertEqual(main(), 1)
                self.assertEqual(json.loads(report.read_text())["divergences"], 1)
                with patch("differential.run", side_effect=[result(), result()]), redirect_stdout(io.StringIO()):
                    self.assertEqual(main(), 0)
                self.assertEqual(json.loads(report.read_text())["divergences"], 0)


if __name__ == "__main__":
    unittest.main()
