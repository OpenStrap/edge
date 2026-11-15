"""Release gate regressions. Tiny ZIPs isolate delivery rules from compilation."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).with_name("verify_apk.py")


class VerifyApkTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.apk = self.root / "app.apk"
        self.pubspec = self.root / "pubspec.yaml"
        self.pubspec.write_text("name: example\nversion: 1.2.3+79\n")
        # Only the external Android tool is a fixture. The real verifier reads
        # real ZIP entries and pubspec, invokes the tool, and returns its status.
        self.aapt2 = self.root / "aapt2"
        self.aapt2.write_text(
            f"#!{sys.executable}\n"
            "from pathlib import Path\n"
            "import sys\n"
            "assert sys.argv[1:3] == ['dump', 'badging']\n"
            "assert Path(sys.argv[3]).is_file()\n"
            "print(Path(__file__).with_name('badging').read_text())\n"
        )
        self.aapt2.chmod(0o755)
        self.badging()

    def badging(self, code="79", name="1.2.3"):
        (self.root / "badging").write_text(
            f"package: name='example' versionCode='{code}' versionName='{name}'\n"
        )

    def package(self, abis=("arm64-v8a",), omit=()):
        with zipfile.ZipFile(self.apk, "w") as archive:
            for abi in abis:
                for library in ("libapp.so", "libflutter.so", "libplugin.so"):
                    name = f"lib/{abi}/{library}"
                    if name not in omit:
                        archive.writestr(name, b"fixture")

    def verify(self, variant="arm64-v8a", error=None):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.apk), "--pubspec", str(self.pubspec),
             "--aapt2", str(self.aapt2), "--variant", variant],
            capture_output=True, text=True,
        )
        if error:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(error, result.stderr)
        else:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)

    def test_accepts_each_delivery_variant(self):
        # WHY: all four release legs must accept their complete, correctly versioned APK.
        for variant, abis in (
            ("portable", ("arm64-v8a", "armeabi-v7a", "x86_64")),
            ("arm64-v8a", ("arm64-v8a",)),
            ("armeabi-v7a", ("armeabi-v7a",)),
            ("x86_64", ("x86_64",)),
        ):
            with self.subTest(variant=variant):
                self.package(abis)
                result = self.verify(variant)
                self.assertEqual(result["abis"], sorted(abis))
                self.assertEqual(result["versionCode"], "79")
                self.assertEqual(result["versionName"], "1.2.3")
                self.assertEqual(result["bytes"], self.apk.stat().st_size)

    def test_rejects_split_version_code(self):
        # WHY: a split offset makes the next ordinary OTA version look older.
        self.package()
        self.badging(code="2079")
        self.verify(error="versionCode")

    def test_rejects_wrong_version_name(self):
        # WHY: the APK must carry pubspec's user-facing release version too.
        self.package()
        self.badging(name="1.2.2")
        self.verify(error="versionName")

    def test_rejects_missing_build_number_or_badging(self):
        # WHY: absent metadata must fail closed instead of skipping the version gate.
        self.package()
        self.pubspec.write_text("version: 1.2.3\n")
        self.verify(error="NAME+BUILD")
        self.pubspec.write_text("version: 1.2.3+79\n")
        (self.root / "badging").write_text("application: label='example'\n")
        self.verify(error="package metadata")

    def test_rejects_foreign_native_asset_residue(self):
        # WHY: a foreign plugin .so is residue even without a Flutter library pair.
        self.package()
        with zipfile.ZipFile(self.apk, "a") as archive:
            archive.writestr("lib/x86_64/libsqlite3.so", b"fixture")
        self.verify(error="ABIs")

    def test_rejects_missing_portable_abi(self):
        # WHY: losing an ABI silently narrows the portable download's compatibility.
        self.package(("arm64-v8a", "armeabi-v7a"))
        self.verify("portable", error="ABIs")

    def test_rejects_each_missing_flutter_library(self):
        # WHY: a plugin alone cannot make an ABI runnable. Check both library names.
        for library in ("libapp.so", "libflutter.so"):
            with self.subTest(library=library):
                self.package(omit=(f"lib/arm64-v8a/{library}",))
                self.verify(error=f"missing lib/arm64-v8a/{library}")

    def test_portable_size_limit_is_inclusive_and_counts_padding(self):
        # WHY: the 150 MB cap covers actual file bytes, including packaging holes.
        self.package(("arm64-v8a", "armeabi-v7a", "x86_64"))
        # Prepending a sparse hole preserves ZIP offsets relative to its end.
        contents = self.apk.read_bytes()
        with self.apk.open("wb") as apk:
            apk.seek(150_000_000 - len(contents))
            apk.write(contents)
        self.assertEqual(self.verify("portable")["bytes"], 150_000_000)
        with self.apk.open("ab") as apk:
            apk.write(b"x")
        self.verify("portable", error="maximum is 150000000")

    def test_rejects_tool_failure_and_invalid_zip(self):
        # WHY: tool and container errors cannot be mistaken for a verified artifact.
        self.package()
        self.aapt2.write_text(f"#!{sys.executable}\nimport sys\nsys.exit(1)\n")
        self.verify(error="non-zero exit status")
        self.aapt2.write_text(f"#!{sys.executable}\nprint(\"package: versionCode='79' versionName='1.2.3'\")\n")
        self.apk.write_bytes(b"broken")
        self.verify(error="not a zip file")


if __name__ == "__main__":
    unittest.main()
