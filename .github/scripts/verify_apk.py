#!/usr/bin/env python3
"""Reject release APKs whose version, native targets, or size break delivery.

The release workflow supplies aapt2 from the Android SDK. All expectations come
from pubspec.yaml and the selected artifact, never the APK's own declarations.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile


VARIANT_ABIS = {
    "portable": {"arm64-v8a", "armeabi-v7a", "x86_64"},
    "arm64-v8a": {"arm64-v8a"},
    "armeabi-v7a": {"armeabi-v7a"},
    "x86_64": {"x86_64"},
}
PORTABLE_MAX_BYTES = 150_000_000
APPLICATION_ID = "wtf.openstrap.openstrap_edge"


def resolve_aapt2(aapt2):
    """Run only an executable file named aapt2, by absolute path, never via a shell."""
    path = shutil.which(aapt2)
    if path is None:
        raise ValueError(f"aapt2 not found: {aapt2!r}")
    path = Path(path).resolve()
    if path.name != "aapt2" or not path.is_file() or not os.access(path, os.X_OK):
        raise ValueError(f"not an aapt2 executable: {str(path)!r}")
    return str(path)


def verify_apk(apk, pubspec, variant, aapt2, application_id=APPLICATION_ID):
    version = re.search(r"^version:\s*([^\s+]+)\+([0-9]+)\s*(?:#.*)?$",
                        pubspec.read_text(), re.MULTILINE)
    if not version:
        raise ValueError("pubspec must contain version: NAME+BUILD")
    expected_name, expected_code = version.groups()
    badging = subprocess.run(
        [resolve_aapt2(aapt2), "dump", "badging", str(apk.resolve())],
        check=True, capture_output=True, text=True,
    ).stdout
    package = re.search(r"^package: (.*)$", badging, re.MULTILINE)
    if not package:
        raise ValueError("aapt2 did not report package metadata")
    metadata = dict(re.findall(r"(\w+)='([^']*)'", package.group(1)))
    for key, expected in (("name", application_id), ("versionName", expected_name),
                          ("versionCode", expected_code)):
        if metadata.get(key) != expected:
            raise ValueError(f"{key}: expected {expected!r}, got {metadata.get(key)!r}")

    with zipfile.ZipFile(apk) as archive:
        entries = {entry.filename for entry in archive.infolist() if not entry.is_dir()}
    abis = {name.split("/")[1] for name in entries if name.startswith("lib/")}
    expected_abis = VARIANT_ABIS[variant]
    if abis != expected_abis:
        raise ValueError(f"ABIs: expected {sorted(expected_abis)}, got {sorted(abis)}")
    for abi in sorted(abis):
        for library in ("libapp.so", "libflutter.so"):
            if f"lib/{abi}/{library}" not in entries:
                raise ValueError(f"missing lib/{abi}/{library}")

    size = apk.stat().st_size
    if variant == "portable" and size > PORTABLE_MAX_BYTES:
        raise ValueError(f"portable APK is {size} bytes; maximum is {PORTABLE_MAX_BYTES}")
    return {
        "apk": str(apk), "variant": variant, "bytes": size,
        "versionCode": expected_code, "versionName": expected_name, "abis": sorted(abis),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--pubspec", type=Path, default=Path("pubspec.yaml"))
    parser.add_argument("--variant", choices=VARIANT_ABIS, required=True)
    parser.add_argument("--aapt2", default="aapt2")
    args = parser.parse_args()
    try:
        result = verify_apk(args.apk, args.pubspec, args.variant, args.aapt2)
    except (ValueError, OSError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print(f"APK verification failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
