import json
import unittest
import contextlib
import io
import subprocess
import time
from unittest.mock import patch
from probe import BOUNDS, InvalidReport, main, validate_checks, validate_report, verdict


class ReadbackTests(unittest.TestCase):
    def sample(self):
        result = {key: 0 for key in BOUNDS}
        result.update(schema=1, kind="SELECTED_HISTORY", recorded_at_ms=1_000_000,
                      sms="OK", mms="OK", limited=False, message_content_exported=False,
                      provider_sample_complete=False, sms_rows=1, text_messages=1, links=1)
        return result

    def parse(self, sample):
        return validate_report(json.dumps(sample).encode(), now_ms=1_000_000)

    def test_positive(self):
        self.assertEqual(verdict(self.parse(self.sample())), "CONTENT_EXPOSED_NOT_FULL_CARD_PROOF")

    def test_blocked_not_empty(self):
        sample = self.sample(); sample["sms"] = "BLOCKED"
        self.assertEqual(verdict(self.parse(sample)), "PARTIAL_OR_BLOCKED")

    def test_empty_is_not_payload_proof(self):
        sample = self.sample(); sample.update(sms_rows=0, text_messages=0, links=0)
        self.assertEqual(verdict(self.parse(sample)), "EMPTY_SAMPLE")

    def test_rejects_content_unknown_fields_and_synthetic(self):
        for key, value in [("body", "PRIVATE_SENTINEL"), ("url", "https://example.invalid"),
                           ("kind", "SYNTHETIC"), ("schema", 2), ("sms", "PRIVATE_SENTINEL")]:
            with self.subTest(key=key):
                sample = self.sample(); sample[key] = value
                with self.assertRaises(InvalidReport): self.parse(sample)

    def test_rejects_wrong_types_bounds_and_missing(self):
        for key, value in [("sms_rows", -1), ("readable_images", 4), ("links", True),
                           ("limited", 0), ("message_content_exported", 0), ("sms", []),
                           ("provider_sample_complete", True), ("recorded_at_ms", True)]:
            with self.subTest(key=key):
                sample = self.sample(); sample[key] = value
                with self.assertRaises(InvalidReport): self.parse(sample)
        sample = self.sample(); del sample["links"]
        with self.assertRaises(InvalidReport): self.parse(sample)

    def test_rejects_absent_malformed_oversized_and_duplicate(self):
        for raw in [b"", b"no data", b"x" * 4097, b"[]", b"null", b"\xff",
                    b'{"schema":1,"schema":1}']:
            with self.subTest(size=len(raw)):
                with self.assertRaises(InvalidReport): validate_report(raw, now_ms=1_000_000)

    def test_rejects_stale_future_and_inconsistent(self):
        for changes in [dict(recorded_at_ms=-1_000_000), dict(recorded_at_ms=1_400_000),
                        dict(text_messages=2), dict(readable_images=1)]:
            sample = self.sample(); sample.update(changes)
            with self.assertRaises(InvalidReport): self.parse(sample)

    def test_assertion_runner_can_go_red(self):
        prefix = "INSTRUMENTATION_RESULT: stream=PASS: 47 assertions; fixture controls\n"
        for branch in ["GRANTED_NO_PROVIDER_READS", "DENIED_GUARD_TESTED"]:
            raw = prefix + "INSTRUMENTATION_RESULT: permission_branch=" + branch + "\nINSTRUMENTATION_CODE: -1\n"
            self.assertEqual(validate_checks(raw)["permission_branch"], branch)
        for raw in ["", prefix, prefix + "INSTRUMENTATION_CODE: 0\n", "FAIL PRIVATE_SENTINEL"]:
            with self.assertRaises(InvalidReport): validate_checks(raw)

    def test_cli_transport_positive_and_content_rejection(self):
        for with_private_field in [False, True]:
            sample = self.sample(); sample["recorded_at_ms"] = int(time.time() * 1000)
            if with_private_field: sample["body"] = "PRIVATE_SENTINEL"
            responses = [subprocess.CompletedProcess([], 0, b"device\n", b""),
                         subprocess.CompletedProcess([], 0, json.dumps(sample).encode(), b"")]
            stdout, stderr = io.StringIO(), io.StringIO()
            with patch.dict("os.environ", {"ANDROID_HOME": "/fixture-sdk"}), \
                    patch("sys.argv", ["probe.py", "--serial", "fixture-device", "report"]), \
                    patch("subprocess.run", side_effect=responses) as transport, \
                    contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = main()
            self.assertNotIn("PRIVATE_SENTINEL", stdout.getvalue() + stderr.getvalue())
            self.assertEqual(code, 1 if with_private_field else 0)
            if not with_private_field:
                self.assertEqual(json.loads(stdout.getvalue())["report"]["links"], 1)
            command = transport.call_args_list[-1].args[0]
            self.assertEqual(command[-1], "files/probe-summary.json")
            self.assertNotIn("content://sms", command)

    def test_cli_failure_never_echoes_adb_or_file_error_strings(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        response = subprocess.CompletedProcess([], 1, b"PRIVATE_SENTINEL", b"PRIVATE_SENTINEL")
        with patch.dict("os.environ", {"ANDROID_HOME": "/fixture-sdk"}), \
                patch("sys.argv", ["probe.py", "--serial", "fixture-device", "report"]), \
                patch("subprocess.run", return_value=response), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(main(), 1)
        self.assertNotIn("PRIVATE_SENTINEL", stdout.getvalue() + stderr.getvalue())

    def test_instrument_timeout_stops_only_owned_probe_not_other_apps(self):
        responses = [subprocess.CompletedProcess([], 0, b"device\n", b""),
                     subprocess.CompletedProcess([], 0, b"1\n", b""),
                     subprocess.TimeoutExpired("fixture", 45),
                     subprocess.CompletedProcess([], 0, b"", b"")]
        with patch.dict("os.environ", {"ANDROID_HOME": "/fixture-sdk"}), \
                patch("sys.argv", ["probe.py", "--serial", "fixture-device", "self-test"]), \
                patch("subprocess.run", side_effect=responses) as transport, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(main(), 1)
        self.assertEqual(transport.call_args_list[-1].args[0][-4:],
                         ["shell", "am", "force-stop", "dev.textem.probe"])

    def test_report_timeout_does_not_stop_the_app(self):
        responses = [subprocess.CompletedProcess([], 0, b"device\n", b""),
                     subprocess.TimeoutExpired("fixture", 15)]
        with patch.dict("os.environ", {"ANDROID_HOME": "/fixture-sdk"}), \
                patch("sys.argv", ["probe.py", "--serial", "fixture-device", "report"]), \
                patch("subprocess.run", side_effect=responses) as transport, \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(main(), 1)
        self.assertEqual(transport.call_count, 2)

    def test_cold_boot_is_not_misreported_as_a_probe_test_failure(self):
        responses = [subprocess.CompletedProcess([], 0, b"device\n", b""),
                     subprocess.CompletedProcess([], 0, b"\n", b"")]
        stderr = io.StringIO()
        with patch.dict("os.environ", {"ANDROID_HOME": "/fixture-sdk"}), \
                patch("sys.argv", ["probe.py", "--serial", "fixture-device", "self-test"]), \
                patch("subprocess.run", side_effect=responses) as transport, \
                contextlib.redirect_stderr(stderr):
            self.assertEqual(main(), 1)
        self.assertIn("not fully booted", stderr.getvalue())
        self.assertEqual(transport.call_count, 2)


if __name__ == "__main__":
    unittest.main()
