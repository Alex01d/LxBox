#!/usr/bin/env python3
"""Package local engineering artifacts without inventing acceptance results."""

import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args])


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot(repo, output, name, scope=()):
    # Untracked local profiles, device reports and build outputs are excluded.
    patch = git(repo, "diff", "HEAD", "--binary", "--", *scope)
    destination = output / f"{name}-source-changes.patch"
    destination.write_bytes(patch)
    return {
        "base_revision": git(repo, "rev-parse", "HEAD").decode().strip(),
        "branch": git(repo, "branch", "--show-current").decode().strip(),
        "uncommitted_tracked_changes": bool(patch),
        "patch": destination.name,
        "patch_sha256": sha(destination),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--core", type=Path)
    parser.add_argument("--launcher", type=Path)
    parser.add_argument(
        "--verification", type=Path,
        help="Optional reviewed JSON results; no test success is inferred",
    )
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    core = (args.core or repo.parent / "sing-box-lx").resolve()
    launcher = (args.launcher or repo.parent / "singbox-launcher").resolve()
    output = args.output.resolve()
    apk, aar = output / "lxbox-awg700-arm64-debug.apk", output / "libbox.aar"
    apk_manifest = json.loads((output / "APK-MANIFEST.json").read_text())
    aar_manifest = json.loads((output / "AAR-MANIFEST.json").read_text())
    if sha(apk) != apk_manifest["apk_sha256"] or sha(aar) != aar_manifest["aar_sha256"]:
        raise SystemExit("Artifact differs from its build manifest")
    if apk_manifest.get("installed") or apk_manifest["min_sdk"] != 24:
        raise SystemExit("Unexpected engineering APK metadata")
    verification = (
        json.loads(args.verification.read_text()) if args.verification
        else {"status": "not supplied; acceptance is not inferred from packaging"}
    )
    shutil.copyfile(repo / "docs/ANDROID_AWG_ENGINEERING.md", output / "RUNBOOK.md")
    shutil.copyfile(repo / "docs/spec/tasks/700-tailscale-awg-android.md", output / "SPEC.md")
    shutil.copyfile(core / "lx-test/tailscale-awg/dependencies.json", output / "DEPENDENCIES.json")
    lock = (repo / "app/contract.lock").read_text()
    contract_hash = next(line.partition("=")[2] for line in lock.splitlines() if line.startswith("sha256="))
    manifest = {
        "task": 700,
        "kind": "engineering artifacts; no installation or release publication",
        "sources": {
            "lxbox": snapshot(repo, output, "lxbox"),
            "core": snapshot(core, output, "core"),
            "contract_authority": snapshot(launcher, output, "launcher-contract", ("contract",)),
        },
        "contract_version": (repo / "app/assets/contract/VERSION").read_text().strip(),
        "contract_tree_sha256": contract_hash,
        "dependency_manifest_sha256": sha(output / "DEPENDENCIES.json"),
        "apk_sha256": sha(apk), "aar_sha256": sha(aar),
        "verification": verification,
        "profiles_and_machine_identity_included": False,
        "production_pin_changed": False,
    }
    (output / "REVISIONS.json").write_text(json.dumps(manifest, indent=2) + "\n")
    files = [p for p in sorted(output.rglob("*")) if p.is_file() and p.name != "SHA256SUMS"]
    (output / "SHA256SUMS").write_text("".join(f"{sha(p)}  {p.relative_to(output)}\n" for p in files))
    print(output / "REVISIONS.json")


if __name__ == "__main__":
    main()
