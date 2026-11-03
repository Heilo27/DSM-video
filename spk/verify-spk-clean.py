#!/usr/bin/env python3
"""Fail if an SPK (or the package.tgz inside it) carries macOS junk (TASK-1080, FRD-003).

Checks, for the SPK tar and for package.tgz nested in it:
  - no member whose basename starts with "._" (AppleDouble resource forks)
  - no PAX extended-attribute headers (LIBARCHIVE.xattr.*, SCHILY.xattr.*, com.apple.*)
  - package.tgz holds MANIFEST.sha256, and every file it lists is in the archive

Usage: python3 -I verify-spk-clean.py path/to/package.spk
Exit 0 clean, 1 dirty or unreadable.
"""
import io
import sys
import tarfile

XATTR_PREFIXES = ("LIBARCHIVE.xattr.", "SCHILY.xattr.", "LIBARCHIVE.creationtime")


def audit(tf, label):
    problems = []
    names = []
    for m in tf.getmembers():
        names.append(m.name)
        base = m.name.rstrip("/").rsplit("/", 1)[-1]
        if base.startswith("._"):
            problems.append(f"{label}: AppleDouble entry {m.name!r}")
        for key in m.pax_headers:
            if key.startswith(XATTR_PREFIXES) or "com.apple" in key:
                problems.append(f"{label}: xattr header {key!r} on {m.name!r}")
    return names, problems


def main(path):
    problems = []
    with tarfile.open(path, "r:*") as outer:
        names, p = audit(outer, "spk")
        problems += p
        if "INFO" not in names:
            problems.append("spk: INFO missing")
        pkg = outer.extractfile("package.tgz") if "package.tgz" in names else None
        if pkg is None:
            problems.append("spk: package.tgz missing")
        else:
            with tarfile.open(fileobj=io.BytesIO(pkg.read()), mode="r:gz") as inner:
                inames, p = audit(inner, "package.tgz")
                problems += p
                members = {n.lstrip("./") for n in inames}
                if "MANIFEST.sha256" not in members:
                    problems.append("package.tgz: MANIFEST.sha256 missing")
                else:
                    text = inner.extractfile("MANIFEST.sha256").read().decode()
                    listed = [ln.split(None, 1)[1].strip() for ln in text.splitlines() if ln.strip()]
                    if "backend/dsvideo-backend" not in listed:
                        problems.append("package.tgz: manifest does not list backend/dsvideo-backend")
                    for f in listed:
                        if f not in members:
                            problems.append(f"package.tgz: manifest lists {f!r} but the archive lacks it")
    if problems:
        print("SPK verification FAILED:", file=sys.stderr)
        for line in problems:
            print("  " + line, file=sys.stderr)
        return 1
    print(f"SPK clean: no AppleDouble or xattr entries; manifest consistent ({path})")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
