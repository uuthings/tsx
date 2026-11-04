#!/usr/bin/env python3
"""Prepare, review and upload TSX updates. No build, notarization or website deployment."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.request
import uuid

import archive_evidence
import update_feed
import cloudflare_audit
import retention_bridge
from release import ACCOUNT, TOOLS

XML_TYPE = "application/xml; charset=utf-8"
DMG_TYPE = "application/x-apple-diskimage"
TEXT_TYPE = "text/plain; charset=utf-8"
IMMUTABLE = "public, max-age=31536000, immutable"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def keychain(service, account):
    result = subprocess.run(["security", "find-generic-password", "-s", service, "-a", account, "-w"],
                            capture_output=True)
    if result.returncode:
        raise RuntimeError("Required Keychain credential is unavailable")
    return result.stdout.decode().strip()


def config(path):
    value = json.loads(path.read_text())
    if not re.fullmatch(r"[a-f0-9]{32}", value["account_id"]):
        raise ValueError("Invalid Cloudflare account ID")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{1,61}[a-z0-9]", value["bucket"]):
        raise ValueError("Invalid R2 bucket")
    if value.get("public_origin") != "https://updates.uuthings.com":
        raise ValueError("Unexpected update origin")
    return value


def client(settings):
    import boto3
    from botocore.config import Config
    credentials = json.loads(keychain(settings["publisher_keychain_service"], settings["keychain_account"]))
    # Never inherit a broader AWS profile, Wrangler login or alternate endpoint.
    return boto3.client("s3", endpoint_url=f"https://{settings['account_id']}.r2.cloudflarestorage.com",
                        region_name="auto", aws_access_key_id=credentials["access_key_id"],
                        aws_secret_access_key=credentials["secret_access_key"],
                        aws_session_token=credentials.get("session_token"),
                        config=Config(retries={"total_max_attempts": 1}, connect_timeout=20, read_timeout=120,
                                      request_checksum_calculation="when_required",
                                      response_checksum_validation="when_required"))


def object_state(s3, bucket, key, limit=2 * 1024 * 1024):
    from botocore.exceptions import ClientError
    try:
        response = s3.get_object(Bucket=bucket, Key=key)
    except ClientError as error:
        if error.response.get("Error", {}).get("Code") in ("NoSuchKey", "404"):
            return None, None
        raise
    with response["Body"] as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise RuntimeError("Remote object exceeds the expected size")
    return response["ETag"], data


def verify_object(s3, bucket, key, path, content_type, cache_control):
    response = s3.get_object(Bucket=bucket, Key=key)
    if response.get("ContentType") != content_type or response.get("CacheControl") != cache_control:
        response["Body"].close()
        raise RuntimeError("Uploaded object headers differ from the prepared plan")
    checksum = hashlib.sha256()
    total = 0
    with response["Body"] as stream:
        while chunk := stream.read(1024 * 1024):
            total += len(chunk)
            if total > path.stat().st_size:
                raise RuntimeError("Remote object is larger than the local candidate")
            checksum.update(chunk)
    if checksum.hexdigest() != archive_evidence.sha(path):
        raise RuntimeError("Uploaded object differs from the local candidate")
    return response["ETag"]


def put_immutable(s3, bucket, key, path, content_type, cache_control):
    from botocore.exceptions import BotoCoreError, ClientError
    try:
        with path.open("rb") as stream:
            s3.put_object(Bucket=bucket, Key=key, Body=stream, ContentLength=path.stat().st_size,
                          ContentType=content_type, CacheControl=cache_control, IfNoneMatch="*")
    except (BotoCoreError, ClientError):
        # A timeout may have committed; an existing identical object is also an
        # idempotent retry. In both cases read and compare actual bytes/headers.
        return verify_object(s3, bucket, key, path, content_type, cache_control)
    return verify_object(s3, bucket, key, path, content_type, cache_control)


def put_manifest(s3, bucket, key, path, expected_etag, cache_control):
    from botocore.exceptions import BotoCoreError, ClientError
    condition = {"IfMatch": expected_etag} if expected_etag else {"IfNoneMatch": "*"}
    try:
        s3.put_object(Bucket=bucket, Key=key, Body=path.read_bytes(), ContentType=XML_TYPE,
                      CacheControl=cache_control, **condition)
    except ClientError as error:
        if error.response.get("ResponseMetadata", {}).get("HTTPStatusCode") in (409, 412):
            raise RuntimeError("Manifest changed since preparation; prepare and review again") from None
        raise
    except BotoCoreError:
        # Do not blindly retry a manifest mutation after an uncertain response.
        return verify_object(s3, bucket, key, path, XML_TYPE, cache_control)
    return verify_object(s3, bucket, key, path, XML_TYPE, cache_control)


def sparkle_verify(path):
    subprocess.run([str(TOOLS / "sign_update"), "--account", ACCOUNT, "--verify", str(path)],
                   check=True, capture_output=True)


def prepare(args, settings, s3):
    with retention_bridge.locked_session(args, settings) as retention:
        identity = retention_bridge.measure_candidate(args.candidate)
        approval_path = getattr(args, "retention_approval", None)
        approval = json.loads(approval_path.read_text()) if approval_path else None
        choice = retention_bridge.candidate_policy(identity, approval)
        retention.validate_candidate(choice)
        _prepare(args, settings, s3() if callable(s3) else s3, retention, choice)


def _prepare(args, settings, s3, retention, choice):
    output = archive_evidence.persistent_directory(args.output)
    if output.exists():
        raise RuntimeError("Use a new preparation directory; existing evidence is not overwritten")
    metadata = json.loads((args.candidate / "release.json").read_text())
    if metadata.get("state") != "notarized-ready-for-install-test" or metadata.get("workflow") != "xcode-organizer":
        raise RuntimeError("Candidate must have completed the Xcode and DMG notarization workflow")
    version, build = metadata["version"], str(metadata["build"])
    formal_prefix = update_feed.release_prefix(version, build)
    artifacts = args.candidate / "artifacts"
    filename = f"TSX-{version}-macOS-universal.dmg"
    dmg = artifacts / filename
    if archive_evidence.sha(dmg) != metadata["dmgSHA256"]:
        raise RuntimeError("Final DMG no longer matches its verified candidate")
    sparkle_verify(artifacts / "appcast.xml")
    package = update_feed.read_xml((artifacts / "appcast.xml").read_bytes()).find("channel/item/enclosure")
    if package is None or package.get("length") != str(dmg.stat().st_size):
        raise RuntimeError("Candidate feed length differs from the final package")
    subprocess.run([str(TOOLS / "sign_update"), "--account", ACCOUNT, "--verify", str(dmg),
                    package.get(update_feed.tag("edSignature"), "")], check=True, capture_output=True)
    feed_key = f"tsx/macos/{args.channel}/appcast.xml"
    etag, previous = object_state(s3, settings["bucket"], feed_key)
    output.mkdir(parents=True)
    if previous:
        (output / "previous-appcast.xml").write_bytes(previous)
        sparkle_verify(output / "previous-appcast.xml")
    batch = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8]
    prefix = formal_prefix if args.channel == "stable" else f"tsx/macos/qa/artifacts/{batch}/"
    notes = update_feed.bundle_notes(args.candidate / "published-release-notes.json", version)
    data = update_feed.compose((artifacts / "appcast.xml").read_bytes(), previous,
                              version=version, build=build, download_url=settings["public_origin"] + "/" + prefix + filename,
                              published_at=args.published_at, notes=notes)
    if args.channel == "stable":
        data, retention_report = retention.rewrite_feed(data, settings["public_origin"])
        (output / "retention-preparation.json").write_text(json.dumps(retention_report, indent=2) + "\n")
    feed = output / "appcast.xml"
    feed.write_bytes(data)
    subprocess.run([str(TOOLS / "sign_update"), "--account", ACCOUNT, str(feed)], check=True, capture_output=True)
    sparkle_verify(feed)
    sums = output / "SHA256SUMS.txt"
    sums.write_text(f"{metadata['dmgSHA256']}  {filename}\n")
    plan = {"schema": 1, "channel": args.channel, "bucket": settings["bucket"],
            "account_id": settings["account_id"], "version": version, "build": build,
            "source_commit": metadata["commit"], "feed_key": feed_key, "expected_etag": etag,
            "objects": [
                {"key": prefix + filename, "path": str(dmg.resolve()), "sha256": metadata["dmgSHA256"], "type": DMG_TYPE},
                {"key": prefix + sums.name, "path": str(sums), "sha256": archive_evidence.sha(sums), "type": TEXT_TYPE}],
            "feed_sha256": archive_evidence.sha(feed), "prepared_at": datetime.now(timezone.utc).isoformat()}
    plan["retention"] = retention.snapshot
    plan["retention_choice"] = choice
    (output / "plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    print(f"Prepared {args.channel} plan for TSX {version} ({build}). No objects uploaded.\n{output / 'plan.json'}")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def check_legacy_redirect():
    request = urllib.request.Request(update_feed.LEGACY_FEED,
                                    headers={"User-Agent": "UUThings-Update-Service/1.0"})
    try:
        response = urllib.request.build_opener(NoRedirect).open(request, timeout=30)
    except urllib.error.HTTPError as error:
        if error.code != 302:
            error.close()
            raise RuntimeError("Legacy update entrypoint must return the configured 302 redirect") from None
        response = error
    with response:
        if response.status != 302 or response.headers.get("Location") != update_feed.FEED:
            raise RuntimeError("Legacy update entrypoint does not redirect to the canonical stable feed")
    return {"url": update_feed.LEGACY_FEED, "status": 302, "location": update_feed.FEED}


class LegacyFeedRedirect(urllib.request.HTTPRedirectHandler):
    def __init__(self):
        super().__init__()
        self.redirects = 0

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if (self.redirects or req.full_url != update_feed.LEGACY_FEED
                or code != 302 or newurl != update_feed.FEED):
            raise RuntimeError("Unexpected update redirect; only the legacy-to-stable hop is allowed")
        self.redirects += 1
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def verify_entrypoints(path):
    """Public, read-only validation. No R2 credentials or publishing operations."""
    sparkle_verify(path)
    canonical = public_verify("tsx/macos/stable/appcast.xml", path, XML_TYPE, "no-cache")
    legacy = check_legacy_redirect()
    handler = LegacyFeedRedirect()
    request = urllib.request.Request(update_feed.LEGACY_FEED,
                                    headers={"Accept-Encoding": "identity", "User-Agent": "UUThings-Update-Service/1.0"})
    with urllib.request.build_opener(handler).open(request, timeout=30) as response:
        if handler.redirects != 1 or response.geturl() != update_feed.FEED:
            raise RuntimeError("Legacy update request did not follow exactly one hop to stable")
        _verify_public_response(response, path, XML_TYPE, "no-cache")
    legacy["final_url"] = update_feed.FEED
    legacy["sha256"] = archive_evidence.sha(path)
    return {"stable": canonical, "legacy": legacy}


def public_verify(key, path, content_type, cache_control):
    request = urllib.request.Request("https://updates.uuthings.com/" + key,
                                     headers={"Accept-Encoding": "identity", "User-Agent": "UUThings-Update-Service/1.0"})
    with urllib.request.build_opener(NoRedirect).open(request, timeout=120) as response:
        status = _verify_public_response(response, path, content_type, cache_control)
        return {"key": key, "sha256": archive_evidence.sha(path), "content_type": content_type,
                "cache_control": cache_control, "cf_cache_status": status}


def _verify_public_response(response, path, content_type, cache_control):
    if response.status != 200 or response.headers.get("Content-Type") != content_type:
        raise RuntimeError("Public response has unexpected status or content type")
    if response.headers.get("Cache-Control") != cache_control:
        raise RuntimeError("Public cache policy differs from the prepared plan")
    status = response.headers.get("CF-Cache-Status", "")
    if cache_control != IMMUTABLE and status in ("HIT", "STALE", "UPDATING", "REVALIDATED"):
        raise RuntimeError("Mutable/test object was served from the CDN cache")
    checksum = hashlib.sha256()
    total = 0
    for chunk in iter(lambda: response.read(1024 * 1024), b""):
        total += len(chunk)
        if total > path.stat().st_size:
            raise RuntimeError("Public object is larger than the local candidate")
        checksum.update(chunk)
    if checksum.hexdigest() != archive_evidence.sha(path):
        raise RuntimeError("Public bytes differ from the prepared local file")
    return status


def upload(args, settings, s3):
    plan = json.loads((args.directory / "plan.json").read_text())
    if (plan["bucket"], plan["account_id"]) != (settings["bucket"], settings["account_id"]):
        raise RuntimeError("Plan belongs to a different bucket/account")
    channel = plan["channel"]
    if channel not in ("qa", "stable") or plan["feed_key"] != f"tsx/macos/{channel}/appcast.xml":
        raise RuntimeError("Unexpected channel or manifest path")
    if channel == "stable" and not args.confirm_production:
        raise RuntimeError("Stable publication requires explicit authorization and --confirm-production")
    with retention_bridge.locked_session(args, settings) as retention:
        retention.validate_prepared(plan.get("retention"))
        if len(plan.get("objects", [])) != 2 or plan["objects"][0].get("type") != DMG_TYPE:
            raise RuntimeError("Expected one DMG and one checksum object")
        dmg = plan["objects"][0]
        identity = retention_bridge.identify_candidate(plan["version"], plan["build"], Path(dmg["path"]), dmg["sha256"])
        prepared_choice = plan.get("retention_choice")
        if not isinstance(prepared_choice, dict):
            raise RuntimeError("Candidate retention review is missing; prepare and review again")
        choice = retention_bridge.candidate_policy(identity, prepared_choice.get("approval"))
        if choice != prepared_choice:
            raise RuntimeError("Final candidate or retention choice changed; prepare and review again")
        retention.validate_candidate(choice)
        receipt, receipt_path = _upload(args, settings, s3() if callable(s3) else s3, plan)
    # The standalone planner acquires the shared lock itself. Never run it
    # while this publisher holds the lock, and never apply/delete implicitly.
    if channel == "stable":
        evidence = args.directory / ("retention-" + uuid.uuid4().hex + ".json")
        try:
            receipt["retention_plan"] = retention.maintenance(evidence)
        except Exception:
            receipt["retention_plan"] = {"state": "failed", "report": str(evidence)}
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
            raise RuntimeError("Stable publication is complete, but its R2 retention check failed; do not republish") from None
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Uploaded and verified {channel}; {len(receipt['verified'])} public objects match local bytes.")


def _upload(args, settings, s3, plan):
    channel = plan["channel"]
    audit_result = cloudflare_audit.audit(settings, keychain(settings["audit_keychain_service"], settings["keychain_account"]))
    prefix = update_feed.release_prefix(plan["version"], plan["build"]) if channel == "stable" else "tsx/macos/qa/artifacts/"
    feed = args.directory / "appcast.xml"
    if archive_evidence.sha(feed) != plan["feed_sha256"]:
        raise RuntimeError("Prepared feed changed; prepare and review again")
    sparkle_verify(feed)
    if len(plan["objects"]) != 2:
        raise RuntimeError("Expected one DMG and one checksum object")
    dmg, sums = plan["objects"]
    filename = f"TSX-{plan['version']}-macOS-universal.dmg"
    if (not dmg["key"].endswith("/" + filename) or dmg["type"] != DMG_TYPE
            or sums["key"] != dmg["key"].removesuffix(filename) + "SHA256SUMS.txt"
            or sums["type"] != TEXT_TYPE):
        raise RuntimeError("Unexpected release artifact names or types")
    item = update_feed.read_xml(feed.read_bytes()).find("channel/item")
    enclosure = item.find("enclosure") if item is not None else None
    if (enclosure is None or enclosure.get("url") != settings["public_origin"] + "/" + dmg["key"]
            or enclosure.get("length") != str(Path(dmg["path"]).stat().st_size)
            or item.findtext(update_feed.tag("version")) != plan["build"]
            or item.findtext(update_feed.tag("shortVersionString")) != plan["version"]):
        raise RuntimeError("Prepared manifest does not describe its planned artifact")
    if Path(sums["path"]).read_text() != f"{dmg['sha256']}  {filename}\n":
        raise RuntimeError("Checksum file differs from the planned DMG")
    for obj in plan["objects"]:
        if not obj["key"].startswith(prefix) or ".." in obj["key"].split("/"):
            raise RuntimeError("Object is outside its approved channel prefix")
        if archive_evidence.sha(Path(obj["path"])) != obj["sha256"]:
            raise RuntimeError("Prepared artifact changed")
    # Fail before uploading any artifact when another publisher has moved the feed.
    current, _ = object_state(s3, settings["bucket"], plan["feed_key"])
    if current != plan["expected_etag"]:
        raise RuntimeError("Manifest changed since preparation; prepare and review again")
    if channel == "stable":
        check_legacy_redirect()
    artifact_cache = IMMUTABLE if channel == "stable" else "no-store"
    records = []
    for obj in plan["objects"]:
        path = Path(obj["path"])
        put_immutable(s3, settings["bucket"], obj["key"], path, obj["type"], artifact_cache)
        records.append(public_verify(obj["key"], path, obj["type"], artifact_cache))
    cache = "no-cache" if channel == "stable" else "no-store"
    etag = put_manifest(s3, settings["bucket"], plan["feed_key"], feed, plan["expected_etag"], cache)
    receipt = {"time": datetime.now(timezone.utc).isoformat(), "manifest_etag": etag,
               "configuration_audit": audit_result, "verified": records,
               "retention": plan["retention"], "retention_choice": plan["retention_choice"],
               "state": "manifest-published-verification-pending"}
    receipt_path = args.directory / ("receipt-" + uuid.uuid4().hex + ".json")
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    try:
        records.append(public_verify(plan["feed_key"], feed, XML_TYPE, cache))
        if channel == "stable":
            receipt["entrypoints"] = verify_entrypoints(feed)
        receipt["state"] = "complete"
    except Exception:
        receipt["state"] = "manifest-published-verification-failed"
        raise
    finally:
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt, receipt_path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, help="Private config outside Git; required for prepare/upload/retention")
    parser.add_argument("--retention-policy", type=Path, help="Shared R2 policy; defaults to the UUThings service directory")
    parser.add_argument("--retention-tool", type=Path, help="Shared R2 retention tool; defaults to the UUThings service directory")
    commands = parser.add_subparsers(dest="command", required=True)
    stage = commands.add_parser("prepare", help="Read current manifest and prepare a signed reviewable plan, without uploads")
    stage.add_argument("--candidate", type=Path, required=True)
    stage.add_argument("--output", type=Path, required=True)
    stage.add_argument("--channel", choices=("qa", "stable"), default="qa")
    stage.add_argument("--published-at", required=True, help="Actual planned publication timestamp with timezone")
    stage.add_argument("--retention-approval", type=Path, help="Candidate-specific user choice recorded by confirm-retention; required above 500 MB")
    send = commands.add_parser("upload")
    send.add_argument("--directory", type=Path, required=True)
    send.add_argument("--confirm-production", action="store_true")
    verify = commands.add_parser("verify-entrypoints", help="Verify signed stable bytes through both public URLs; no credentials or writes")
    verify.add_argument("--feed", type=Path, required=True, help="Expected signed stable appcast")
    verify.add_argument("--output", type=Path, required=True, help="New evidence file outside Git")
    review = commands.add_parser("review-retention", help="Measure a final candidate locally; does not inspect cloud storage or grant publishing authorization")
    review.add_argument("--candidate", type=Path, required=True)
    confirmation = commands.add_parser("confirm-retention", help="Record an already-authorized large-installer choice for these exact bytes; never obtains user consent")
    confirmation.add_argument("--candidate", type=Path, required=True)
    confirmation.add_argument("--keep-versions", type=int, choices=(1, 2), required=True)
    confirmation.add_argument("--confirm-large-package", action="store_true", required=True)
    confirmation.add_argument("--output", type=Path, required=True, help="New confirmation JSON outside Git")
    retention = commands.add_parser("retention", help="Generate a read-only cloud retention plan using the shared service; never delete objects")
    retention.add_argument("action", choices=("plan",))
    retention.add_argument("--output", type=Path, required=True)
    retention.add_argument("--recover-plan", type=Path, help="Original reviewed plan for a new recovery plan")
    retention.add_argument("--recover-receipt", type=Path, help="Partial maintenance receipt paired with the original plan")
    args = parser.parse_args()
    if args.command in ("review-retention", "confirm-retention"):
        identity = retention_bridge.measure_candidate(args.candidate)
        if args.command == "review-retention":
            keep = retention_bridge.keep_for_size(identity["max_artifact_bytes"])
            print(json.dumps({"candidate": identity, "keep_versions": keep,
                              "user_choice_required": keep is None,
                              "old_versions_and_storage": "unknown: inspect registered cloud references before requesting confirmation"}, indent=2))
        else:
            output = archive_evidence.persistent_directory(args.output)
            approval = retention_bridge.confirm_candidate(identity, args.keep_versions, args.confirm_large_package)
            with output.open("x") as stream:
                stream.write(json.dumps(approval, indent=2) + "\n")
            print(f"Recorded the operator's authorized candidate choice. No objects uploaded.\n{output}")
        return
    if args.command == "verify-entrypoints":
        if args.output.exists():
            parser.error("Evidence output already exists; use a new path")
        result = verify_entrypoints(args.feed)
        with args.output.open("x") as stream:
            stream.write(json.dumps({"time": datetime.now(timezone.utc).isoformat(), "entrypoints": result}, indent=2) + "\n")
        print("Both update entrypoints serve the expected signed stable feed.")
        return
    if args.config is None:
        parser.error("--config is required for prepare/upload/retention")
    settings = config(args.config)
    if args.command == "retention":
        session = retention_bridge.load_session(args, settings)
        output = archive_evidence.persistent_directory(args.output)
        session.maintenance(output,
                            recover_plan=args.recover_plan, recover_receipt=args.recover_receipt)
        print(f"R2 retention {args.action} completed; evidence: {args.output}")
        return
    # Local candidate, approval and policy checks happen before credential access.
    {"prepare": prepare, "upload": upload}[args.command](args, settings, lambda: client(settings))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # SDK errors can contain request URLs or headers. Do not echo credentials
        # or underlying service responses into terminal output or release logs.
        message = str(error) if type(error) in (ValueError, RuntimeError) else type(error).__name__
        sys.exit("Update operation stopped: " + message)
