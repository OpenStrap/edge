"""Release gate checks. Tiny ZIPs stand in for APKs; a fake aapt2 prints the badging."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).with_name("verify_apk.py")


class VerifyApkTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.apk = self.root / "app.apk"
        self.pubspec = self.root / "pubspec.yaml"
        self.pubspec.write_text("name: example\nversion: 1.2.3+79\n")
        self.aapt2 = self.root / "aapt2"
        self.aapt2.write_text(f"#!{sys.executable}\nimport pathlib\nprint(pathlib.Path(__file__).with_name('badging').read_text())\n")
        self.aapt2.chmod(0o755)
        self.badging()

    def badging(self, code="79", package="wtf.openstrap.openstrap_edge"):
        (self.root / "badging").write_text(
            f"package: name='{package}' versionCode='{code}' versionName='1.2.3'\n")

    def package(self, abis=("arm64-v8a",), omit=()):
        with zipfile.ZipFile(self.apk, "w") as archive:
            for abi in abis:
                for library in ("libapp.so", "libflutter.so"):
                    if f"lib/{abi}/{library}" not in omit:
                        archive.writestr(f"lib/{abi}/{library}", b"x")

    def verify(self, variant="arm64-v8a", error=None):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.apk), "--pubspec", str(self.pubspec),
             "--aapt2", str(self.aapt2), "--variant", variant],
            capture_output=True, text=True)
        if error:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(error, result.stderr)
        else:
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_portable_and_single_abi(self):
        self.package(("arm64-v8a", "armeabi-v7a", "x86_64"))
        self.verify("portable")
        self.package()
        self.verify("arm64-v8a")

    def test_rejects_split_version_code_and_other_package(self):
        # --split-per-abi turns build 79 into 2079, which OTA would never see as older.
        self.package()
        self.badging(code="2079")
        self.verify(error="versionCode")
        self.badging(package="other.app")
        self.verify(error="name")

    def test_rejects_wrong_abi_set_or_missing_flutter_library(self):
        self.package(("arm64-v8a", "x86_64"))
        self.verify(error="ABIs")
        self.package(omit=("lib/arm64-v8a/libflutter.so",))
        self.verify(error="missing lib/arm64-v8a/libflutter.so")

    def test_rejects_oversized_portable(self):
        self.package(("arm64-v8a", "armeabi-v7a", "x86_64"))
        contents = self.apk.read_bytes()
        with self.apk.open("wb") as apk:
            apk.seek(150_000_001 - len(contents))  # a sparse hole keeps the ZIP readable
            apk.write(contents)
        self.verify("portable", error="maximum is 150000000")


if __name__ == "__main__":
    unittest.main()
