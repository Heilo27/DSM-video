"""Builds small SPK fixtures (outer tar holding INFO + package.tgz) for test_verify_spk_clean.py.

Each `mode` plants exactly one defect (or none) so a test can name the check it exercises:

  clean               valid SPK: INFO, package.tgz{backend/dsvideo-backend, MANIFEST.sha256}
  inner-comapple      bare com.apple.* PAX header (no xattr prefix) inside package.tgz
  inner-xattr         PAX xattr header on a file inside package.tgz
  inner-dot           AppleDouble "._" entry inside package.tgz
  outer-xattr         PAX xattr header on INFO in the outer tar
  outer-dot           scripts/._start-stop-status in the outer tar
  outer-dot-top       ._INFO at the top of the outer tar
  nomanifest          package.tgz has no MANIFEST.sha256
  manifest-nobackend  manifest exists but does not list backend/dsvideo-backend
  manifest-ghost      manifest lists a file the archive does not contain
  noinfo              the outer tar has no INFO
  nopackage           the outer tar has no package.tgz
"""
import hashlib
import io
import tarfile

MODES = (
    "clean", "inner-comapple", "inner-xattr", "inner-dot", "outer-xattr", "outer-dot", "outer-dot-top",
    "nomanifest", "manifest-nobackend", "manifest-ghost", "noinfo", "nopackage",
)


def _add(tf, name, data=b"x", pax=None):
    ti = tarfile.TarInfo(name)
    ti.size = len(data)
    if pax:
        ti.pax_headers = pax
    tf.addfile(ti, io.BytesIO(data))


def _inner(mode):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz", format=tarfile.PAX_FORMAT) as t:
        binary = b"binary"
        xattr = {"LIBARCHIVE.xattr.user.test": "x"} if mode == "inner-xattr" else None
        if mode == "inner-comapple":
            xattr = {"com.apple.quarantine": "x"}
        _add(t, "backend/dsvideo-backend", binary, xattr)
        if mode == "inner-dot":
            _add(t, "backend/._dsvideo-backend")
        if mode != "nomanifest":
            lines = hashlib.sha256(binary).hexdigest() + "  backend/dsvideo-backend\n"
            if mode == "manifest-nobackend":
                _add(t, "bin/ffmpeg")
                lines = hashlib.sha256(b"x").hexdigest() + "  bin/ffmpeg\n"
            if mode == "manifest-ghost":
                lines += hashlib.sha256(b"x").hexdigest() + "  bin/ffprobe\n"
            _add(t, "MANIFEST.sha256", lines.encode())
    return buf.getvalue()


def build_spk(out_path, mode="clean"):
    if mode not in MODES:
        raise ValueError(f"unknown mode {mode!r}; one of {MODES}")
    with tarfile.open(out_path, "w", format=tarfile.PAX_FORMAT) as o:
        if mode != "noinfo":
            xattr = {"SCHILY.xattr.user.test": "x"} if mode == "outer-xattr" else None
            _add(o, "INFO", b'package="x"\n', xattr)
        if mode == "outer-dot":
            _add(o, "scripts/._start-stop-status")
        if mode == "outer-dot-top":
            _add(o, "._INFO")
        if mode != "nopackage":
            _add(o, "package.tgz", _inner(mode))
    return out_path
