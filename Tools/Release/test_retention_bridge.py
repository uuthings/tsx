from contextlib import contextmanager, nullcontext
from copy import deepcopy
import io
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

import retention_bridge as bridge
import r2_updates as r2
import update_feed as feed


def appcast(count=4):
    root = ET.Element("rss")
    channel = ET.SubElement(root, "channel")
    for build in range(count, 0, -1):
        item = ET.SubElement(channel, "item")
        for name, value in (("version", str(build)), ("shortVersionString", f"1.0.{build}"),
                            ("minimumSystemVersion", "15.0")):
            ET.SubElement(item, feed.tag(name)).text = value
        ET.SubElement(item, "pubDate").text = "Fri, 23 Oct 2026 12:00:00 +0000"
        ET.SubElement(item, "description").text = "Original bilingual release description"
        ET.SubElement(item, "enclosure", {"url": f"{feed.BASE}/releases/1.0.{build}-{build}/TSX-1.0.{build}-macOS-universal.dmg",
                       "length": "7", feed.tag("edSignature"): f"signature-{build}"})
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


class RetentionBridgeTests(unittest.TestCase):
    def setUp(self):
        temporary = TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        patch = mock.patch.object(bridge, "SERVICE_ROOT", self.root)
        patch.start()
        self.addCleanup(patch.stop)
        self.args = SimpleNamespace(config=self.root / "config.json")

    def session(self, keep=3):
        policy, tool = self.root / "retention-policy.json", self.root / "tool.py"
        policy.write_text("{}")
        tool.write_text("# shared fixture")
        module = SimpleNamespace(service_lock=lambda path: nullcontext(),
                 verify_feed_mirror=mock.Mock(return_value={"url": "https://github.com/uuthings/tsx/releases/download/v1.0.1/TSX.dmg",
                                                           "sha256": "a" * 64, "size": 7, "tag": "v1.0.1", "asset_id": 1}))
        return bridge.Session(config=self.args.config, policy=policy, tool=tool,
                              module=module, target={"keep_versions": keep})

    def upload_plan(self, session, channel="stable"):
        path = self.root / "TSX-1.0.1-macOS-universal.dmg"
        path.write_bytes(b"fixture")
        checksum = bridge.sha(path)
        identity = bridge.identify_candidate("1.0.1", "1", path, checksum)
        plan = {"channel": channel, "feed_key": f"tsx/macos/{channel}/appcast.xml", "bucket": "updates",
                "account_id": "fixture", "retention": session.snapshot, "version": "1.0.1", "build": "1",
                "retention_choice": bridge.candidate_policy(identity),
                "objects": [{"path": str(path), "sha256": checksum, "type": r2.DMG_TYPE}, {}]}
        (self.root / "plan.json").write_text(json.dumps(plan))
        return plan

    def test_absent_and_incomplete_service_stop(self):
        with self.assertRaisesRegex(RuntimeError, "missing or incomplete"):
            bridge.load_session(self.args, {})
        self.args.retention_policy = self.root / "missing.json"
        with self.assertRaisesRegex(RuntimeError, "incomplete"):
            bridge.load_session(self.args, {})
        del self.args.retention_policy
        (self.root / "retention-policy.json").write_text("{}")
        with self.assertRaisesRegex(RuntimeError, "incomplete"):
            bridge.load_session(self.args, {})

    def test_changed_or_newly_installed_policy_requires_new_preparation(self):
        session = self.session()
        session.validate_prepared(dict(session.snapshot))
        for prior in (None, {"enabled": False}, {**session.snapshot, "policy_sha256": "changed"}):
            with self.subTest(prior=prior), self.assertRaisesRegex(RuntimeError, "prepare"):
                session.validate_prepared(prior)

    def test_configuration_path_binds_the_shared_lock_domain(self):
        session = self.session()
        snapshot = dict(session.snapshot)
        snapshot["config"] = str(self.root / "other" / "config.json")
        with self.assertRaisesRegex(RuntimeError, "prepare"):
            session.validate_prepared(snapshot)
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        same = bridge.Session(config=alias / "config.json", policy=session.policy, tool=session.tool,
                              module=session.module, target=session.target)
        session.validate_prepared(same.snapshot)

    def test_only_verified_old_enclosure_url_changes_and_all_history_survives(self):
        session = self.session()
        data = appcast()
        rewritten, report = session.rewrite_feed(data, "https://updates.uuthings.com")
        before, after = feed.read_xml(data), feed.read_xml(rewritten)
        original_items, changed_items = before.findall("channel/item"), after.findall("channel/item")
        self.assertEqual(len(changed_items), 4)
        for old, new in zip(original_items, changed_items):
            if old.findtext(feed.tag("version")) == "1":
                self.assertTrue(new.find("enclosure").get("url").startswith("https://github.com/"))
                new.find("enclosure").set("url", old.find("enclosure").get("url"))
            self.assertEqual(ET.tostring(new), ET.tostring(old))
        session.module.verify_feed_mirror.assert_called_once()
        self.assertEqual(report["mirrored"][0]["build"], "1")

    def test_failed_mirror_preserves_r2_reference_and_records_blocker(self):
        session = self.session()
        session.module.verify_feed_mirror.side_effect = RuntimeError("checksum mismatch")
        data = appcast()
        rewritten, report = session.rewrite_feed(data, "https://updates.uuthings.com")
        self.assertEqual(rewritten, data)
        self.assertEqual(report["blocked"], [{"version": "1.0.1", "build": "1", "reason": "RuntimeError"}])

    def test_latest_compatibility_bridge_and_policy_pins_stay_on_r2(self):
        session = self.session(keep=1)
        session.target["pinned_versions"] = ["1.0.1-1"]
        root = feed.read_xml(appcast())
        items = root.findall("channel/item")
        items[0].find(feed.tag("minimumSystemVersion")).text = "16.0"
        rewritten, report = session.rewrite_feed(ET.tostring(root), "https://updates.uuthings.com")
        self.assertEqual([row["build"] for row in report["retained"]], ["4", "3", "1"])
        self.assertEqual([row["build"] for row in report["mirrored"]], ["2"])

    def test_existing_github_history_is_not_fetched_or_changed(self):
        session = self.session()
        root = feed.read_xml(appcast())
        root.findall("channel/item")[-1].find("enclosure").set("url", "https://github.com/uuthings/tsx/releases/download/v1/old.dmg")
        data = ET.tostring(root)
        self.assertEqual(session.rewrite_feed(data, "https://updates.uuthings.com")[0], data)
        session.module.verify_feed_mirror.assert_not_called()

    def test_maintenance_forwards_only_read_only_plan(self):
        session = self.session()
        with mock.patch.object(bridge.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as run:
            session.maintenance(self.root / "report.json")
            command = run.call_args.args[0]
            self.assertIn("plan", command)
            self.assertNotIn("apply", command)
            self.assertNotIn("--confirm-r2-delete", command)
            self.assertNotIn("--confirm-exclusive-maintenance", command)
            run.reset_mock()
            with self.assertRaises(TypeError):
                session.maintenance(self.root / "report.json", action="apply")
            run.assert_not_called()

    def test_stable_preparation_rewrites_before_signing_and_binds_shared_policy(self):
        session = self.session()
        candidate = self.root / "candidate"
        artifacts = candidate / "artifacts"
        artifacts.mkdir(parents=True)
        dmg = artifacts / "TSX-1.0.1-macOS-universal.dmg"
        dmg.write_bytes(b"fixture")
        (artifacts / "appcast.xml").write_bytes(appcast(1))
        (candidate / "release.json").write_text(json.dumps({
            "state": "notarized-ready-for-install-test", "workflow": "xcode-organizer",
            "version": "1.0.1", "build": 1, "commit": "fixture", "dmgSHA256": r2.archive_evidence.sha(dmg)}))
        output = self.root / "prepared"
        args = SimpleNamespace(candidate=candidate, output=output, channel="stable",
                               published_at="2026-10-23T12:00:00Z")
        events = []
        original = session.rewrite_feed
        def rewrite(*arguments):
            events.append("rewrite")
            return original(*arguments)
        def sign(command, **kwargs):
            if str(output / "appcast.xml") in command:
                events.append("sign-feed")
                self.assertEqual(events, ["rewrite", "sign-feed"])
                self.assertTrue((output / "retention-preparation.json").is_file())
        session.rewrite_feed = rewrite
        with mock.patch.object(bridge, "load_session", return_value=session), \
             mock.patch.object(r2.archive_evidence, "persistent_directory", return_value=output), \
             mock.patch.object(r2, "sparkle_verify"), \
             mock.patch.object(r2, "object_state", return_value=(None, None)), \
             mock.patch.object(feed, "bundle_notes", return_value={"notes": "fixture"}), \
             mock.patch.object(r2.subprocess, "run", side_effect=sign), mock.patch("sys.stdout", new=io.StringIO()):
            r2.prepare(args, {"bucket": "updates", "account_id": "fixture", "public_origin": "https://updates.uuthings.com"}, None)
        self.assertEqual(events, ["rewrite", "sign-feed"])
        self.assertEqual(json.loads((output / "plan.json").read_text())["retention"], session.snapshot)

    def test_partial_recovery_only_builds_new_plan_from_both_original_files(self):
        session = self.session()
        original, partial = self.root / "original.json", self.root / "partial.json"
        with mock.patch.object(bridge.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as run:
            for arguments in ({"recover_plan": original}, {"recover_receipt": partial}):
                with self.subTest(arguments=arguments), self.assertRaisesRegex(RuntimeError, "both the original plan"):
                    session.maintenance(self.root / "new-plan.json", **arguments)
            run.assert_not_called()
            session.maintenance(self.root / "new-plan.json", recover_plan=original, recover_receipt=partial)
            command = run.call_args.args[0]
            self.assertIn("plan", command)
            self.assertEqual(command[command.index("--recover-plan") + 1], str(original))
            self.assertEqual(command[command.index("--recover-receipt") + 1], str(partial))
            self.assertNotIn("--confirm-r2-delete", command)

    def test_changed_policy_blocks_upload_before_any_cloud_mutation(self):
        session = self.session()
        (self.root / "plan.json").write_text(json.dumps({"channel": "stable", "feed_key": "tsx/macos/stable/appcast.xml",
                "bucket": "updates", "account_id": "fixture", "retention": {**session.snapshot, "policy_sha256": "changed"}}))
        with mock.patch.object(bridge, "load_session", return_value=session), mock.patch.object(r2, "_upload") as upload, \
             self.assertRaisesRegex(RuntimeError, "prepare"):
            r2.upload(SimpleNamespace(directory=self.root, confirm_production=True), {"bucket": "updates", "account_id": "fixture"}, None)
        upload.assert_not_called()

    def test_stable_post_publish_planner_runs_after_lock_and_failure_preserves_publication(self):
        session = self.session()
        self.upload_plan(session)
        args = SimpleNamespace(directory=self.root, confirm_production=True)
        events = []
        @contextmanager
        def lock():
            events.append("locked")
            yield
            events.append("unlocked")
        session.lock = lock
        receipt_path = self.root / "receipt.json"
        def published(*args):
            self.assertEqual(events[-1], "locked")
            return {"state": "complete", "verified": []}, receipt_path
        def maintenance(*args):
            self.assertEqual(events[-1], "unlocked")
            raise RuntimeError("planner unavailable")
        session.maintenance = maintenance
        with mock.patch.object(bridge, "load_session", return_value=session), \
             mock.patch.object(r2, "_upload", side_effect=published), \
             self.assertRaisesRegex(RuntimeError, "publication is complete"):
            r2.upload(args, {"bucket": "updates", "account_id": "fixture"}, None)
        receipt = json.loads(receipt_path.read_text())
        self.assertEqual(receipt["state"], "complete")
        self.assertEqual(receipt["retention_plan"]["state"], "failed")

    def test_qa_checks_shared_policy_but_does_not_run_maintenance(self):
        session = self.session()
        self.upload_plan(session, "qa")
        session.maintenance = mock.Mock()
        args = SimpleNamespace(directory=self.root, confirm_production=False)
        with mock.patch.object(bridge, "load_session", return_value=session) as load, \
             mock.patch.object(r2, "_upload", return_value=({"verified": []}, self.root / "receipt.json")), \
             mock.patch("sys.stdout", new=io.StringIO()):
            r2.upload(args, {"bucket": "updates", "account_id": "fixture"}, None)
        self.assertEqual(load.call_count, 2)
        session.maintenance.assert_not_called()

    def test_decimal_size_boundaries(self):
        for size, keep in ((1, 3), (200_000_000, 3), (200_000_001, 2),
                           (500_000_000, 2), (500_000_001, None)):
            with self.subTest(size=size):
                self.assertEqual(bridge.keep_for_size(size), keep)
        for size in (0, -1, True, 1.5):
            with self.subTest(size=size), self.assertRaises(ValueError):
                bridge.keep_for_size(size)

    def large_identity(self):
        artifact = SimpleNamespace(stat=lambda: SimpleNamespace(st_size=500_000_001))
        with mock.patch.object(bridge, "sha", return_value="a" * 64):
            return bridge.identify_candidate("1.0.1", "1", artifact, "a" * 64)

    def test_large_candidate_needs_an_explicit_choice(self):
        identity = self.large_identity()
        with self.assertRaisesRegex(RuntimeError, "candidate-specific"):
            bridge.candidate_policy(identity)
        for keep, confirmed in ((1, False), (2, None), (3, True), (True, True)):
            with self.subTest(keep=keep, confirmed=confirmed), self.assertRaisesRegex(RuntimeError, "explicit user choice"):
                bridge.confirm_candidate(identity, keep, confirmed)
        for keep in (1, 2):
            approval = bridge.confirm_candidate(identity, keep, True)
            self.assertEqual(bridge.candidate_policy(identity, approval)["keep_versions"], keep)
            self.assertEqual(approval["channels"], ["qa", "stable"])

    def test_confirmation_cannot_follow_changed_bytes_version_or_build(self):
        identity = self.large_identity()
        approval = bridge.confirm_candidate(identity, 1, True)
        changes = [{"version": "1.0.2"}, {"build": "2"}, {"candidate_sha256": "b" * 64},
                   {"artifacts": [{**identity["artifacts"][0], "sha256": "b" * 64}]},
                   {"max_artifact_bytes": 500_000_002}]
        for change in changes:
            with self.subTest(change=change), self.assertRaisesRegex(RuntimeError, "does not match"):
                bridge.candidate_policy({**identity, **change}, approval)
        for change in ({"channels": ["qa"]}, {"confirmed_large_package": False},
                       {"keep_versions": True}, {"confirmed_at": "2026-10-23T12:00:00"}):
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                bridge.candidate_policy(identity, {**approval, **change})

    def test_qa_and_stable_reuse_only_the_same_approved_candidate(self):
        session = self.session(keep=2)
        identity = self.large_identity()
        approval = bridge.confirm_candidate(identity, 2, True)
        session.maintenance = mock.Mock(return_value={"state": "complete", "action": "plan"})
        for channel in ("qa", "stable"):
            plan = self.upload_plan(session, channel)
            plan["retention_choice"] = bridge.candidate_policy(identity, approval)
            (self.root / "plan.json").write_text(json.dumps(plan))
            with mock.patch.object(bridge, "load_session", return_value=session), \
                 mock.patch.object(bridge, "identify_candidate", return_value=identity), \
                 mock.patch.object(r2, "_upload", return_value=({"state": "complete", "verified": []}, self.root / f"{channel}-receipt.json")) as upload, \
                 mock.patch("sys.stdout", new=io.StringIO()):
                r2.upload(SimpleNamespace(directory=self.root, confirm_production=channel == "stable"),
                          {"bucket": "updates", "account_id": "fixture"}, None)
            upload.assert_called_once()
        session.maintenance.assert_called_once()

    def test_both_channels_reject_large_unconfirmed_and_changed_packages_before_credentials(self):
        for channel in ("qa", "stable"):
            for failure in ("unconfirmed", "changed-bytes", "changed-policy"):
                with self.subTest(channel=channel, failure=failure):
                    session = self.session()
                    plan = self.upload_plan(session, channel)
                    client = mock.Mock(side_effect=AssertionError("Credentials must not be read"))
                    if failure == "changed-bytes":
                        Path(plan["objects"][0]["path"]).write_bytes(b"changed")
                    elif failure == "changed-policy":
                        session.target["keep_versions"] = 2
                    real_identify = bridge.identify_candidate
                    identity = self.large_identity() if failure == "unconfirmed" else None
                    with mock.patch.object(bridge, "load_session", return_value=session), \
                         mock.patch.object(bridge, "identify_candidate", side_effect=(lambda *args: identity) if identity else real_identify), \
                         mock.patch.object(r2, "_upload") as upload, self.assertRaises(RuntimeError):
                        r2.upload(SimpleNamespace(directory=self.root, confirm_production=True),
                                  {"bucket": "updates", "account_id": "fixture"}, client)
                    client.assert_not_called()
                    upload.assert_not_called()

    def test_both_channels_require_service_before_prepare_or_upload(self):
        for channel in ("qa", "stable"):
            with self.subTest(channel=channel):
                (self.root / "plan.json").write_text(json.dumps({"channel": channel,
                    "feed_key": f"tsx/macos/{channel}/appcast.xml", "bucket": "updates", "account_id": "fixture"}))
                args = SimpleNamespace(directory=self.root, candidate=self.root / "candidate", channel=channel,
                                       config=self.args.config, confirm_production=True)
                client = mock.Mock(side_effect=AssertionError("Credentials must not be read"))
                for action in (r2.prepare, r2.upload):
                    with self.assertRaisesRegex(RuntimeError, "missing or incomplete"):
                        action(args, {"bucket": "updates", "account_id": "fixture"}, client)
                client.assert_not_called()

    def test_both_channels_reject_unapproved_or_mismatched_retention_before_prepare(self):
        for channel in ("qa", "stable"):
            for failure in ("unconfirmed", "wrong-keep"):
                with self.subTest(channel=channel, failure=failure):
                    session = self.session(keep=2)
                    identity = self.large_identity()
                    if failure == "wrong-keep":
                        identity = {**identity, "max_artifact_bytes": 7, "total_artifact_bytes": 7}
                    args = SimpleNamespace(candidate=self.root / "candidate", channel=channel)
                    client = mock.Mock(side_effect=AssertionError("Credentials must not be read"))
                    with mock.patch.object(bridge, "load_session", return_value=session), \
                         mock.patch.object(bridge, "measure_candidate", return_value=identity), \
                         mock.patch.object(r2, "_prepare") as prepare, self.assertRaises(RuntimeError):
                        r2.prepare(args, {}, client)
                    client.assert_not_called()
                    prepare.assert_not_called()

    def install_service(self):
        target = {"app_id": "tsx", "platform": "macos", "channel": "stable", "keep_versions": 2,
                  "release_prefix": "tsx/macos/releases/", "manifest_key": "tsx/macos/stable/appcast.xml",
                  "github_repository": "uuthings/tsx", "github_tag_template": "v{version}",
                  "artifact_template": "TSX-{version}-macOS-universal.dmg"}
        policy = self.root / "retention-policy.json"
        policy.write_text(json.dumps({"defaults": {"keep_versions": 3}, "targets": {bridge.TARGET: target,
                                     "other/macos/stable": {"keep_versions": 3}}}))
        tool = self.root / "tools/r2_retention.py"
        tool.parent.mkdir(exist_ok=True)
        tool.write_text("from contextlib import nullcontext\nimport json\n"
                        "def load_policy(path, settings): return json.loads(path.read_text())\n"
                        "def resolve_target(policy, target): return {**policy['defaults'], **policy['targets'][target]}\n"
                        "def verify_feed_mirror(*args): raise AssertionError('No cloud reads in fixture')\n"
                        "def service_lock(path): return nullcontext()\n")
        return policy, tool

    def test_shared_target_override_is_read_without_mutating_any_policy(self):
        policy, tool = self.install_service()
        before = policy.read_bytes(), tool.read_bytes()
        session = bridge.load_session(self.args, {})
        self.assertEqual(session.target["keep_versions"], 2)
        session.validate_candidate({"keep_versions": 2})
        self.assertEqual((policy.read_bytes(), tool.read_bytes()), before)
        with self.assertRaisesRegex(RuntimeError, "update only the tsx"):
            session.validate_candidate({"keep_versions": 3})
        value = json.loads(policy.read_text())
        value["targets"]["other/macos/stable"]["keep_versions"] = 1
        policy.write_text(json.dumps(value))
        with self.assertRaisesRegex(RuntimeError, "prepare"):
            bridge.load_session(self.args, {}).validate_prepared(session.snapshot)

    def test_shared_target_must_match_publisher_paths_and_mirror(self):
        policy, _ = self.install_service()
        original = json.loads(policy.read_text())
        for key, value in (("release_prefix", "tsx/macos/stable/releases/"),
                           ("manifest_key", "tsx/macos/qa/appcast.xml"),
                           ("artifact_template", "Other-{version}.dmg"),
                           ("github_repository", "another/project")):
            changed = deepcopy(original)
            changed["targets"][bridge.TARGET][key] = value
            policy.write_text(json.dumps(changed))
            with self.subTest(key=key), self.assertRaisesRegex(RuntimeError, "publication paths"):
                bridge.load_session(self.args, {})

    def test_policy_is_rechecked_after_waiting_for_shared_lock(self):
        policy, _ = self.install_service()
        initial = bridge.load_session(self.args, {})
        @contextmanager
        def lock():
            policy.write_text(policy.read_text() + "\n")
            yield
        initial.lock = lock
        original = bridge.load_session
        calls = 0
        def load(*args):
            nonlocal calls
            calls += 1
            return initial if calls == 1 else original(*args)
        with mock.patch.object(bridge, "load_session", side_effect=load), \
             self.assertRaisesRegex(RuntimeError, "prepare"):
            with bridge.locked_session(self.args, {}):
                self.fail("Changed policy must not enter publication")

    def test_review_and_confirmation_commands_are_local_and_confirmation_needs_flag(self):
        identity = self.large_identity()
        with mock.patch.object(bridge, "measure_candidate", return_value=identity), \
             mock.patch.object(r2, "config", side_effect=AssertionError("No private configuration")), \
             mock.patch.object(r2, "client", side_effect=AssertionError("No credentials")), \
             mock.patch.object(bridge, "load_session", side_effect=AssertionError("No shared tool")), \
             mock.patch.object(r2.sys, "argv", ["r2_updates.py", "review-retention", "--candidate", str(self.root)]), \
             mock.patch("sys.stdout", new=io.StringIO()) as output:
            r2.main()
            report = json.loads(output.getvalue())
            self.assertTrue(report["user_choice_required"])
            self.assertTrue(report["old_versions_and_storage"].startswith("unknown"))
        for command in (["confirm-retention", "--candidate", str(self.root), "--keep-versions", "1", "--output", str(self.root / "approval.json")],
                        ["retention", "apply", "--output", str(self.root / "plan.json")]):
            with mock.patch.object(r2.sys, "argv", ["r2_updates.py", *command]), \
                 mock.patch("sys.stderr", new=io.StringIO()), self.assertRaises(SystemExit) as stopped:
                r2.main()
            self.assertEqual(stopped.exception.code, 2)

    def test_confirmation_and_plan_reject_repository_or_cache_outputs(self):
        identity = self.large_identity()
        session = self.session()
        session.maintenance = mock.Mock()
        repository = self.root / "repository"
        (repository / ".git").mkdir(parents=True)
        (repository / ".git/HEAD").write_text("ref: refs/heads/main\n")
        for output in (repository / "record.json", self.root / ".cache" / "record.json"):
            for command in (["confirm-retention", "--candidate", str(self.root), "--keep-versions", "1",
                             "--confirm-large-package", "--output", str(output)],
                            ["--config", str(self.args.config), "retention", "plan", "--output", str(output)]):
                with self.subTest(command=command[0], output=output), \
                     mock.patch.object(bridge, "measure_candidate", return_value=identity), \
                     mock.patch.object(bridge, "load_session", return_value=session), \
                     mock.patch.object(r2, "config", return_value={}), \
                     mock.patch.object(r2.archive_evidence, "TEMPORARY_ROOTS", ()), \
                     mock.patch.object(r2.sys, "argv", ["r2_updates.py", *command]), \
                     self.assertRaisesRegex(RuntimeError, "Git working tree|build or cache"):
                    r2.main()
                self.assertFalse(output.exists())
        session.maintenance.assert_not_called()


if __name__ == "__main__":
    unittest.main()
