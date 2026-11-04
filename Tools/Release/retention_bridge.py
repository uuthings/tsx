"""TSX adapter for the separately installed, R2-only retention service."""
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

import update_feed

SERVICE_ROOT = Path.home() / "Library/Application Support/UUThings/UpdateService"
TARGET = "tsx/macos/stable"


def sha(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            result.update(chunk)
    return result.hexdigest()


def identify_candidate(version, build, dmg, expected_sha256):
    """Measure final bytes, independently of QA/stable object paths."""
    update_feed.release_prefix(version, str(build))
    actual = sha(dmg)
    if actual != expected_sha256:
        raise RuntimeError("Final DMG no longer matches its verified candidate")
    size = dmg.stat().st_size
    if size <= 0:
        raise RuntimeError("Final DMG must not be empty")
    identity = {"app_id": "tsx", "platform": "macos", "version": version, "build": str(build),
                "artifacts": [{"name": f"TSX-{version}-macOS-universal.dmg", "size_bytes": size,
                               "sha256": actual}], "max_artifact_bytes": size, "total_artifact_bytes": size}
    identity["candidate_sha256"] = hashlib.sha256(
        json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return identity


def measure_candidate(directory):
    metadata = json.loads((directory / "release.json").read_text())
    if metadata.get("state") != "notarized-ready-for-install-test" or metadata.get("workflow") != "xcode-organizer":
        raise RuntimeError("Candidate must have completed the Xcode and DMG notarization workflow")
    version = metadata["version"]
    dmg = directory / "artifacts" / f"TSX-{version}-macOS-universal.dmg"
    return identify_candidate(version, metadata["build"], dmg, metadata["dmgSHA256"])


def keep_for_size(size):
    """Decimal MB boundaries; None means an explicit candidate choice is required."""
    if type(size) is not int or size <= 0:
        raise ValueError("Invalid final installer size")
    return 3 if size <= 200_000_000 else 2 if size <= 500_000_000 else None


def confirm_candidate(identity, keep_versions, confirmed):
    # This flag records an operator's already-authorized choice. It cannot
    # obtain user consent or replace review of actual old-version storage.
    if keep_for_size(identity["max_artifact_bytes"]) is not None:
        raise RuntimeError("Only installers larger than 500 MB require this confirmation")
    if confirmed is not True or type(keep_versions) is not int or keep_versions not in (1, 2):
        raise RuntimeError("An explicit user choice of one or two versions is required")
    return {"schema": 1, "kind": "large-installer-retention", "candidate": identity,
            "channels": ["qa", "stable"], "keep_versions": keep_versions,
            "confirmed_large_package": True, "confirmed_at": datetime.now(timezone.utc).isoformat()}


def candidate_policy(identity, approval=None):
    keep = keep_for_size(identity["max_artifact_bytes"])
    if keep is None:
        if not isinstance(approval, dict) or approval.get("schema") != 1:
            raise RuntimeError("Installer exceeds 500 MB; record the user's candidate-specific retention choice before uploading")
        if (approval.get("kind") != "large-installer-retention" or approval.get("candidate") != identity
                or approval.get("channels") != ["qa", "stable"]
                or approval.get("confirmed_large_package") is not True
                or type(approval.get("keep_versions")) is not int or approval["keep_versions"] not in (1, 2)):
            raise RuntimeError("Retention confirmation does not match this final candidate")
        try:
            date = datetime.fromisoformat(approval["confirmed_at"])
            if date.tzinfo is None or date.utcoffset() is None:
                raise ValueError("Missing timezone")
        except (KeyError, TypeError, ValueError):
            raise RuntimeError("Retention confirmation needs a timestamp with timezone") from None
        keep = approval["keep_versions"]
    elif approval is not None:
        raise RuntimeError("This candidate does not need a large-installer confirmation; remove the stale approval")
    return {"candidate": identity, "keep_versions": keep, "approval": approval}


@contextmanager
def locked_session(args, settings):
    initial = load_session(args, settings)
    with initial.lock():
        # Another cooperating publisher may have changed policy while waiting.
        # Never rely on the snapshot read before acquiring the shared lock.
        current = load_session(args, settings)
        initial.validate_prepared(current.snapshot)
        yield current


class Session:
    def __init__(self, *, config, policy, tool, module, target):
        self.config, self.policy, self.tool = config, policy, tool
        self.module, self.target = module, target
        self.snapshot = {"enabled": True, "target": TARGET, "config": str(Path(config).resolve()),
                          "policy": str(policy), "policy_sha256": sha(policy),
                          "tool": str(tool), "tool_sha256": sha(tool),
                          "keep_versions": target["keep_versions"]}

    def lock(self):
        return self.module.service_lock(self.config)

    def validate_prepared(self, snapshot):
        if snapshot != self.snapshot:
            raise RuntimeError("Retention policy/tool changed; prepare and review again")

    def validate_candidate(self, choice):
        if self.target["keep_versions"] != choice["keep_versions"]:
            raise RuntimeError("Shared retention keep_versions does not match this candidate; update only the tsx/macos/stable target and prepare again")

    def rewrite_feed(self, data, public_origin):
        report = {**self.snapshot, "mirrored": [], "retained": [], "blocked": []}
        root = update_feed.read_xml(data)
        items = root.findall("channel/item")
        ordered = sorted(items, key=lambda item: int(item.findtext(update_feed.tag("version"))), reverse=True)
        keep = {id(item) for item in ordered[:self.target["keep_versions"]]}
        # Keep the newest entry for every distinct compatibility envelope.
        # Older systems must still have a retained, directly hosted update.
        compatibility = set()
        for item in ordered:
            enclosure = item.find("enclosure")
            key = tuple(item.findtext(update_feed.tag(name), "") for name in
                        ("minimumSystemVersion", "maximumSystemVersion", "minimumUpdateVersion"))
            key += ((enclosure.get(update_feed.tag("os"), "") if enclosure is not None else ""),)
            if key not in compatibility:
                keep.add(id(item))
                compatibility.add(key)
        changed = False
        for item in ordered:
            version = item.findtext(update_feed.tag("shortVersionString"))
            build = item.findtext(update_feed.tag("version"))
            identity = {"version": version, "build": build}
            enclosure = item.find("enclosure")
            if id(item) in keep or self._pinned(version, build):
                report["retained"].append(identity)
                continue
            if enclosure is None or not enclosure.get("url", "").startswith(public_origin + "/"):
                continue
            try:
                mirror = self.module.verify_feed_mirror(
                    version, build, enclosure.get("url"), int(enclosure.get("length", "0")),
                    self.target, public_origin)
                enclosure.set("url", mirror["url"])
                report["mirrored"].append({**identity, **mirror})
                changed = True
            except Exception as error:
                # An absent/unverified historical mirror blocks its deletion,
                # but need not block publication of a valid new release.
                report["blocked"].append({**identity, "reason": type(error).__name__})
        if not changed:
            return data, report
        result = ET.tostring(root, encoding="utf-8", xml_declaration=True)
        update_feed.read_xml(result)
        return result, report

    def _pinned(self, version, build):
        return f"{version}-{build}" in self.target.get("pinned_versions", [])

    def maintenance(self, output, *, recover_plan=None, recover_receipt=None):
        command = [sys.executable, str(self.tool), "--config", str(self.config),
                   "--policy", str(self.policy), "--target", TARGET, "plan", "--output", str(output)]
        if recover_plan or recover_receipt:
            if not recover_plan or not recover_receipt:
                raise RuntimeError("Retention recovery requires plan with both the original plan and partial receipt")
            command += ["--recover-plan", str(recover_plan), "--recover-receipt", str(recover_receipt)]
        result = subprocess.run(command, capture_output=True)
        if result.returncode:
            raise RuntimeError("R2 retention check did not complete; inspect the maintenance evidence")
        return {"state": "complete", "action": "plan", "report": str(output)}


def load_session(args, settings):
    policy = Path(getattr(args, "retention_policy", None) or SERVICE_ROOT / "retention-policy.json").expanduser().resolve()
    tool = Path(getattr(args, "retention_tool", None) or SERVICE_ROOT / "tools/r2_retention.py").expanduser().resolve()
    if not policy.is_file() or not tool.is_file():
        raise RuntimeError("Shared retention policy/tool is missing or incomplete; install the service before preparing or uploading QA/stable")
    config = getattr(args, "config", None)
    if config is None:
        raise RuntimeError("Retention requires the update-service configuration path")
    spec = importlib.util.spec_from_file_location("uuthings_r2_retention", tool)
    if spec is None or spec.loader is None:
        raise RuntimeError("Cannot load the shared retention tool")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    required = ("load_policy", "resolve_target", "verify_feed_mirror", "service_lock")
    if not all(callable(getattr(module, name, None)) for name in required):
        raise RuntimeError("Shared retention tool has an incompatible interface")
    target = module.resolve_target(module.load_policy(policy, settings), TARGET)
    expected = {"app_id": "tsx", "platform": "macos", "channel": "stable",
                "release_prefix": "tsx/macos/releases/", "manifest_key": "tsx/macos/stable/appcast.xml",
                "github_repository": "uuthings/tsx", "github_tag_template": "v{version}",
                "artifact_template": "TSX-{version}-macOS-universal.dmg"}
    if any(target.get(key) != value for key, value in expected.items()):
        raise RuntimeError("Shared retention target does not match the TSX publication paths and GitHub mirror")
    if type(target.get("keep_versions")) is not int or not 1 <= target["keep_versions"] <= 3:
        raise RuntimeError("Retention must keep between one and three formal releases")
    return Session(config=Path(config).resolve(), policy=policy, tool=tool, module=module, target=target)
