import json
import unittest
import contextlib
import io
import subprocess
import time
import base64
import hashlib
import struct
import zlib
from unittest.mock import patch
from probe import BOUNDS, SHARE_BOUNDS, SOURCE_ENUMS, NOTIFICATION_BOUNDS, InvalidReport, main, validate_checks, validate_report, validate_share, validate_notification, verdict
from probe import CONTENT_BYTES, validate_notification_content, validate_content_state, content_summary


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


class NotificationReadbackTests(unittest.TestCase):
    def sample(self):
        r = {key: 0 for key in NOTIFICATION_BOUNDS}
        r.update(schema=1, kind="NOTIFICATION_SAMPLE", recorded_at_ms=1000000, origin="POSTED", state="SHAPES_PRESENT",
                 capture_enabled=True, notification_access=True, listener_connected=True, limited=False, messaging_style=True,
                 content_exported=False, graphics_decoded=False, notifications=1, messages=1, text_values=1, text_chars=10)
        return r

    def parse(self, r):
        return validate_notification(json.dumps(r).encode(), now_ms=1000000)

    def test_positive_text_and_uri_are_shapes_not_full_content(self):
        self.assertEqual(self.parse(self.sample())["text_values"], 1)
        r=self.sample(); r.update(text_values=0, text_chars=0, uri_attachments=1)
        self.assertEqual(self.parse(r)["uri_attachments"], 1)
        self.assertFalse(self.parse(r)["graphics_decoded"])

    def test_empty_off_and_denied_discriminate(self):
        for state, enabled, access, connected, origin in [("EMPTY",True,True,True,"ACTIVE_SCAN"),
                ("OFF",False,False,False,"STATE"), ("ACCESS_REQUIRED",True,False,False,"STATE"),
                ("WAITING_FOR_LISTENER",True,True,False,"STATE")]:
            r=self.sample(); r.update({key:0 for key in NOTIFICATION_BOUNDS})
            r.update(state=state,capture_enabled=enabled,notification_access=access,listener_connected=connected,origin=origin,messaging_style=False)
            self.assertEqual(self.parse(r)["state"],state)

    def test_synthetic_private_unknown_fields_and_types_reject(self):
        for key,value in [("kind","SYNTHETIC"),("origin","SYNTHETIC"),("private_text","PRIVATE_SENTINEL"),
                ("uri","content://private.invalid/path"),("text_values",True),("messages",11),
                ("graphics_decoded",True),("notification_access",1),("state",[]),("schema",True)]:
            r=self.sample(); r[key]=value
            with self.subTest(key=key), self.assertRaises(InvalidReport): self.parse(r)

    def test_invalid_delivery_and_counter_combinations_reject(self):
        for changes in [dict(notification_access=False),dict(capture_enabled=False),dict(listener_connected=False),
                dict(state="EMPTY"),dict(state="OFF"),dict(text_chars=0),dict(uri_attachments=3),dict(origin="STATE")]:
            r=self.sample();r.update(changes)
            with self.subTest(changes=changes),self.assertRaises(InvalidReport):self.parse(r)

    def test_stale_missing_oversized_duplicate_reject(self):
        for changes in [dict(recorded_at_ms=-1000000),dict(recorded_at_ms=1400000)]:
            r=self.sample();r.update(changes)
            with self.assertRaises(InvalidReport):self.parse(r)
        for raw in [b'',b'{}',b'[]',b'x'*4097,b'{"schema":1,"schema":1}',b'\xff']:
            with self.assertRaises(InvalidReport):validate_notification(raw,now_ms=1000000)

    def test_cli_uses_only_private_diagnostics_and_suppresses_payload(self):
        for invalid in [False,True]:
            r=self.sample();r['recorded_at_ms']=int(time.time()*1000)
            if invalid:r['private_text']='PRIVATE_SENTINEL'
            responses=[subprocess.CompletedProcess([],0,b'device\n',b''),subprocess.CompletedProcess([],0,json.dumps(r).encode(),b'')]
            stdout,stderr=io.StringIO(),io.StringIO()
            with patch.dict('os.environ',{'ANDROID_HOME':'/fixture-sdk'}),patch('sys.argv',['probe.py','--serial','fixture','notification-report']), \
                    patch('subprocess.run',side_effect=responses) as transport,contextlib.redirect_stdout(stdout),contextlib.redirect_stderr(stderr):
                self.assertEqual(main(),1 if invalid else 0)
            self.assertEqual(transport.call_args_list[-1].args[0][-1],'files/notification-summary.json')
            self.assertNotIn('PRIVATE_SENTINEL',stdout.getvalue()+stderr.getvalue())


class NotificationContentReadbackTests(unittest.TestCase):
    def sample(self):
        return dict(schema=1, kind='NOTIFICATION_CONTENT', captured_at_ms=1000000, origin='ACTIVE_SCAN',
                    install_id='57b2dd91-cfa8-4193-9a38-e2d6d6470625', source_key='a'*64, title='PRIVATE_TITLE_SENTINEL',
                    messages=[dict(timestamp_ms=1,text='PRIVATE_BODY_SENTINEL',truncated=False)], truncated=False,
                    image=None,image_state='ABSENT',uri_attachments=0,complete=False)

    def parse(self, r):
        return validate_notification_content(json.dumps(r).encode(), now_ms=1000000)

    def image(self, pixels=b'\0\x22\x33\x44\xff'):
        def chunk(kind, data):
            return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data))
        raw=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',1,1,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(pixels))+chunk(b'IEND',b'')
        return dict(mime='image/png',width=1,height=1,bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest(),data_base64=base64.b64encode(raw).decode())

    def test_real_parser_accepts_text_and_png_not_full_card(self):
        r=self.sample();self.assertEqual(self.parse(r)['messages'][0]['text'],'PRIVATE_BODY_SENTINEL')
        r.update(image=self.image(),image_state='BITMAP_PREVIEW',messages=[])
        self.assertTrue(content_summary(self.parse(r))['image_present'])
        self.assertFalse(content_summary(self.parse(r))['complete'])
        self.assertNotIn('PRIVATE',json.dumps(content_summary(self.parse(self.sample()))))

    def test_schema_types_bounds_and_synthetic_reject(self):
        for key,value in [('kind','SYNTHETIC_NOTIFICATION_CONTENT'),('origin','STATE'),('complete',True),('schema',True),
                ('title','x'*257),('source_key','private-source'),('install_id','not-a-uuid'),('messages',{}),
                ('truncated',1),('uri_attachments',12),('sender','PRIVATE_SENDER'),('captured_at_ms',-1000000)]:
            r=self.sample();r[key]=value
            with self.subTest(key=key),self.assertRaises(InvalidReport):self.parse(r)
        for row in [dict(timestamp_ms=True,text='x',truncated=False),dict(timestamp_ms=0,text='x'*4001,truncated=False),
                dict(timestamp_ms=0,text='x',truncated=0),dict(timestamp_ms=0,text='x',truncated=False,sender='PRIVATE')]:
            r=self.sample();r['messages']=[row]
            with self.assertRaises(InvalidReport):self.parse(r)

    def test_empty_and_impossible_image_states_reject(self):
        for changes in [dict(messages=[]),dict(image_state='BITMAP_PREVIEW'),dict(image=self.image()),dict(messages=[None]),
                dict(messages=self.sample()['messages']*11),dict(image_state=[])]:
            r=self.sample();r.update(changes)
            with self.subTest(changes=list(changes)),self.assertRaises(InvalidReport):self.parse(r)

    def test_png_digest_base64_and_structure_discriminate(self):
        for changes in [dict(sha256='b'*64),dict(width=2),dict(height=0),dict(bytes=1048577),dict(data_base64='not valid'),dict(extra='PRIVATE')]:
            r=self.sample();r.update(image=self.image(),image_state='BITMAP_PREVIEW');r['image'].update(changes)
            with self.subTest(changes=list(changes)),self.assertRaises(InvalidReport):self.parse(r)
        for pixels in [b'\x05\x22\x33\x44\xff',b'\0',b'\0'+b'x'*100000]:
            r=self.sample();r.update(image=self.image(pixels),image_state='BITMAP_PREVIEW')
            with self.assertRaises(InvalidReport):self.parse(r)

    def test_duplicate_unknown_invalid_and_oversized_document_reject(self):
        for raw in [b'',b'{}',b'[]',b'x'*(CONTENT_BYTES+1),b'{"schema":1,"schema":1}',b'\xff']:
            with self.assertRaises(InvalidReport):validate_notification_content(raw,now_ms=1000000)

    def test_state_is_fixed_safe_and_current(self):
        state=dict(schema=1,state='URI_ONLY_UNSUPPORTED',recorded_at_ms=1000000)
        self.assertEqual(validate_content_state(json.dumps(state).encode(),now_ms=1000000)['state'],'URI_ONLY_UNSUPPORTED')
        state['state']='REDACTED'
        self.assertEqual(validate_content_state(json.dumps(state).encode(),now_ms=1000000)['state'],'REDACTED')
        for key,value in [('state','PRIVATE_ERROR'),('schema',True),('recorded_at_ms',-1000000),('text','PRIVATE_BODY')]:
            invalid=state.copy();invalid[key]=value
            with self.assertRaises(InvalidReport):validate_content_state(json.dumps(invalid).encode(),now_ms=1000000)

    def test_cli_never_prints_content_and_refuses_race(self):
        for mode in ['valid','private-field','raced']:
            r=self.sample();now=int(time.time()*1000);r['captured_at_ms']=now
            if mode=='private-field':r['PRIVATE_BODY_SENTINEL']='PRIVATE_BODY_SENTINEL'
            state=json.dumps(dict(schema=1,state='SAVED',recorded_at_ms=now)).encode()
            last=state if mode!='raced' else json.dumps(dict(schema=1,state='CLEARED',recorded_at_ms=now+1)).encode()
            results=[b'device\n',state,json.dumps(r).encode(),last]
            responses=[subprocess.CompletedProcess([],0,data,b'') for data in results]
            stdout,stderr=io.StringIO(),io.StringIO()
            with patch.dict('os.environ',{'ANDROID_HOME':'/fixture-sdk'}),patch('sys.argv',['probe.py','--serial','fixture','notification-content-summary']), \
                    patch('subprocess.run',side_effect=responses) as transport,contextlib.redirect_stdout(stdout),contextlib.redirect_stderr(stderr):
                self.assertEqual(main(),0 if mode=='valid' else 1)
            self.assertNotIn('PRIVATE',stdout.getvalue()+stderr.getvalue())
            self.assertNotIn(r['install_id'],stdout.getvalue()+stderr.getvalue())
            self.assertIn('files/notification-content.json',transport.call_args_list[2].args[0])

    def test_unsupported_state_does_not_read_a_previous_sample(self):
        state=json.dumps(dict(schema=1,state='URI_ONLY_UNSUPPORTED',recorded_at_ms=int(time.time()*1000))).encode()
        stdout=io.StringIO()
        responses=[subprocess.CompletedProcess([],0,data,b'') for data in [b'device\n',state]]
        with patch.dict('os.environ',{'ANDROID_HOME':'/fixture-sdk'}),patch('sys.argv',['probe.py','--serial','fixture','notification-content-summary']), \
                patch('subprocess.run',side_effect=responses) as transport,contextlib.redirect_stdout(stdout):
            self.assertEqual(main(),0)
        self.assertEqual(transport.call_count,2)
        self.assertEqual(json.loads(stdout.getvalue())['verdict'],'URI_ONLY_UNSUPPORTED')


if __name__ == "__main__":
    unittest.main()
