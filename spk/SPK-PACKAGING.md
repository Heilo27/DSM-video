# SPK Packaging Reference

How to build and structure a Synology DSM 7 package (.spk) for DS Video.

---

## Quick Build

```bash
cd spk/
./build-spk-macos.sh amd64    # DS923+ (AMD Ryzen)
./build-spk-macos.sh arm64    # ARM-based NAS models
```

Output: `build/spk/DSVideoServer-{version}-{arch}.spk`

---

## SPK File Structure

An `.spk` file is a **plain tar archive** (NOT gzipped) containing:

```
DSVideoServer-0.3.0-0001-x64.spk (plain tar)
├── INFO                          # Package metadata (MUST be first entry)
├── PACKAGE_ICON.PNG              # 72x72 icon for Package Center
├── PACKAGE_ICON_256.PNG          # 256x256 icon for Package Center
├── package.tgz                   # Compressed package contents
├── scripts/                      # Lifecycle scripts
│   ├── preinst                   # Runs before installation
│   ├── postinst                  # Runs after installation
│   └── start-stop-status         # Service control (start/stop/status)
├── conf/                         # DSM 7 configuration
│   ├── privilege                 # Package privilege requirements
│   └── resource                  # Portal/webservice proxy config
└── ui/                           # DSM desktop integration
    ├── config                    # App launcher configuration
    └── images/                   # Desktop icons
        ├── DSVideoServer_64.png
        ├── DSVideoServer_128.png
        └── DSVideoServer_256.png
```

---

## Key Files Explained

### INFO

Package metadata. Fields that matter:

```
package="DSVideoServer"           # Internal package name (no spaces)
version="0.3.0-0001"             # Version string
arch="x86_64"                    # Target architecture
firmware="7.0-40000"             # Minimum DSM version
os_min_ver="7.0-40000"           # Minimum OS version
displayname="DS Video"           # Human-readable name
startable="yes"                  # Has a service to start/stop
dsmuidir="ui"                    # Directory containing desktop config
dsmappname="com.dsvideo.app"     # Reverse-DNS app identifier
adminprotocol="http"             # Protocol for admin URL
adminport="8080"                 # Port the service listens on
adminurl="/"                     # Path to admin interface
```

### conf/privilege

Minimal privilege file required by DSM 7:

```json
{"defaults": {"run-as": "package"}}
```

### conf/resource

Portal configuration for nginx reverse proxy:

```json
{
  "portal-alias": "dsvideo",
  "webservice": {
    "portal": [{
      "app": "DSVideoServer",
      "type": "alias",
      "name": "dsvideo",
      "alias": "dsvideo",
      "backend": {
        "type": "http",
        "host": "127.0.0.1",
        "port": 8080
      }
    }]
  }
}
```

This tells DSM's nginx to proxy `http://nas-ip/dsvideo/` to the Go backend on port 8080.

### ui/config

Registers the app icon on the DSM desktop:

```json
{
  ".url": {
    "com.dsvideo.app": {
      "type": "url",
      "title": "DS Video",
      "desc": "Stream your personal video library",
      "icon": "images/DSVideoServer_{0}.png",
      "url": "/dsvideo/",
      "allUsers": true,
      "grantPrivilege": "local"
    }
  }
}
```

- `icon`: `{0}` is replaced by DSM with the appropriate size (64, 128, 256)
- `url`: Opens this URL when the icon is clicked
- `allUsers`: All DSM users see the icon

### scripts/start-stop-status

Service lifecycle script. Called with argument `start`, `stop`, or `status`.

- Must return exit code 0 for success
- `status`: exit 0 = running, exit 1 = stopped
- Binary path: `/var/packages/DSVideoServer/target/backend/dsvideo-backend`
- Log path: `/var/packages/DSVideoServer/var/DSVideoServer.log`
- PID file: `/var/packages/DSVideoServer/var/server.pid`

---

## package.tgz Contents

The `package.tgz` is a gzipped tar containing the actual application files. These extract to `/volume1/@appstore/DSVideoServer/` and are accessible via the symlink at `/var/packages/DSVideoServer/target/`.

```
package.tgz
├── backend/
│   └── dsvideo-backend           # Go binary (Linux, static, CGO_ENABLED=0)
├── ui/                           # DSM desktop icon (MUST be here, not just SPK root)
│   ├── config                    # App launcher configuration
│   └── images/                   # Desktop icons (64, 128, 256px)
└── var/                          # Empty dir, placeholder for runtime data
```

**IMPORTANT:** The `ui/` directory MUST be inside `package.tgz` so it gets installed to the target
directory. `dsmuidir="ui"` in INFO tells DSM to look at `<target>/ui/config`. If `ui/` is only at
the SPK root level, DSM will NOT find it and no desktop icon will appear.

---

## DSM 7 Directory Layout (After Install)

```
/var/packages/DSVideoServer/
├── target -> /volume1/@appstore/DSVideoServer    # Symlink to package contents
│   ├── backend/
│   │   └── dsvideo-backend                       # Go binary
│   └── ui/                                       # DSM desktop icon config
│       ├── config
│       └── images/
├── var/                                          # Writable data directory
│   ├── dsvideo.db                                # SQLite database
│   ├── DSVideoServer.log                         # Server log
│   ├── server.pid                                # PID file
│   ├── .jwt_secret                               # Persisted JWT signing key
│   ├── images/                                   # Cached poster images
│   └── transcode/                                # HLS transcode output
├── etc/                                          # Package config (unused)
└── tmp/                                          # Temp files
```

---

## Cross-Compilation

The Go binary MUST be compiled for Linux (not macOS):

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
  -ldflags="-s -w" \
  -o dsvideo-backend \
  ./cmd/dsvideo-backend
```

- `CGO_ENABLED=0`: Static binary, no C dependencies
- `-ldflags="-s -w"`: Strip debug info for smaller binary
- Verify with `file dsvideo-backend` — should say "ELF 64-bit LSB executable"

---

## Architecture Mapping

| NAS Model | CPU | GOARCH | SPK arch field | SPK filename |
|-----------|-----|--------|----------------|--------------|
| DS923+ | AMD Ryzen R1600 | amd64 | x86_64 | *-x64.spk |
| DS920+ | Intel Celeron J4125 | amd64 | x86_64 | *-x64.spk |
| DS223 | ARM Cortex-A55 | arm64 | armv8 | *-armv8.spk |

---

## Tar Format Requirements

- SPK outer archive: **plain tar, NOT gzipped** (Synology expects this)
- Use `--format=ustar` for maximum compatibility
- INFO must be the **first entry** in the archive
- package.tgz inner archive: **gzipped tar** (standard tar.gz)

---

## Common Pitfalls

1. **Don't gzip the .spk** — it's a plain tar despite the convention
2. **INFO must be first** — Synology reads it first to determine package info
3. **conf/privilege is required** on DSM 7 — without it, installation fails
4. **Binary must be Linux ELF** — verify with `file` command after cross-compile
5. **scripts must be executable** — chmod +x all files in scripts/
6. **No trailing newlines in INFO** — some DSM versions are picky about this
7. **Empty `firmware=""` lines** — remove these, DSM doesn't like empty fields
8. **Variable expansion with `set -u`** — use `${VAR:-}` for optional env vars
9. **ui/ MUST be inside package.tgz** — `dsmuidir="ui"` looks at `target/ui/`, not the SPK root. If you only put `ui/` at the SPK root, no desktop icon appears.
10. **Database migrations: ALTER before INDEX** — If using `CREATE TABLE IF NOT EXISTS` with new columns, the table creation is skipped on upgrades. You must ALTER TABLE to add columns BEFORE creating indexes that reference those columns. Otherwise `CREATE INDEX` fails with "no such column" and `log.Fatal` kills the process.
11. **Don't use `openssl` in start scripts** — The package user's PATH may not include openssl. Use `/dev/urandom` with `od` instead: `head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'`
12. **Persist JWT secrets across restarts** — Generate once, save to a file in `var/`, and read from there on subsequent starts. Otherwise all user tokens invalidate on every restart.
13. **Portal alias requires Web Station** — The `conf/resource` portal configuration (`"type": "alias"`) only works if Web Station is installed on the NAS. Without it, nginx has no proxy rule and `/alias-path/` returns a Synology 404 page.
14. **Desktop icon URL workaround** — Since portal aliases need Web Station, use `/webman/3rdparty/PACKAGE_NAME/` as the URL in `ui/config`. This path is mapped to `target/ui/` by DSM. Put a redirect `index.html` there that uses JavaScript to redirect to port 8080: `window.location.replace('http://' + window.location.hostname + ':8080/')`.
15. **Handle portal prefix in your server** — Even if the portal works, nginx may NOT strip the alias prefix. Your server should handle both `/` and `/dsvideo/` (or whatever your alias is) to work in both direct and proxied modes.
16. **Don't use 127.0.0.1 in API responses** — If `DSVIDEO_BASE_URL` defaults to `http://127.0.0.1:PORT`, absolute URLs in API responses (like stream URLs) are unreachable from other machines. Web clients should rewrite absolute URLs from the API to use the origin they connected to (e.g., `window.location.origin + parsed.pathname`). Never trust the server's `BASE_URL` for client-facing URLs.

---

## Environment Variables (Runtime)

Set in `start-stop-status` or via DSM config:

| Variable | Default | Description |
|----------|---------|-------------|
| DSVIDEO_PORT | 8080 | HTTP listen port |
| DSVIDEO_DB_PATH | var/dsvideo.db | SQLite database path |
| DSVIDEO_JWT_SECRET | (auto-generated, persisted) | JWT signing secret (saved to var/.jwt_secret) |
| DSVIDEO_MOVIES_PATH | /volume1/video/Movies | Movies library root |
| DSVIDEO_TV_PATH | /volume1/video/Shows | TV shows library root |
| DSVIDEO_HOME_PATH | /volume1/video/Home | Home videos library root |
| DSVIDEO_FFMPEG_PATH | (auto-detect) | Path to ffmpeg binary |
| DSVIDEO_FFPROBE_PATH | (auto-detect) | Path to ffprobe binary |
| DSVIDEO_TRANSCODE_DIR | var/transcode | HLS output directory |
| DSVIDEO_TMDB_API_KEY | (none) | TMDb API key for metadata |
| DSVIDEO_IMAGE_CACHE_DIR | var/images | Poster image cache |

---

## Installation Testing

```bash
# Build the package
./build-spk-macos.sh amd64

# Copy to NAS
scp build/spk/DSVideoServer-*.spk admin@nas-ip:/tmp/

# Install via CLI (alternative to Package Center UI)
ssh admin@nas-ip
sudo synopkg install /tmp/DSVideoServer-*.spk
sudo synopkg start DSVideoServer

# Check status
sudo synopkg status DSVideoServer
cat /var/packages/DSVideoServer/var/DSVideoServer.log
```
