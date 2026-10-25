import json
import unittest
import contextlib
import io
import subprocess
import time
from unittest.mock import patch
from probe import BOUNDS, SHARE_BOUNDS, SOURCE_ENUMS, InvalidReport, main, validate_checks, validate_report, validate_share, verdict


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


class ShareReadbackTests(unittest.TestCase):
    def sample(self):
        result = {key: 0 for key in SHARE_BOUNDS}
        result.update(schema=1, kind="SHARED_CONTENT", recorded_at_ms=1_000_000,
                      state="IMAGE_READABLE", block_reason="NONE", text_present=False, limited=False,
                      message_content_exported=False, full_card_proven=False,
                      uris=1, attempted_images=1, readable_images=1)
        return result

    def parse(self, report):
        return validate_share(json.dumps(report).encode(), now_ms=1_000_000)

    def test_real_image_differs_from_text_and_blocked(self):
        self.assertEqual(self.parse(self.sample())["state"], "IMAGE_READABLE")
        text = self.sample(); text.update(state="TEXT_OR_LINK_ONLY", text_present=True,
                                         uris=0, attempted_images=0, readable_images=0, links=1)
        self.assertEqual(self.parse(text)["state"], "TEXT_OR_LINK_ONLY")
        blocked = self.sample(); blocked.update(state="BLOCKED", attempted_images=0,
                                                readable_images=0, blocked_uris=1, block_reason="READ_GRANT_MISSING")
        self.assertEqual(self.parse(blocked)["state"], "BLOCKED")

    def test_share_rejects_private_fields_synthetic_and_unsupported_states(self):
        for key, value in [("uri", "PRIVATE_SENTINEL"), ("body", "PRIVATE_SENTINEL"),
                           ("kind", "SYNTHETIC_SHARE"), ("state", "PRIVATE_SENTINEL"),
                           ("full_card_proven", True), ("message_content_exported", True),
                           ("state", []), ("schema", True), ("text_present", 0)]:
            sample = self.sample(); sample[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(InvalidReport): self.parse(sample)

    def test_share_rejects_impossible_counts_and_false_image_verdicts(self):
        for changes in [dict(uris=0), dict(attempted_images=0), dict(readable_images=0),
                        dict(links=1), dict(blocked_uris=1), dict(state="TEXT_OR_LINK_ONLY"),
                        dict(readable_images=4), dict(uris=True), dict(state="EMPTY"),
                        dict(state="PARTIAL_IMAGE"), dict(recorded_at_ms=1_400_000),
                        dict(recorded_at_ms=-1_000_000)]:
            sample = self.sample(); sample.update(changes)
            with self.subTest(changes=changes), self.assertRaises(InvalidReport): self.parse(sample)

    def test_share_rejects_bad_input_and_missing_keys(self):
        for raw in [b"", b"[]", b"null", b"x" * 4097, b"\xff", b'{"schema":1,"schema":1}',
                    b"[" * 1500 + b"]" * 1500]:
            with self.assertRaises(InvalidReport): validate_share(raw, now_ms=1_000_000)
        sample = self.sample(); del sample["state"]
        with self.assertRaises(InvalidReport): self.parse(sample)

    def test_share_cli_uses_only_its_fixed_file_and_never_echoes_content(self):
        for private in [False, True]:
            sample = self.sample(); sample["recorded_at_ms"] = int(time.time() * 1000)
            if private: sample["uri"] = "PRIVATE_SENTINEL"
            responses = [subprocess.CompletedProcess([], 0, b"device\n", b""),
                         subprocess.CompletedProcess([], 0, json.dumps(sample).encode(), b"")]
            stdout, stderr = io.StringIO(), io.StringIO()
            with patch.dict("os.environ", {"ANDROID_HOME": "/fixture-sdk"}), \
                    patch("sys.argv", ["probe.py", "--serial", "fixture-device", "share-report"]), \
                    patch("subprocess.run", side_effect=responses) as transport, \
                    contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                self.assertEqual(main(), 1 if private else 0)
            self.assertNotIn("PRIVATE_SENTINEL", stdout.getvalue() + stderr.getvalue())
            self.assertEqual(transport.call_args_list[-1].args[0][-1], "files/share-summary.json")


class SourceReadbackTests(ShareReadbackTests):
    def sample(self):
        result = super().sample()
        result.update(schema=2, uri_policy_detail="ALLOWED", provider_owner="GOOGLE_MESSAGES",
                      provider_access="PRIVATE_GRANT_CAPABLE", explicit_read_grant="GRANTED", share_read_flag=True)
        return result

    def test_real_image_differs_from_text_and_blocked(self):
        self.assertEqual(self.parse(self.sample())["state"], "IMAGE_READABLE")
        text = self.sample(); text.update(state="TEXT_OR_LINK_ONLY", text_present=True,
                                         uris=0, attempted_images=0, readable_images=0, links=1)
        text.update({key: "NOT_CHECKED" for key in SOURCE_ENUMS})
        self.assertEqual(self.parse(text)["state"], "TEXT_OR_LINK_ONLY")
        blocked = self.sample(); blocked.update(state="BLOCKED", attempted_images=0, readable_images=0,
            blocked_uris=1, block_reason="URI_POLICY", uri_policy_detail="AUTHORITY_NOT_ALLOWED")
        self.assertEqual(self.parse(blocked)["provider_owner"], "GOOGLE_MESSAGES")

    def test_source_categories_reject_arbitrary_strings_and_private_fields(self):
        for key in SOURCE_ENUMS:
            for value in ["PRIVATE_SOURCE_SENTINEL", "com.google.android.apps.messaging", "content://private.invalid/1", [], None, True]:
                report = self.sample(); report[key] = value
                with self.subTest(key=key, value=value), self.assertRaises(InvalidReport): self.parse(report)
        for key in ["authority", "package_name", "path", "filename", "source_hash"]:
            report = self.sample(); report[key] = "PRIVATE_SOURCE_SENTINEL"
            with self.assertRaises(InvalidReport): self.parse(report)

    def test_source_v2_requires_exact_schema_and_boolean(self):
        for changes in [dict(share_read_flag=1), dict(schema=3), dict(schema=1)]:
            report = self.sample(); report.update(changes)
            with self.assertRaises(InvalidReport): self.parse(report)
        for key in (*SOURCE_ENUMS, "share_read_flag"):
            report = self.sample(); del report[key]
            with self.assertRaises(InvalidReport): self.parse(report)

    def test_source_rejects_inconsistent_categories(self):
        for changes in [dict(uris=0, attempted_images=0, readable_images=0, state="EMPTY"),
                        dict(provider_owner="MULTIPLE"), dict(uri_policy_detail="NOT_CHECKED"),
                        dict(provider_access="UNRESOLVED"), dict(provider_owner="UNAVAILABLE"),
                        dict(uri_policy_detail="NON_CONTENT"),
                        dict(provider_owner="NOT_CHECKED", provider_access="NOT_CHECKED"),
                        dict(share_read_flag=False), dict(explicit_read_grant="NOT_CHECKED")]:
            report = self.sample(); report.update(changes)
            with self.subTest(changes=changes), self.assertRaises(InvalidReport): self.parse(report)

    def test_source_unknown_is_not_absent_image_or_permission_denial(self):
        for owner, access in [("GOOGLE_MESSAGES", "PRIVATE_GRANT_CAPABLE"), ("OTHER_APP", "EXPORTED"),
                              ("UNRESOLVED", "UNRESOLVED"), ("UNAVAILABLE", "UNAVAILABLE")]:
            report = self.sample(); report.update(state="BLOCKED", block_reason="URI_POLICY", blocked_uris=1,
                attempted_images=0, readable_images=0, uri_policy_detail="AUTHORITY_NOT_ALLOWED",
                provider_owner=owner, provider_access=access)
            self.assertEqual(self.parse(report)["state"], "BLOCKED")
        report = self.sample(); report.update(state="BLOCKED", block_reason="URI_POLICY", blocked_uris=1,
                                              attempted_images=0, readable_images=0)
        with self.assertRaises(InvalidReport): self.parse(report)

    def test_source_timeout_can_explicitly_omit_unfinished_diagnostics(self):
        report = self.sample(); report.update(state="TIMEOUT", attempted_images=0, readable_images=0)
        report.update({key: "NOT_CHECKED" for key in SOURCE_ENUMS})
        self.assertEqual(self.parse(report)["uri_policy_detail"], "NOT_CHECKED")

    def test_legacy_readback_does_not_invent_source_categories(self):
        legacy = ShareReadbackTests().sample()
        self.assertNotIn("provider_owner", self.parse(legacy))

    def test_source_cli_suppresses_private_category_values(self):
        report = self.sample(); report.update(recorded_at_ms=int(time.time() * 1000), provider_owner="PRIVATE_SOURCE_SENTINEL")
        responses = [subprocess.CompletedProcess([], 0, b"device\n", b""),
                     subprocess.CompletedProcess([], 0, json.dumps(report).encode(), b"")]
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.dict("os.environ", {"ANDROID_HOME": "/fixture-sdk"}), \
                patch("sys.argv", ["probe.py", "--serial", "fixture-device", "share-report"]), \
                patch("subprocess.run", side_effect=responses), \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(main(), 1)
        self.assertNotIn("PRIVATE_SOURCE_SENTINEL", stdout.getvalue() + stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
