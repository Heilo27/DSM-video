"""Tests for spk/verify-spk-clean.py (TASK-1080, FRD-003 AC on a clean SPK).

Run: python3 -m unittest discover -s spk/tests -p 'test_verify*.py'
VERIFY_SPK_CLEAN=/path/to/verify-spk-clean.py points the tests at another copy (used to prove
each check matters by running them against a verifier with that check removed).
"""
import os
import subprocess
import sys
import tempfile
import unittest

from spk_fixtures import build_spk

HERE = os.path.dirname(os.path.abspath(__file__))
VERIFIER = os.environ.get("VERIFY_SPK_CLEAN") or os.path.join(HERE, "..", "verify-spk-clean.py")


def verify(mode):
    """Build the fixture for `mode`, run the verifier on it exactly as the build does."""
    with tempfile.TemporaryDirectory() as d:
        spk = build_spk(os.path.join(d, "pkg.spk"), mode)
        r = subprocess.run([sys.executable, "-I", VERIFIER, spk], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


class VerifySpkClean(unittest.TestCase):
    def assertDirty(self, mode, needle):
        rc, out = verify(mode)
        self.assertEqual(rc, 1, f"{mode}: expected exit 1, got {rc}: {out}")
        self.assertIn(needle, out, f"{mode}: the report must name the problem")

    # given a clean SPK / when verified / then exit 0
    def test_clean_spk_passes(self):
        rc, out = verify("clean")
        self.assertEqual(rc, 0, out)
        self.assertIn("SPK clean", out)

    # given macOS junk in package.tgz / when verified / then it is refused and named
    def test_inner_xattr_header_is_refused(self):
        self.assertDirty("inner-xattr", "xattr header")

    def test_inner_bare_com_apple_header_is_refused(self):
        self.assertDirty("inner-comapple", "xattr header")

    def test_inner_appledouble_entry_is_refused(self):
        self.assertDirty("inner-dot", "AppleDouble entry")

    # given macOS junk in the OUTER tar (a place the build used to miss) / then refused
    def test_outer_xattr_header_is_refused(self):
        self.assertDirty("outer-xattr", "xattr header")

    def test_outer_appledouble_in_scripts_is_refused(self):
        self.assertDirty("outer-dot", "AppleDouble entry")

    def test_outer_appledouble_at_top_level_is_refused(self):
        self.assertDirty("outer-dot-top", "AppleDouble entry")

    # given a package.tgz without / with a hollow manifest / then refused (D4's build-side twin)
    def test_missing_manifest_is_refused(self):
        self.assertDirty("nomanifest", "MANIFEST.sha256 missing")

    def test_manifest_without_the_backend_is_refused(self):
        self.assertDirty("manifest-nobackend", "does not list backend/dsvideo-backend")

    def test_manifest_naming_a_file_the_archive_lacks_is_refused(self):
        self.assertDirty("manifest-ghost", "archive lacks it")

    # given a structurally incomplete SPK / then refused
    def test_missing_info_is_refused(self):
        self.assertDirty("noinfo", "INFO missing")

    def test_missing_package_tgz_is_refused(self):
        self.assertDirty("nopackage", "package.tgz missing")

    # given no file / a non-tar / when verified / then a failure, not a crash that reads as success
    def test_unreadable_input_does_not_pass(self):
        with tempfile.TemporaryDirectory() as d:
            junk = os.path.join(d, "junk.spk")
            with open(junk, "wb") as f:
                f.write(b"not a tar")
            r = subprocess.run([sys.executable, "-I", VERIFIER, junk], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)

    def test_wrong_usage_exits_2(self):
        r = subprocess.run([sys.executable, "-I", VERIFIER], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
