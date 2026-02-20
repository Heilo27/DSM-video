## DS Video clone backend (dev)

The backend service provides:

- Auth (dev token)
- Libraries + browsing
- Item details with basic local metadata (`.nfo`) and artwork discovery (`poster.jpg`, `folder.jpg`, etc.)
- Playback endpoints (HTTP range streaming; optional HLS if `ffmpeg` is available)
- Progress (“Continue Watching”)
- QuickConnect resolve (best-effort)

### Run locally

```bash
DSVIDEO_PORT=8090 \
DSVIDEO_BASE_URL=http://localhost:8090 \
DSVIDEO_JWT_SECRET=devsecret \
DSVIDEO_MOVIES_PATH="/path/to/movies" \
python3 backend/server.py
```

### Environment variables

- `DSVIDEO_HOST` (default `0.0.0.0`)
- `DSVIDEO_PORT` (default `8080`)
- `DSVIDEO_BASE_URL` (default `http://localhost:<port>`)
- `DSVIDEO_JWT_SECRET` (**change for production**)
- `DSVIDEO_DB_PATH` (default `./dsvideo.db`)
- `DSVIDEO_MOVIES_PATH` / `DSVIDEO_TV_PATH` / `DSVIDEO_HOME_PATH` (optional; enable scanning)
- `DSVIDEO_HLS_TMP` (default `/tmp`) for temporary HLS output directories when `ffmpeg` exists

