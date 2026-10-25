import io
import json
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest import mock
import urllib.error
import urllib.request

import boto3
from botocore.exceptions import ReadTimeoutError
from botocore.response import StreamingBody
from botocore.stub import Stubber, ANY

import cloudflare_audit
import r2_updates as r2
import update_feed as feed


def xml(build="15", version="1.3.8"):
    return f'''<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="{feed.SPARKLE}"><channel><title>TSX</title><item>
    <sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
    <enclosure url="https://example.invalid/old.dmg" length="7" sparkle:edSignature="fixture-signature"/>
    <description>Old</description></item></channel></rss>'''.encode()


class FeedTests(unittest.TestCase):
    def compose(self, **extra):
        args = dict(version="1.3.8", build="15", download_url=feed.BASE + "/qa/artifacts/batch/TSX.dmg",
                    published_at="2026-10-23T12:00:00Z", notes={"notes": "## 中文\n测试\n## English\nTest",
                    "url": "https://github.com/uuthings/tsx/releases/tag/v1.3.8"})
        args.update(extra)
        return feed.compose(xml(), xml("14", "1.3.7"), **args)

    def test_package_signature_requirements_and_history_survive_url_promotion(self):
        qa = self.compose()
        stable = self.compose(download_url=feed.BASE + "/releases/1.3.8-15/TSX.dmg")
        for data in (qa, stable):
            items = feed.read_xml(data).findall("channel/item")
            self.assertEqual(len(items), 2)
            self.assertEqual(items[0].find("enclosure").get(feed.tag("edSignature")), "fixture-signature")
            self.assertEqual(items[0].findtext(feed.tag("minimumSystemVersion")), "15.0")
            self.assertEqual(items[0].find("description").get(feed.tag("format")), "plain-text")
            self.assertEqual(items[0].findtext("description"), "## 中文\n测试\n## English\nTest")
            self.assertEqual(items[0].findtext("pubDate"), "Fri, 23 Oct 2026 12:00:00 +0000")
            self.assertEqual(items[0].findtext(feed.tag("fullReleaseNotesLink")),
                             "https://github.com/uuthings/tsx/releases/tag/v1.3.8")
        self.assertNotEqual(qa, stable)

    def test_rejects_duplicate_build_and_mismatched_candidate(self):
        with self.assertRaisesRegex(ValueError, "identity"):
            self.compose(build="16")
        with self.assertRaisesRegex(ValueError, "already exists"):
            feed.compose(xml(), xml(), version="1.3.8", build="15", download_url=feed.BASE + "/qa/a.dmg",
                         published_at="2026-10-23T12:00:00Z", notes={"notes": "text"})

    def test_rejects_build_rollback_and_non_numeric_history(self):
        for previous in (xml("16", "1.4.0"), xml("build-14", "1.3.7")):
            with self.subTest(previous=previous), self.assertRaisesRegex(ValueError, "Build"):
                feed.compose(xml(), previous, version="1.3.8", build="15", download_url=feed.BASE + "/qa/a.dmg",
                             published_at="2026-10-23T12:00:00Z", notes={"notes": "text"})

    def test_rejects_unbounded_or_entity_feed_and_unzoned_time(self):
        for data in (b"<!DOCTYPE rss><rss><channel/></rss>", b"x" * (2 * 1024 * 1024 + 1)):
            with self.assertRaises(ValueError):
                feed.read_xml(data)
        with self.assertRaisesRegex(ValueError, "timezone"):
            self.compose(published_at="2026-10-23T12:00:00")

    def test_notes_must_match_bundled_version_without_inventing_dates(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "notes.json"
            path.write_text(json.dumps([{"version": "1.3.8", "notes": "Actual bundled notes"}]))
            self.assertNotIn("publishedAt", feed.bundle_notes(path, "1.3.8"))
            with self.assertRaises(ValueError):
                feed.bundle_notes(path, "9.9.9")


class UploadTests(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "test.dmg"
        self.path.write_bytes(b"fixture")
        self.s3 = boto3.client("s3", region_name="auto", aws_access_key_id="fixture",
                               aws_secret_access_key="fixture", endpoint_url="https://example.invalid")
        self.stub = Stubber(self.s3)
        self.stub.activate()
        self.addCleanup(self.stub.deactivate)

    def object_response(self, data=b"fixture", cache="no-store", content_type=r2.DMG_TYPE):
        return {"Body": StreamingBody(io.BytesIO(data), len(data)), "ETag": '"etag"',
                "ContentType": content_type, "CacheControl": cache}

    def test_artifact_write_is_conditional_and_reads_back_actual_bytes(self):
        self.stub.add_response("put_object", {}, {"Bucket": "updates", "Key": "qa/test.dmg", "Body": ANY,
                               "ContentLength": 7, "ContentType": r2.DMG_TYPE, "CacheControl": "no-store", "IfNoneMatch": "*"})
        self.stub.add_response("get_object", self.object_response(), {"Bucket": "updates", "Key": "qa/test.dmg"})
        self.assertEqual(r2.put_immutable(self.s3, "updates", "qa/test.dmg", self.path, r2.DMG_TYPE, "no-store"), '"etag"')
        self.stub.assert_no_pending_responses()

    def test_identical_existing_artifact_can_resume_but_different_bytes_stop(self):
        for data, succeeds in [(b"fixture", True), (b"changed", False)]:
            self.stub.add_client_error("put_object", "PreconditionFailed", http_status_code=412)
            self.stub.add_response("get_object", self.object_response(data))
            if succeeds:
                r2.put_immutable(self.s3, "updates", "qa/test.dmg", self.path, r2.DMG_TYPE, "no-store")
            else:
                with self.assertRaisesRegex(RuntimeError, "differs"):
                    r2.put_immutable(self.s3, "updates", "qa/test.dmg", self.path, r2.DMG_TYPE, "no-store")
        self.stub.assert_no_pending_responses()

    def test_manifest_uses_observed_etag_and_conflict_does_not_force_retry(self):
        for expected, condition in [(None, {"IfNoneMatch": "*"}), ('"old"', {"IfMatch": '"old"'})]:
            self.stub.add_client_error("put_object", "PreconditionFailed", http_status_code=412,
                expected_params={"Bucket": "updates", "Key": "qa/appcast.xml", "Body": b"fixture",
                                 "ContentType": r2.XML_TYPE, "CacheControl": "no-store", **condition})
            with self.assertRaisesRegex(RuntimeError, "changed since"):
                r2.put_manifest(self.s3, "updates", "qa/appcast.xml", self.path, expected, "no-store")
        self.stub.assert_no_pending_responses()

    def test_uncertain_manifest_response_is_verified_without_second_write(self):
        s3 = mock.Mock()
        s3.put_object.side_effect = ReadTimeoutError(endpoint_url="https://example.invalid")
        s3.get_object.return_value = self.object_response(content_type=r2.XML_TYPE)
        r2.put_manifest(s3, "updates", "qa/appcast.xml", self.path, '"old"', "no-store")
        self.assertEqual(s3.put_object.call_count, 1)

    def test_stable_cannot_upload_without_deliberate_production_flag(self):
        directory = Path(self.directory.name)
        (directory / "plan.json").write_text(json.dumps({"bucket": "updates", "account_id": "fixture", "channel": "stable",
                                                        "feed_key": "tsx/macos/stable/appcast.xml"}))
        with self.assertRaisesRegex(RuntimeError, "explicit authorization"):
            r2.upload(SimpleNamespace(directory=directory, confirm_production=False),
                      {"bucket": "updates", "account_id": "fixture"}, self.s3)
        self.stub.assert_no_pending_responses()

    def test_cache_header_mismatch_blocks_manifest_publication(self):
        self.stub.add_response("get_object", self.object_response(cache=r2.IMMUTABLE))
        with self.assertRaisesRegex(RuntimeError, "headers"):
            r2.verify_object(self.s3, "updates", "qa/test.dmg", self.path, r2.DMG_TYPE, "no-store")

    def test_public_artifacts_are_verified_before_manifest_is_written(self):
        directory = Path(self.directory.name)
        filename = "TSX-1.3.8-macOS-universal.dmg"
        prefix = "tsx/macos/qa/artifacts/fixture-batch/"
        sums = directory / "SHA256SUMS.txt"
        sums.write_text(f"{r2.archive_evidence.sha(self.path)}  {filename}\n")
        appcast = directory / "appcast.xml"
        appcast.write_bytes(feed.compose(xml(), None, version="1.3.8", build="15",
                           download_url="https://updates.uuthings.com/" + prefix + filename,
                           published_at="2026-10-23T12:00:00Z", notes={"notes": "fixture"}))
        plan = {"channel": "qa", "bucket": "updates", "account_id": "fixture", "build": "15", "version": "1.3.8",
                "expected_etag": None, "feed_key": "tsx/macos/qa/appcast.xml", "feed_sha256": r2.archive_evidence.sha(appcast),
                "objects": [{"key": prefix + filename, "path": str(self.path), "type": r2.DMG_TYPE,
                             "sha256": r2.archive_evidence.sha(self.path)},
                            {"key": prefix + sums.name, "path": str(sums), "type": r2.TEXT_TYPE,
                             "sha256": r2.archive_evidence.sha(sums)}]}
        (directory / "plan.json").write_text(json.dumps(plan))
        settings = {"bucket": "updates", "account_id": "fixture", "public_origin": "https://updates.uuthings.com",
                    "audit_keychain_service": "fixture", "keychain_account": "fixture"}
        for failed_public_read in (False, True):
            events = []
            def public(key, *args):
                events.append("read:" + key)
                if failed_public_read:
                    raise RuntimeError("fixture public read mismatch")
                return {"key": key}
            with mock.patch.object(r2, "keychain", return_value="fixture"), \
                 mock.patch.object(r2.cloudflare_audit, "audit", return_value={}), \
                 mock.patch.object(r2, "sparkle_verify"), \
                 mock.patch.object(r2, "object_state", return_value=(None, None)), \
                 mock.patch.object(r2, "put_immutable", side_effect=lambda s, b, key, *a: events.append("put:" + key)), \
                 mock.patch.object(r2, "put_manifest", side_effect=lambda *a: events.append("manifest")), \
                 mock.patch.object(r2, "public_verify", side_effect=public), mock.patch("sys.stdout", new=io.StringIO()):
                args = SimpleNamespace(directory=directory, confirm_production=False)
                if failed_public_read:
                    with self.assertRaises(RuntimeError):
                        r2.upload(args, settings, self.s3)
                    self.assertNotIn("manifest", events)
                else:
                    r2.upload(args, settings, self.s3)
                    self.assertEqual(events[-2:], ["manifest", "read:tsx/macos/qa/appcast.xml"])
                    self.assertEqual(len(events), 6)


    def test_stable_requires_legacy_route_before_upload_and_persists_post_publish_failure(self):
        directory = Path(self.directory.name)
        filename = "TSX-1.3.8-macOS-universal.dmg"
        prefix = "tsx/macos/releases/1.3.8-15/"
        sums = directory / "SHA256SUMS.txt"
        checksum = r2.archive_evidence.sha(self.path)
        sums.write_text(f"{checksum}  {filename}\n")
        appcast = directory / "appcast.xml"
        appcast.write_bytes(feed.compose(xml(), None, version="1.3.8", build="15",
                           download_url="https://updates.uuthings.com/" + prefix + filename,
                           published_at="2026-10-23T12:00:00Z", notes={"notes": "fixture"}))
        plan = {"channel": "stable", "bucket": "updates", "account_id": "fixture", "build": "15", "version": "1.3.8",
                "expected_etag": None, "feed_key": "tsx/macos/stable/appcast.xml", "feed_sha256": r2.archive_evidence.sha(appcast),
                "objects": [{"key": prefix + filename, "path": str(self.path), "type": r2.DMG_TYPE, "sha256": checksum},
                            {"key": prefix + sums.name, "path": str(sums), "type": r2.TEXT_TYPE,
                             "sha256": r2.archive_evidence.sha(sums)}]}
        (directory / "plan.json").write_text(json.dumps(plan))
        settings = {"bucket": "updates", "account_id": "fixture", "public_origin": "https://updates.uuthings.com",
                    "audit_keychain_service": "fixture", "keychain_account": "fixture"}
        for stage in ("preflight-failure", "post-publish-failure", "success"):
            with self.subTest(stage=stage), mock.patch.object(r2, "keychain", return_value="fixture"), \
                 mock.patch.object(r2.cloudflare_audit, "audit", return_value={}), \
                 mock.patch.object(r2, "sparkle_verify"), \
                 mock.patch.object(r2, "object_state", return_value=(None, None)), \
                 mock.patch.object(r2, "put_immutable") as put, \
                 mock.patch.object(r2, "put_manifest", return_value='"new"') as manifest, \
                 mock.patch.object(r2, "public_verify", return_value={}), \
                 mock.patch.object(r2, "check_legacy_redirect", side_effect=RuntimeError("legacy unavailable") if stage == "preflight-failure" else None), \
                 mock.patch.object(r2, "verify_entrypoints", side_effect=RuntimeError("legacy changed") if stage == "post-publish-failure" else None,
                                   return_value={"stable": {}, "legacy": {}}), mock.patch("sys.stdout", new=io.StringIO()) as output:
                before = set(directory.glob("receipt-*.json"))
                args = SimpleNamespace(directory=directory, confirm_production=True)
                if stage == "success":
                    r2.upload(args, settings, self.s3)
                else:
                    with self.assertRaises(RuntimeError):
                        r2.upload(args, settings, self.s3)
                    self.assertNotIn("Uploaded and verified", output.getvalue())
                after = set(directory.glob("receipt-*.json")) - before
                if stage == "preflight-failure":
                    put.assert_not_called()
                    manifest.assert_not_called()
                    self.assertFalse(after)
                else:
                    self.assertEqual(put.call_count, 2)
                    manifest.assert_called_once()
                    self.assertEqual(len(after), 1)
                    receipt = json.loads(after.pop().read_text())
                    self.assertEqual(receipt["state"], "complete" if stage == "success" else "manifest-published-verification-failed")


class PublicReadTests(unittest.TestCase):
    def setUp(self):
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / "test.dmg"
        self.path.write_bytes(b"fixture")

    def response(self, data=b"fixture", **headers):
        response = io.BytesIO(data)
        response.status = 200
        response.headers = {"Content-Type": r2.DMG_TYPE, "Cache-Control": "no-store", "CF-Cache-Status": "DYNAMIC", **headers}
        return response

    def verify(self, response):
        with mock.patch.object(r2.urllib.request, "build_opener") as opener:
            opener.return_value.open.return_value = response
            result = r2.public_verify("tsx/macos/qa/test.dmg", self.path, r2.DMG_TYPE, "no-store")
            request = opener.return_value.open.call_args.args[0]
            self.assertEqual(request.get_header("User-agent"), "UUThings-Update-Service/1.0")
            self.assertEqual(request.get_header("Accept-encoding"), "identity")
            return result

    def test_direct_download_is_identified_and_verified(self):
        result = self.verify(self.response())
        self.assertEqual(result["sha256"], r2.archive_evidence.sha(self.path))
        self.assertEqual(result["cf_cache_status"], "DYNAMIC")

    def test_browser_challenge_is_not_accepted_as_an_artifact(self):
        with self.assertRaisesRegex(RuntimeError, "content type"):
            self.verify(self.response(b"<html>Challenge</html>", **{"Content-Type": "text/html"}))

    def test_qa_cache_hit_or_changed_policy_blocks_verification(self):
        for headers in ({"CF-Cache-Status": "HIT"}, {"Cache-Control": r2.IMMUTABLE}):
            with self.subTest(headers=headers), self.assertRaisesRegex(RuntimeError, "cache"):
                self.verify(self.response(**headers))

    def test_same_length_corruption_and_oversized_download_are_rejected(self):
        for data in (b"changed", b"fixture-extra"):
            with self.subTest(data=data), self.assertRaisesRegex(RuntimeError, "Public"):
                self.verify(self.response(data))

    def test_legacy_probe_rejects_old_xml_or_wrong_redirect_target(self):
        for status, target in [(200, None), (302, "https://example.invalid/feed.xml"), (301, feed.FEED)]:
            response = self.response()
            response.status = status
            response.headers["Location"] = target
            with self.subTest(status=status, target=target), mock.patch.object(r2.urllib.request, "build_opener") as opener:
                opener.return_value.open.return_value = response
                with self.assertRaisesRegex(RuntimeError, "redirect"):
                    r2.check_legacy_redirect()

    def test_legacy_probe_accepts_http_error_302_only_for_exact_canonical_url(self):
        with mock.patch.object(r2.urllib.request, "build_opener") as opener:
            opener.return_value.open.side_effect = urllib.error.HTTPError(
                feed.LEGACY_FEED, 302, "Found", {"Location": feed.FEED}, io.BytesIO())
            result = r2.check_legacy_redirect()
        self.assertEqual(result["location"], feed.FEED)

    def test_legacy_follow_allows_one_exact_hop_and_rejects_loops_or_other_origins(self):
        handler = r2.LegacyFeedRedirect()
        request = urllib.request.Request(feed.LEGACY_FEED)
        redirected = handler.redirect_request(request, None, 302, "Found", {}, feed.FEED)
        self.assertEqual(redirected.full_url, feed.FEED)
        for source, code, target in [(redirected, 302, feed.FEED), (request, 302, feed.FEED)]:
            with self.assertRaisesRegex(RuntimeError, "Unexpected"):
                handler.redirect_request(source, None, code, "Found", {}, target)
        for code, target in [(301, feed.FEED), (302, "https://example.invalid/")]:
            with self.assertRaisesRegex(RuntimeError, "Unexpected"):
                r2.LegacyFeedRedirect().redirect_request(request, None, code, "Found", {}, target)

    def test_legacy_follow_requires_same_signed_feed_bytes_and_uncached_response(self):
        for data, headers, succeeds in [(b"fixture", {}, True), (b"changed", {}, False),
                                        (b"fixture", {"CF-Cache-Status": "HIT"}, False)]:
            response = self.response(data, **{"Content-Type": r2.XML_TYPE, "Cache-Control": "no-cache", **headers})
            response.geturl = lambda: feed.FEED
            def opener(handler):
                handler.redirects = 1
                return SimpleNamespace(open=lambda *args, **kwargs: response)
            with self.subTest(data=data, headers=headers), mock.patch.object(r2, "sparkle_verify"), \
                 mock.patch.object(r2, "public_verify", return_value={"sha256": "fixture"}), \
                 mock.patch.object(r2, "check_legacy_redirect", return_value={}), \
                 mock.patch.object(r2.urllib.request, "build_opener", side_effect=opener):
                if succeeds:
                    self.assertEqual(r2.verify_entrypoints(self.path)["legacy"]["sha256"], r2.archive_evidence.sha(self.path))
                else:
                    with self.assertRaises(RuntimeError):
                        r2.verify_entrypoints(self.path)

    def test_read_only_entrypoint_command_does_not_load_publisher_credentials(self):
        output = self.path.parent / "entrypoints.json"
        with mock.patch.object(sys, "argv", ["r2_updates.py", "verify-entrypoints", "--feed", str(self.path), "--output", str(output)]), \
             mock.patch.object(r2, "verify_entrypoints", return_value={"legacy": {}, "stable": {}}), \
             mock.patch.object(r2, "client", side_effect=AssertionError("Credentials must not be loaded")), \
             mock.patch("sys.stdout", new=io.StringIO()):
            r2.main()
        self.assertIn("entrypoints", json.loads(output.read_text()))


class ConfigurationTests(unittest.TestCase):
    def test_only_immutable_release_prefix_is_locked(self):
        rule = {"enabled": True, "prefix": "tsx/macos/releases/", "condition": {"type": "Indefinite"}}
        cloudflare_audit.validate_lock([rule])
        for prefix in ("", "tsx/", "tsx/macos/qa/", "tsx/macos/stable/"):
            with self.assertRaises(RuntimeError):
                cloudflare_audit.validate_lock([rule, {**rule, "prefix": prefix}])
        with self.assertRaises(RuntimeError):
            cloudflare_audit.validate_lock([{**rule, "enabled": False}])

    def test_cache_bypass_must_not_be_overridden_by_later_rules(self):
        rule = {"enabled": True, "expression": cloudflare_audit.BYPASS_EXPRESSION,
                "action": "set_cache_settings", "action_parameters": {"cache": False}}
        cloudflare_audit.validate_cache([rule])
        with self.assertRaises(RuntimeError):
            cloudflare_audit.validate_cache([rule, {**rule, "action_parameters": {"cache": True}}])


if __name__ == "__main__":
    unittest.main()
