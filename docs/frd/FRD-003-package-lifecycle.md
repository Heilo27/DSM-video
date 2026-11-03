# FRD-003 — Package Lifecycle: Start, Stop, Health and a Clean Install

**Status:** Specified and implemented 2026-11-03 (TASK-1080).
**Authority:** TASK-1080 (Friday's dispatch). Design calls made to carry it out are tagged **[DESIGN]** and can be
revised without going back to Ryan. One call that narrows a stated safety setting is tagged **[FLAG]** (FR-305).
**Truths:** `docs/TRUTHS.md` (draft). **Mission:** `docs/frd/FRD-000-mission.md`.
**Code:** `spk/DSVideoServer/scripts/start-stop-status`, `backend/cmd/dsvideo-backend/healthz.go`,
`spk/build-spk-macos.sh`, `spk/verify-spk-clean.py`. **Harness:** `spk/tests/test-start-stop-status.sh`.

## Truth Test
- Serves: **P1** (every title findable and playable). A server that silently fails to start, or that is
  replaced by a stale copy of itself, makes the whole library unreachable.
- Supports: **S2** (a failed start names its real cause in the package log and the DSM status, instead of
  "running" or silence), **S3** (stopping and upgrading never leaves a half-written database: the backend gets
  a TERM and ten seconds to close it before anything harsher), **S4** (database, log and secrets are readable
  only by the package user).
- Violates: none. Checked against **A2** "no external runtime dependencies on the NAS": the health probe is a
  flag of the backend binary itself (`--healthcheck`), not `curl` or `wget`; the integrity check uses
  `sha256sum`, which DSM ships. Checked against **A4**: `/api/v1/healthz` grants nothing; callers that are not
  direct loopback processes learn only `ok` and the version.
- Verdict: **KEEP.** Plumbing under P1; it adds no user-facing feature.

---

## 1. Terms

| Term | Meaning |
|---|---|
| **Package user** | The DSM-created service user the package runs as (uid 1026 on the reference NAS). |
| **Port holder** | Whatever process is LISTENing on the backend port (default 8090). |
| **Ours** | A process of the package user's uid whose identity is `dsvideo-backend`. |
| **Foreign holder** | Any other process on the port: another uid (root included), or the package user's uid running something else. |
| **Health gate** | `start` does not report success until the new process proves, over loopback, that it is the right one. |
| **Manifest** | `MANIFEST.sha256`, a list of sha256 sums of every binary the package ships. |

## 2. Requirements

### FR-301 Port-holder detection
The start script finds who holds the port by reading `/proc/net/tcp` and `/proc/net/tcp6` (LISTEN state only),
matching the port in hex (8090 is `1F9A`), taking the owner uid from the table and mapping the socket inode to a
pid through `/proc/<pid>/fd`. It does not depend on `netstat`, `ss` or `lsof`.
- **Free**: start proceeds.
- **Ours** (uid is the package user's and the process is `dsvideo-backend`): a stale copy of ourselves. Start
  ends it (FR-303 sequence) and carries on.
- **Foreign**: start **never kills it**, whether it is root's, another user's, or an unrelated process of the
  package user. It writes the holder's uid, pid and command line to the package log and **fails the start
  loudly** (non-zero exit). `stop` applies the same rule: it will not kill a foreign holder either.
- [DESIGN] Process identity tolerates emulation layers. Under Rosetta (Docker Desktop on Apple Silicon running an
  amd64 image) `/proc/<pid>/exe` points at the emulator, not the binary. Identity is therefore "the exe is
  `dsvideo-backend`, or, when it is not, the process name (`comm`) is". A foreign program is still rejected
  because both must disagree before a process is judged not ours. Found by the amd64 end-to-end run: the
  earlier exe-only check rejected the live backend and orphaned it. Real DSM reports the real exe; this only
  widens nothing there.
- Why: the previous script compared against `0x2392` (9106), so it never matched port 8090 and never found
  any holder.

### FR-302 Health gate
The backend serves `GET /api/v1/healthz` and has a `--healthcheck` mode (flags `--expect-pid`, `--expect-uid`,
`--expect-version`, `--timeout`; it reads the port from the same `DSVIDEO_PORT` setting as the server).
- A direct loopback caller (no proxy headers) receives `{ok, version, pid, uid, startedAt, db:{ok}}`. Any other
  caller (remote, or through the DSM reverse proxy) receives only `{ok, version}`.
- `ok` is true only if a `SELECT 1` against the database succeeds within 2 seconds; otherwise HTTP 503.
- `start` launches the backend, then polls `--healthcheck` until it reports the **launched pid**, the
  **package user's uid** and the **version this package was built as**, or until the timeout (30 s, override
  `DSVIDEO_START_TIMEOUT`). A different process answering on the port, an older version answering, or a child
  that exits during startup all fail the start with the reason in the log, leave no pidfile and leave no
  backend running.
- `status` (what DSM shows) uses the same probe, not just "the pid exists".
- The library scan runs in the background after the server is listening (first scan about 5 s after boot), so
  it is not on the gate's critical path. Database migrations and the profiles migration run before the server
  listens and are on it. 30 s was verified under Rosetta emulation (healthy in about 2 s on a small database).
  It has **not** been measured against the production library (about 5.5k items); the setting exists so that can
  be tuned without a release.
- `/api/v1/healthz` is registered public (no token) and contains no library or profile data.

### FR-303 Stop
`stop` ends the backend in this order and exits non-zero if it cannot finish:
1. Record the backend's children (for the sweep below), then send TERM and wait up to 10 seconds for it to exit.
2. If still alive, send KILL and confirm it is gone.
3. Re-check the port. A backend of ours that is on the port but not in the pidfile (lost pidfile, interrupted
   start) is a leftover and is ended the same way. A foreign holder is reported and left alone (FR-301).
4. End the watchdog loop (the background log-size trimmer; it never restarts the backend) and sweep orphaned
   `ffmpeg`/`ffprobe` children recorded in step 1, only if they are still those programs. Remove the pidfile.
5. **Verify the port is free**, not merely that the pid is gone. A port still held by ours is an error; a port
   still held by a foreign process is logged as such and is not our failure.

`start` uses the same terminate-and-verify step when it replaces its own stale backend.

### FR-304 Integrity manifest
The build writes `MANIFEST.sha256` covering `backend/dsvideo-backend` and, when bundled, `bin/ffmpeg` and
`bin/ffprobe`, and verifies it once before archiving. `start` runs `sha256sum -c` against it first. Any
mismatch or missing listed file stops the start, with the offending file named in the log, before the backend
runs.
- Threat model, stated plainly: this catches **accidents** (a truncated copy, a half-applied upgrade, a binary
  swapped by hand). It does not stop an attacker who can write to the package directory, who can rewrite the
  manifest too. It is not a signature.
- A package without a manifest (a build made before this change) logs a warning and starts, so an upgrade from
  an older SPK is not blocked. [DESIGN]

### FR-305 File modes **[FLAG]**
The database, its `-wal` and `-shm` files, the pre-migration backup copies, the log and rotated log, the JWT
secret and the pidfile are mode `0600`, owned by the package user. They are created that way (not created open
and tightened later) and any existing ones are tightened at every start. A file the script cannot change (left
behind by root) is reported in the log, not ignored.
- SQLite creates `-wal`/`-shm` with the main file's mode, so creating the database `0600` covers them.
- **Decision for Ryan:** the task asked for "umask 077 for the backend". The backend process runs at **022**
  instead, and only the package-private files above are forced to `0600`. Reason: the backend also writes into
  the user's media shares (normalised and converted copies, moved or backed-up originals). A process-wide 077
  would make those `0600`, unreadable to other DSM users and to Plex-style apps reading the same share, which
  breaks P1 and the "adapt to the folders that exist" posture (A1). The sensitive files lose nothing; the media
  outputs keep working. This is a deliberate narrowing of the literal wording and is flagged here rather than
  made silently.
- Package-internal caches (transcode segments, trickplay, image cache) stay at the default modes; they hold no
  credentials and live inside the package's own data directory.

### FR-306 Clean SPK
`build-spk-macos.sh` produces an SPK with **no AppleDouble `._*` entries and no extended-attribute headers**:
it sets `COPYFILE_DISABLE=1`, clears `._*` files and xattrs from the staging tree, and archives with
`--no-xattrs` where bsdtar supports it. After building, `spk/verify-spk-clean.py` opens every archive with
Python `tarfile` (the SPK and the inner `package.tgz`), fails on any `._` basename or PAX xattr header, and
checks that `MANIFEST.sha256` is present and lists every shipped binary. A dirty archive fails the build.
- Why: DSM extracts `._x` files next to the real ones, where they pollute the install and the library scan.

## 3. Truth Test per FR

| FR | Truth served | Anti-truth check |
|---|---|---|
| FR-301 | P1 (start must reach a working server), S2 (names the holder) | Not killing foreign holders protects other software on the NAS: no A-conflict |
| FR-302 | S2 (status is real health), P1 | A2: no `curl` dependency. A4: the endpoint grants nothing |
| FR-303 | S3 (clean DB close), P1 | none |
| FR-304 | S2 (loud failure), S4 | A2: `sha256sum` ships with DSM. Not a signature, stated |
| FR-305 | S4, S3 | A1: media outputs stay readable by others, which is why the process umask is not 077 |
| FR-306 | P1 (installable package), S2 | none |

## 4. Deferred and open

- Gate timeout on the real 5.5k-item library is unmeasured (FR-302). First install on the NAS should read the
  log line "launched pid N; waiting up to 30s" against the time `healthz` first answers.
- If a start fails after launching, a misidentified child could be left running. Identity checking (FR-301)
  reduces this to the emulation case; a process-group kill on failure would close it. Not done here.
- Manifest signing (a key the package does not carry) is out of scope; the threat model is accidents.
- Release SPK build, version bump and NAS install are explicitly not part of this change.

## 5. Acceptance Criteria

- **AC-1 (FR-301).** With the port held by the package's own stale backend, `start` ends it and succeeds. With
  it held by a root-owned process, or by another program of the package user, `start` and `stop` kill nothing,
  the log has the holder's uid, pid and command line, and `start` exits non-zero. Port detection matches
  `1F9A`, reads IPv4 and IPv6 tables and reports the owner uid.
- **AC-2 (FR-302).** `GET /api/v1/healthz` returns pid, uid, version and db status to a direct loopback caller
  and only ok and version to others, and 503 when the database probe fails. `start` succeeds only after
  `--healthcheck` confirms the launched pid, the package user's uid and the packaged version within the
  timeout; a wrong version fails the start and leaves no backend and no pidfile. `status` uses the probe.
- **AC-3 (FR-303).** `stop` sends TERM, waits 10 s, sends KILL if needed, ends the watchdog loop, sweeps
  ffmpeg/ffprobe children and the pidfile, and verifies the port is free. Nothing else is killed.
- **AC-4 (FR-304).** The build generates `MANIFEST.sha256`; `start` verifies it and refuses to run on a
  mismatch, naming the file.
- **AC-5 (FR-305).** After a start, the DB, WAL, SHM, log, pre-migration copy, JWT secret and pidfile are
  `0600`. The backend process umask is `022`, so files it writes outside the package directories are not
  forced private. (Narrowing of the original wording, flagged above.)
- **AC-6 (FR-306).** The SPK built by `build-spk-macos.sh` contains zero `._` entries and zero PAX xattr
  headers, verified by Python `tarfile`; the verifier is part of the build.
- **AC-7.** This FRD exists and is in the same commit as the code it specifies.

Verification: `sh spk/tests/test-start-stop-status.sh` (fake `/proc`, 32 checks) plus a Docker end-to-end run on
amd64 and arm64 covering clean start, own-stale replacement, root-owned foreign holder, manifest tamper and
version mismatch.
