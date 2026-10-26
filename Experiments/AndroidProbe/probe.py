#!/usr/bin/env python3
"""Explicit-device automated checks and fixed-field readback; never pulls messages/UI."""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

BOUNDS = {
    "sms_rows": 20, "mms_rows": 20, "text_messages": 40, "links": 1_000_000,
    "image_parts": 640, "readable_images": 3, "unreadable_images": 3,
    "oversized_images": 3, "skipped_images": 640, "part_failures": 20,
}
KEYS = set(BOUNDS) | {"schema", "kind", "recorded_at_ms", "sms", "mms", "limited",
                      "message_content_exported", "provider_sample_complete"}
STATES = {"OK", "BLOCKED", "UNAVAILABLE", "ERROR"}
SHARE_BOUNDS = {"uris": 8, "attempted_images": 3, "readable_images": 3,
                "blocked_uris": 8, "unreadable_images": 3, "oversized_images": 3,
                "skipped_uris": 8, "links": 10_000}
SHARE_KEYS = set(SHARE_BOUNDS) | {"schema", "kind", "recorded_at_ms", "state",
                                 "block_reason", "text_present", "limited", "message_content_exported", "full_card_proven"}
SHARE_STATES = {"IMAGE_READABLE", "PARTIAL_IMAGE", "TEXT_OR_LINK_ONLY", "EMPTY", "BLOCKED",
                "UNREADABLE", "UNSUPPORTED", "MALFORMED", "TIMEOUT", "ERROR"}
BLOCK_REASONS = {"NONE", "URI_POLICY", "READ_GRANT_MISSING", "PROVIDER_POLICY", "READ_DENIED", "MULTIPLE"}
SOURCE_ENUMS = {
    "uri_policy_detail": {"NOT_CHECKED", "ALLOWED", "NON_CONTENT", "AUTHORITY_NOT_ALLOWED",
                          "USER_INFO_PRESENT", "PORT_PRESENT", "FRAGMENT_PRESENT", "LENGTH_LIMIT", "MULTIPLE"},
    "provider_owner": {"NOT_CHECKED", "GOOGLE_MESSAGES", "OTHER_APP", "UNRESOLVED", "UNAVAILABLE", "MULTIPLE"},
    "provider_access": {"NOT_CHECKED", "PRIVATE_GRANT_CAPABLE", "EXPORTED", "PRIVATE_NO_GRANTS",
                        "UNRESOLVED", "UNAVAILABLE", "MULTIPLE"},
    "explicit_read_grant": {"NOT_CHECKED", "GRANTED", "DENIED", "UNAVAILABLE", "MULTIPLE"},
}
SHARE_V2_KEYS = SHARE_KEYS | set(SOURCE_ENUMS) | {"share_read_flag"}
NOTIFICATION_BOUNDS = {"notifications": 1, "messages": 10, "text_values": 10, "text_chars": 40000,
                       "bitmap_pictures": 1, "bitmap_picture_icons": 1, "uri_attachments": 11,
                       "shortcut_ids": 1, "conversation_titles": 1, "summaries_skipped": 1}
NOTIFICATION_KEYS = set(NOTIFICATION_BOUNDS) | {"schema", "kind", "recorded_at_ms", "origin", "state",
    "capture_enabled", "notification_access", "listener_connected", "limited", "messaging_style", "content_exported", "graphics_decoded"}


def validate_notification(raw, now_ms=None):
    if not raw or len(raw) > 4096:
        raise InvalidReport()
    try:
        r = json.loads(raw, object_pairs_hook=_unique)
        if not isinstance(r, dict) or set(r) != NOTIFICATION_KEYS or type(r["schema"]) is not int or r["schema"] != 1:
            raise InvalidReport()
        if r["kind"] != "NOTIFICATION_SAMPLE" or r["origin"] not in {"STATE", "POSTED", "ACTIVE_SCAN"}:
            raise InvalidReport()
        if r["state"] not in {"OFF", "ACCESS_REQUIRED", "OTHER_APP_IGNORED", "MALFORMED", "SUMMARY_SKIPPED",
                              "EMPTY", "SHAPES_PRESENT", "LISTENING", "WAITING_FOR_LISTENER", "UNAVAILABLE"}:
            raise InvalidReport()
        for key in ["capture_enabled", "notification_access", "listener_connected", "limited", "messaging_style", "content_exported", "graphics_decoded"]:
            if type(r[key]) is not bool:
                raise InvalidReport()
        if r["content_exported"] or r["graphics_decoded"]:
            raise InvalidReport()
        for key, maximum in NOTIFICATION_BOUNDS.items():
            if type(r[key]) is not int or not 0 <= r[key] <= maximum:
                raise InvalidReport()
        now = int(time.time() * 1000) if now_ms is None else now_ms
        if type(r["recorded_at_ms"]) is not int or not now - 1800000 <= r["recorded_at_ms"] <= now + 300000:
            raise InvalidReport()
        if not r["text_values"] <= r["text_chars"] <= r["text_values"] * 4000 or r["text_values"] > r["messages"]:
            raise InvalidReport()
        if (r["uri_attachments"] > r["messages"] + 1 or r["shortcut_ids"] > r["notifications"]
                or r["conversation_titles"] > r["notifications"]):
            raise InvalidReport()
        shapes = sum(r[k] for k in ("text_values", "bitmap_pictures", "bitmap_picture_icons", "uri_attachments"))
        enabled, access, connected = r["capture_enabled"], r["notification_access"], r["listener_connected"]
        if r["origin"] in {"POSTED", "ACTIVE_SCAN"} and not connected:
            raise InvalidReport()
        state = r["state"]
        if r["origin"] == "STATE" and state in {"SUMMARY_SKIPPED", "MALFORMED", "OTHER_APP_IGNORED"}:
            raise InvalidReport()
        if state in {"SHAPES_PRESENT", "EMPTY"}:
            if (not enabled or not access or r["summaries_skipped"] or r["origin"] == "STATE"
                    or (state == "SHAPES_PRESENT" and (r["notifications"] != 1 or shapes == 0))
                    or (state == "EMPTY" and shapes != 0)):
                raise InvalidReport()
        else:
            if (r["messages"] + shapes + r["notifications"] + r["shortcut_ids"] + r["conversation_titles"]
                    or r["messaging_style"] or r["limited"]):
                raise InvalidReport()
            if state == "SUMMARY_SKIPPED":
                if not enabled or not access or r["summaries_skipped"] != 1:
                    raise InvalidReport()
            elif r["summaries_skipped"]:
                raise InvalidReport()
            if ((state == "OFF" and enabled) or (state == "ACCESS_REQUIRED" and (not enabled or access))
                    or (state == "LISTENING" and not (enabled and access and connected))
                    or (state == "WAITING_FOR_LISTENER" and not (enabled and access and not connected))
                    or (state in {"MALFORMED", "OTHER_APP_IGNORED", "UNAVAILABLE"} and not (enabled and access))):
                raise InvalidReport()
        return r
    except (ValueError, TypeError, KeyError, UnicodeError, RecursionError):
        raise InvalidReport() from None


def validate_source(report):
    for key, choices in SOURCE_ENUMS.items():
        if type(report[key]) is not str or report[key] not in choices:
            raise InvalidReport()
    if type(report["share_read_flag"]) is not bool:
        raise InvalidReport()
    policy, owner, access, grant = (report[key] for key in SOURCE_ENUMS)
    values = (policy, owner, access, grant)
    if ((report["uris"] == 0 and any(v != "NOT_CHECKED" for v in values))
            or (report["uris"] < 2 and "MULTIPLE" in values)
            or (policy == "NOT_CHECKED" and any(v != "NOT_CHECKED" for v in values[1:]))):
        raise InvalidReport()
    for paired in ("NOT_CHECKED", "UNRESOLVED", "UNAVAILABLE"):
        if (owner == paired) != (access == paired):
            raise InvalidReport()
    if ((owner == "NOT_CHECKED" and grant != "NOT_CHECKED")
            or (owner != "NOT_CHECKED" and grant == "NOT_CHECKED")
            or (policy == "ALLOWED" and owner == "NOT_CHECKED")
            or (policy not in {"NOT_CHECKED", "ALLOWED", "AUTHORITY_NOT_ALLOWED", "MULTIPLE"}
                and owner != "NOT_CHECKED")
            or (report["block_reason"] == "URI_POLICY" and policy in {"ALLOWED", "NOT_CHECKED"})):
        raise InvalidReport()
    if report["readable_images"] and (not report["share_read_flag"] or policy not in {"ALLOWED", "MULTIPLE"}):
        raise InvalidReport()


class InvalidReport(Exception):
    """Deliberately does not carry source strings or exception messages."""


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidReport()
        result[key] = value
    return result


def validate_report(raw, now_ms=None):
    if not raw or len(raw) > 4096:
        raise InvalidReport()
    try:
        report = json.loads(raw, object_pairs_hook=_unique)
        if not isinstance(report, dict) or set(report) != KEYS:
            raise InvalidReport()
        if type(report["schema"]) is not int or report["schema"] != 1:
            raise InvalidReport()
        if report["kind"] != "SELECTED_HISTORY":
            raise InvalidReport()
        if report["sms"] not in STATES or report["mms"] not in STATES:
            raise InvalidReport()
        if (type(report["limited"]) is not bool
                or report["message_content_exported"] is not False
                or report["provider_sample_complete"] is not False):
            raise InvalidReport()
        for key, maximum in BOUNDS.items():
            if type(report[key]) is not int or not 0 <= report[key] <= maximum:
                raise InvalidReport()
        now = int(time.time() * 1000) if now_ms is None else now_ms
        stamp = report["recorded_at_ms"]
        if type(stamp) is not int or not now - 1_800_000 <= stamp <= now + 300_000:
            raise InvalidReport()
        if report["text_messages"] > report["sms_rows"] + report["mms_rows"]:
            raise InvalidReport()
        outcomes = sum(report[k] for k in ("readable_images", "unreadable_images", "oversized_images", "skipped_images"))
        if outcomes > report["image_parts"] or sum(report[k] for k in ("readable_images", "unreadable_images", "oversized_images")) > 3:
            raise InvalidReport()
        return report
    except (ValueError, TypeError, KeyError, UnicodeError, RecursionError):
        raise InvalidReport() from None


def validate_checks(raw):
    passed = re.search(r"^INSTRUMENTATION_RESULT: stream=PASS: ([0-9]+) assertions;", raw, re.M)
    branch = re.search(r"^INSTRUMENTATION_RESULT: permission_branch=(GRANTED_NO_PROVIDER_READS|DENIED_GUARD_TESTED)\s*$", raw, re.M)
    code = re.search(r"^INSTRUMENTATION_CODE: -1\s*$", raw, re.M)
    if not passed or not branch or not code or not 40 <= int(passed[1]) <= 1000:
        raise InvalidReport()
    return {"status": "PASS", "assertions": int(passed[1]),
            "permission_branch": branch[1], "private_provider_reads": False}


def validate_share(raw, now_ms=None):
    if not raw or len(raw) > 4096:
        raise InvalidReport()
    try:
        report = json.loads(raw, object_pairs_hook=_unique)
        if not isinstance(report, dict) or type(report.get("schema")) is not int:
            raise InvalidReport()
        schema = report["schema"]
        if schema not in (1, 2) or set(report) != (SHARE_KEYS if schema == 1 else SHARE_V2_KEYS):
            raise InvalidReport()
        if report["kind"] != "SHARED_CONTENT":
            raise InvalidReport()
        if report["state"] not in SHARE_STATES or report["block_reason"] not in BLOCK_REASONS:
            raise InvalidReport()
        for key in ("text_present", "limited", "message_content_exported", "full_card_proven"):
            if type(report[key]) is not bool:
                raise InvalidReport()
        if report["message_content_exported"] or report["full_card_proven"]:
            raise InvalidReport()
        for key, maximum in SHARE_BOUNDS.items():
            if type(report[key]) is not int or not 0 <= report[key] <= maximum:
                raise InvalidReport()
        stamp = report["recorded_at_ms"]
        now = int(time.time() * 1000) if now_ms is None else now_ms
        if type(stamp) is not int or not now - 1_800_000 <= stamp <= now + 300_000:
            raise InvalidReport()
        images = report["readable_images"]
        outcomes = images + report["unreadable_images"] + report["oversized_images"]
        failures = report["blocked_uris"] + report["skipped_uris"] + outcomes - images
        if (outcomes > report["attempted_images"] or report["attempted_images"] > report["uris"]
                or outcomes + report["blocked_uris"] + report["skipped_uris"] > report["uris"]
                or (report["links"] and not report["text_present"])):
            raise InvalidReport()
        if (report["blocked_uris"] == 0) != (report["block_reason"] == "NONE"):
            raise InvalidReport()
        valid_state = {
            "IMAGE_READABLE": images > 0 and failures == 0,
            "PARTIAL_IMAGE": images > 0 and failures > 0,
            "TEXT_OR_LINK_ONLY": report["uris"] == 0 and report["text_present"],
            "EMPTY": report["uris"] == 0 and not report["text_present"],
            "BLOCKED": images == 0 and report["blocked_uris"] > 0,
            "UNREADABLE": images == 0 and report["blocked_uris"] == 0
                and report["unreadable_images"] + report["oversized_images"] > 0,
            "UNSUPPORTED": report["attempted_images"] == 0 and images == 0,
            "MALFORMED": report["attempted_images"] == 0 and images == 0,
            "ERROR": report["attempted_images"] == 0 and images == 0,
            "TIMEOUT": True,
        }
        if not valid_state[report["state"]]:
            raise InvalidReport()
        if schema == 2:
            validate_source(report)
        return report
    except (ValueError, TypeError, KeyError, UnicodeError, RecursionError):
        raise InvalidReport() from None


def verdict(report):
    if report["sms"] != "OK" or report["mms"] != "OK" or report["part_failures"]:
        return "PARTIAL_OR_BLOCKED"
    if not report["text_messages"] and not report["readable_images"]:
        return "EMPTY_SAMPLE"
    return "CONTENT_EXPOSED_NOT_FULL_CARD_PROOF"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True, help="Explicit previously approved adb device")
    parser.add_argument("mode", choices=["self-test", "report", "share-report", "notification-report"])
    args = parser.parse_args()
    sdk = os.environ.get("ANDROID_HOME")
    adb = os.path.join(sdk, "platform-tools", "adb") if sdk else shutil.which("adb")
    if not adb:
        parser.error("Set ANDROID_HOME or put adb on PATH")

    def run(*command, timeout=45):
        try:
            result = subprocess.run([adb, "-s", args.serial, *command],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=False)
        except subprocess.TimeoutExpired:
            if command[:3] == ("shell", "am", "instrument"):
                # Killing the local adb client does not reliably end remote
                # instrumentation. Clean up only our own test target.
                try:
                    subprocess.run([adb, "-s", args.serial, "shell", "am", "force-stop", "dev.textem.probe"],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5, check=False)
                except (OSError, subprocess.TimeoutExpired):
                    pass
            raise InvalidReport() from None
        except OSError:
            raise InvalidReport() from None
        if result.returncode:
            raise InvalidReport()
        return result.stdout

    try:
        if run("get-state").strip() != b"device":
            raise InvalidReport()
        if args.mode == "self-test":
            if run("shell", "getprop", "sys.boot_completed").strip() != b"1":
                print("Device is connected but not fully booted; no checks started.", file=sys.stderr)
                return 1
            raw = run("shell", "am", "instrument", "-w", "-r", "dev.textem.probe/.ProbeAutomation")
            result = validate_checks(raw.decode("utf-8"))
        elif args.mode == "report":
            # Only this known app-private metadata file, never directories or clipboard/UI.
            raw = run("exec-out", "run-as", "dev.textem.probe", "/system/bin/head",
                      "-c", "4097", "files/probe-summary.json", timeout=15)
            result = validate_report(raw)
            result = {"verdict": verdict(result), "report": result}
        elif args.mode == "notification-report":
            raw = run("exec-out", "run-as", "dev.textem.probe", "/system/bin/head",
                      "-c", "4097", "files/notification-summary.json", timeout=15)
            result = validate_notification(raw)
            result = {"verdict": result["state"], "report": result}
        else:
            raw = run("exec-out", "run-as", "dev.textem.probe", "/system/bin/head",
                      "-c", "4097", "files/share-summary.json", timeout=15)
            result = validate_share(raw)
            result = {"verdict": result["state"], "report": result}
        print(json.dumps(result, sort_keys=True))
        return 0
    except (InvalidReport, UnicodeError):
        # Never print arbitrary adb/provider/file strings, including on malformed input.
        print("No valid current result: check connection, installed probe version, and selected-sample state.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
