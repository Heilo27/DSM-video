## SPK packaging (DSM 7.2.2+)

This folder contains a **skeleton** Synology SPK definition for the DS Video clone backend.

### Current status

- The backend service implementation lives in [`backend/server.py`](../backend/server.py).
- The SPK skeleton lives in [`spk/DSVideoServer/`](DSVideoServer/).
- Packaging the backend into a signed/redistributable SPK is a **separate step** that requires Synology’s `pkgscripts-ng` toolchain and (optionally) bundling a Python runtime.

### Runtime strategy

DSM 7 removed the legacy SPK signing flow and encourages packages to run with **lower privilege** (package user). We’ll ship:

- A `start-stop-status` script that runs the backend as the package user.
- A vendored Python runtime under `target/python/` (preferred), or a dependency on Synology’s Python package (fallback).

### Building an SPK (outline)

1. Fetch Synology tooling:
   - `pkgscripts-ng` (PkgCreate.py)
   - Example packages/templates
2. Arrange package content:
   - `target/backend/server.py`
   - `target/python/...` (if bundling runtime)
3. Use `PkgCreate.py` for DSM 7.x to produce `*.spk`.

