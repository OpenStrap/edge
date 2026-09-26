#!/usr/bin/env python3
"""Generate an AltStore-format source (apps.json) describing the just-built
unsigned .ipa, so sideload users can subscribe to a URL and get update
notifications instead of manually checking Releases.

Reads the real Info.plist baked into the .ipa (bundle id, version, min OS)
instead of re-parsing pubspec.yaml separately, so this can never drift from
what actually shipped.

Usage: gen_altstore_source.py <path-to-ipa> <output-path> <repo> <tag>
  repo: "owner/name" (for the release download URL)
  tag:  the git tag being released, e.g. "v0.9.29"
"""
import datetime
import json
import os
import plistlib
import sys
import zipfile


def read_info_plist(ipa_path: str) -> dict:
    with zipfile.ZipFile(ipa_path) as z:
        info_plist_names = [
            n for n in z.namelist()
            if n.startswith("Payload/") and n.endswith(".app/Info.plist")
            and n.count("/") == 2  # the app's own Info.plist, not a nested extension's
        ]
        if not info_plist_names:
            raise SystemExit(f"no app Info.plist found inside {ipa_path}")
        with z.open(info_plist_names[0]) as f:
            return plistlib.load(f)


def main() -> None:
    if len(sys.argv) != 5:
        raise SystemExit(f"usage: {sys.argv[0]} <ipa> <out.json> <owner/repo> <tag>")
    ipa_path, out_path, repo, tag = sys.argv[1:5]

    info = read_info_plist(ipa_path)
    bundle_id = info["CFBundleIdentifier"]
    version = info["CFBundleShortVersionString"]
    min_os = info.get("MinimumOSVersion", "15.0")
    size = os.path.getsize(ipa_path)
    ipa_filename = os.path.basename(ipa_path)
    download_url = f"https://github.com/{repo}/releases/download/{tag}/{ipa_filename}"
    date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT00:00:00Z")

    source = {
        "name": "OpenStrap Edge",
        "identifier": f"{bundle_id}.altstore-source",
        "apps": [
            {
                "name": "OpenStrap Edge",
                "bundleIdentifier": bundle_id,
                "developerName": "OpenStrap",
                "subtitle": "Open-source, local-first WHOOP 4.0 companion",
                "localizedDescription": (
                    "Open-source, local-first fitness tracking companion for "
                    "WHOOP 4.0 hardware. Not affiliated with WHOOP, Inc. "
                    "Unsigned sideload build — see IOS_SIDELOAD.md."
                ),
                "size": size,
                "versions": [
                    {
                        "version": version,
                        "date": date,
                        "localizedDescription": f"OpenStrap Edge {version}. See the GitHub release notes for details.",
                        "downloadURL": download_url,
                        "size": size,
                        "minOSVersion": min_os,
                    }
                ],
            }
        ],
    }

    with open(out_path, "w") as f:
        json.dump(source, f, indent=2)
        f.write("\n")
    print(f"wrote {out_path}: {bundle_id} {version}, {size} bytes, min iOS {min_os}")


if __name__ == "__main__":
    main()
