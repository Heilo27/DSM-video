# EXP: Synology DSM WebAPI Auth + File Station (inputs for DS Video clone)

Date: 2026-01-08

This document summarizes key items extracted from:

- `~/Downloads/DSM_Login_Web_API_Guide_enu.pdf`
- `~/Downloads/Synology_File_Station_API_Guide.pdf`
- `~/Downloads/DSM_Developer_Guide_7_enu.pdf` (packaging notes)

It is intentionally focused on **the minimum needed** to build our DSM 7.2.2+ “modern Video Station” SPK backend and iOS/tvOS client.

## DSM WebAPI basics

- **Base endpoint**: most examples use `GET /webapi/entry.cgi?...`
- **Discovery**: query `SYNO.API.Info` to learn the **cgi path** and supported versions for specific APIs.

Example (from DSM Login Web API guide):

- `GET https://<host>:<port>/webapi/entry.cgi?api=SYNO.API.Info&version=1&method=query`
- Query specific APIs:
  - `GET https://<host>:<port>/webapi/entry.cgi?api=SYNO.API.Info&version=1&method=query&query=SYNO.API.Auth,SYNO.FileStation.`

## Authentication: `SYNO.API.Auth` (DSM login)

The DSM Login Web API guide describes login via `SYNO.API.Auth` (commonly **version 6**).

- **Login**:
  - `GET /webapi/entry.cgi?api=SYNO.API.Auth&version=6&method=login&account=<USERNAME>&passwd=<PASSWORD>`
  - Successful response includes:
    - **`sid`**: session id (useful as `_sid=<sid>` if not using cookies)
    - **`synotoken`** (aka `SynoToken`): required for CSRF protection when enabled
- **Calling subsequent APIs**:
  - Either use cookies, or pass `&_sid=<sid>`
  - If `synotoken` is returned, pass `&SynoToken=<synotoken>` to subsequent API calls.
  - Example shown:
    - `GET /webapi/entry.cgi?api=SYNO.FileStation.List&version=1&method=list_share&SynoToken=<token>`
- **Logout**:
  - `GET /webapi/entry.cgi?api=SYNO.API.Auth&version=6&method=logout`
  - If not using cookies: `...&method=logout&_sid=<sid>`
- **Token refresh**:
  - Guide shows: `GET /webapi/entry.cgi?api=SYNO.API.Auth&version=6&method=token`

Notes:
- The guide lists common error codes such as `107` (session interrupted by duplicated login) and mentions IP mismatch errors.
- For our backend, we’ll treat DSM login as an upstream auth mechanism when we need to access DSM-provided WebAPIs (e.g., File Station). For our own API, we will issue our own JWT/session token to the client.

## File Station APIs (for storage access)

The File Station API guide enumerates key APIs we can rely on if we choose to interact with DSM’s file layer rather than raw filesystem access:

- `SYNO.FileStation.Info`
- `SYNO.FileStation.List`:
  - `list_share`: list shares
  - `list`: list files in a folder
  - `getinfo`: detailed file info; supports `additional=real_path,owner,time,perm` etc.
- `SYNO.FileStation.Search` (non-blocking `start` + `list` polling)
- `SYNO.FileStation.Thumb` (thumbnails)
- `SYNO.FileStation.Download` (download file/folder; single file returns content)

Important detail from the guide:
- Thumbnails for videos are limited (note states video thumbnails exist only if files are in the `photo` share or users’ home folders). For a media library, we should not rely on this and instead generate/cached artwork ourselves.

## DSM 7 package/SPK notes (Package Developer Guide)

From the DSM Package Developer Guide excerpts:

- **DSM 7 breaking changes**: package framework and Package Center behavior differs from DSM6.
- **Lower privilege**: packages should run as a *package user* (not root).
- **Signing**: DSM7 removed the old SPK signing mechanism; unsigned packages install with warnings.
- **Directories**:
  - Package home: `/var/packages/<package_name>/home`
  - Logs:
    - `/var/log/synopkg.log`
    - `/var/log/packages/<package_name>.log`
- **Lifecycle**: Package Center drives scripts via `synopkg` (`install`, `start`, `stop`, `uninstall`).
- **Tooling/examples**:
  - `pkgscripts-ng` (`PkgCreate.py`)
  - `ExamplePackages` templates (SynologyOpenSource)

For our backend we will:

- Package a **single self-contained backend service** (preferably one binary + config templates).
- Run as the package user.
- Expose an HTTP server on a configurable port (TLS optional).

## How we’ll apply this

- **Client login (QuickConnect)**: the app resolves endpoint(s) then authenticates to our backend; backend may optionally use DSM WebAPI for admin-only storage tasks.
- **Backend indexing**: prefer direct filesystem access to configured share paths; optionally support DSM WebAPI (File Station) as a fallback.
- **Streaming**: implement HTTP range streaming + HLS generation instead of relying on File Station `Download`.
