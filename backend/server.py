#!/usr/bin/env python3

"""
DS Video clone backend (dev implementation)

This is a developer-friendly HTTP JSON service intended to be packaged into a
Synology SPK later. It uses only Python stdlib at runtime.
"""

from __future__ import annotations

import base64
import dataclasses
import datetime as dt
import hashlib
import hmac
import json
import os
import re
import shutil
import sqlite3
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, urlparse


def _utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def _b64url_encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def _b64url_decode(s: str) -> bytes:
    padding = "=" * ((4 - (len(s) % 4)) % 4)
    return base64.urlsafe_b64decode((s + padding).encode("ascii"))


def _json_bytes(obj: Any) -> bytes:
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def _read_json(handler: BaseHTTPRequestHandler) -> Any:
    length = int(handler.headers.get("Content-Length", "0"))
    raw = handler.rfile.read(length) if length > 0 else b"{}"
    return json.loads(raw.decode("utf-8"))


def _write_json(handler: BaseHTTPRequestHandler, status: int, obj: Any) -> None:
    raw = _json_bytes(obj) + b"\n"
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(raw)))
    handler.end_headers()
    handler.wfile.write(raw)


def _write_error(handler: BaseHTTPRequestHandler, status: int, code: str) -> None:
    _write_json(handler, status, {"error": code})


def _parse_int(s: Optional[str], default: int) -> int:
    if s is None:
        return default
    try:
        return int(s)
    except ValueError:
        return default


def _clamp(v: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, v))


def _sanitize_id(s: str) -> str:
    s = s.strip().lower()
    s = re.sub(r"[^a-z0-9]+", "_", s)
    return s.strip("_") or "user"


def _title_from_filename(name: str) -> str:
    base = Path(name).stem
    base = base.replace(".", " ").replace("_", " ").strip()
    return base or "Untitled"


def _is_path_within_allowed(path: str, allowed_roots: List[str]) -> bool:
    """
    Security check: verify a path is within one of the allowed root directories.
    Prevents path traversal attacks via symlinks or malicious database entries.
    """
    if not allowed_roots:
        return False
    try:
        resolved = Path(path).resolve()
        for root in allowed_roots:
            if not root:
                continue
            root_resolved = Path(root).expanduser().resolve()
            # Check if path starts with allowed root (is a subdirectory)
            try:
                resolved.relative_to(root_resolved)
                return True
            except ValueError:
                continue
        return False
    except (OSError, ValueError):
        return False


def _item_id_from_path(p: str) -> str:
    # Deterministic stable id. (Not security-sensitive.)
    digest = hashlib.sha256(os.path.normpath(p).encode("utf-8")).hexdigest()
    return f"it_{digest}"


@dataclasses.dataclass(frozen=True)
class Config:
    listen_host: str
    listen_port: int
    base_url: str
    jwt_secret: str
    db_path: str
    movies_path: str
    tv_path: str
    home_path: str

    @staticmethod
    def load() -> "Config":
        def get(key: str, default: str) -> str:
            v = os.environ.get(key, "").strip()
            return v if v else default

        host = get("DSVIDEO_HOST", "0.0.0.0")
        port = _parse_int(get("DSVIDEO_PORT", "8080"), 8080)
        base_url = get("DSVIDEO_BASE_URL", f"http://localhost:{port}")

        # JWT secret handling: require env var or generate secure random
        jwt_secret = os.environ.get("DSVIDEO_JWT_SECRET", "").strip()
        jwt_secret_generated = False
        if not jwt_secret:
            # Generate a cryptographically secure random secret
            jwt_secret = base64.urlsafe_b64encode(os.urandom(32)).decode("ascii")
            jwt_secret_generated = True

        cfg = Config(
            listen_host=host,
            listen_port=port,
            base_url=base_url.rstrip("/"),
            jwt_secret=jwt_secret,
            db_path=get("DSVIDEO_DB_PATH", "./dsvideo.db"),
            movies_path=get("DSVIDEO_MOVIES_PATH", ""),
            tv_path=get("DSVIDEO_TV_PATH", ""),
            home_path=get("DSVIDEO_HOME_PATH", ""),
        )

        if jwt_secret_generated:
            print("⚠️  DSVIDEO_JWT_SECRET not set - using generated random secret.")
            print("   Sessions will not persist across server restarts.")
            print("   Set DSVIDEO_JWT_SECRET env var for persistent sessions.")

        return cfg


class Store:
    def __init__(self, db_path: str) -> None:
        self._db = sqlite3.connect(db_path, check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._lock = threading.Lock()
        self._migrate()

    def _migrate(self) -> None:
        with self._db:
            self._db.executescript(
                """
                CREATE TABLE IF NOT EXISTS items (
                  id TEXT PRIMARY KEY,
                  library_id TEXT NOT NULL,
                  type TEXT NOT NULL,
                  title TEXT NOT NULL,
                  year INTEGER,
                  summary TEXT,
                  cast_json TEXT,
                  path TEXT NOT NULL,
                  duration_seconds INTEGER,
                  poster_image_id TEXT,
                  backdrop_image_id TEXT,
                  added_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_items_library_added ON items(library_id, added_at);

                CREATE TABLE IF NOT EXISTS images (
                  id TEXT PRIMARY KEY,
                  kind TEXT NOT NULL,
                  mime TEXT NOT NULL,
                  path TEXT NOT NULL,
                  added_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS progress (
                  item_id TEXT NOT NULL,
                  user_id TEXT NOT NULL,
                  position_seconds INTEGER NOT NULL,
                  duration_seconds INTEGER NOT NULL,
                  updated_at TEXT NOT NULL,
                  PRIMARY KEY (item_id, user_id)
                );

                CREATE TABLE IF NOT EXISTS pairing_codes (
                  code TEXT PRIMARY KEY,
                  user_id TEXT NOT NULL,
                  username TEXT NOT NULL,
                  expires_at TEXT NOT NULL,
                  created_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_pairing_expires ON pairing_codes(expires_at);
                """
            )
            # Handle upgrades from earlier dev schemas (SQLite doesn't modify existing tables on CREATE IF NOT EXISTS).
            self._ensure_column("items", "summary", "TEXT")
            self._ensure_column("items", "cast_json", "TEXT")
            self._ensure_column("items", "poster_image_id", "TEXT")
            self._ensure_column("items", "backdrop_image_id", "TEXT")
            self._ensure_column("items", "show_id",        "TEXT")
            self._ensure_column("items", "show_title",      "TEXT")
            self._ensure_column("items", "season_number",   "INTEGER")
            self._ensure_column("items", "episode_number",  "INTEGER")

    def _ensure_column(self, table: str, col: str, col_type: str) -> None:
        existing = {r["name"] for r in self._db.execute(f"PRAGMA table_info({table})").fetchall()}
        if col in existing:
            return
        self._db.execute(f"ALTER TABLE {table} ADD COLUMN {col} {col_type}")

    def upsert_item(
        self,
        item_id: str,
        library_id: str,
        item_type: str,
        title: str,
        path: str,
        added_at: str,
        summary: Optional[str],
        cast_json: Optional[str],
        poster_image_id: Optional[str],
        backdrop_image_id: Optional[str],
        year: Optional[int] = None,
        duration_seconds: Optional[int] = None,
        show_id: Optional[str] = None,
        show_title: Optional[str] = None,
        season_number: Optional[int] = None,
        episode_number: Optional[int] = None,
    ) -> None:
        now = _utc_now_iso()
        with self._lock, self._db:
            self._db.execute(
                """
                INSERT INTO items(
                  id, library_id, type, title, year, summary, path, duration_seconds,
                  cast_json,
                  poster_image_id, backdrop_image_id,
                  show_id, show_title, season_number, episode_number,
                  added_at, updated_at
                )
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  library_id=excluded.library_id,
                  type=excluded.type,
                  title=excluded.title,
                  year=excluded.year,
                  summary=excluded.summary,
                  cast_json=excluded.cast_json,
                  path=excluded.path,
                  duration_seconds=excluded.duration_seconds,
                  poster_image_id=excluded.poster_image_id,
                  backdrop_image_id=excluded.backdrop_image_id,
                  show_id=excluded.show_id,
                  show_title=excluded.show_title,
                  season_number=excluded.season_number,
                  episode_number=excluded.episode_number,
                  added_at=excluded.added_at,
                  updated_at=excluded.updated_at
                """,
                (
                    item_id,
                    library_id,
                    item_type,
                    title,
                    year,
                    summary,
                    path,
                    duration_seconds,
                    cast_json,
                    poster_image_id,
                    backdrop_image_id,
                    show_id,
                    show_title,
                    season_number,
                    episode_number,
                    added_at,
                    now,
                ),
            )

    def upsert_image(self, image_id: str, kind: str, mime: str, path: str) -> None:
        with self._lock, self._db:
            self._db.execute(
                """
                INSERT INTO images(id, kind, mime, path, added_at)
                VALUES(?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, mime=excluded.mime, path=excluded.path
                """,
                (image_id, kind, mime, path, _utc_now_iso()),
            )

    def get_items(
        self, library_id: Optional[str], limit: int, offset: int
    ) -> Tuple[int, List[Dict[str, Any]]]:
        where = ""
        args: List[Any] = []
        if library_id:
            where = "WHERE library_id = ?"
            args.append(library_id)

        with self._lock:
            total = self._db.execute(f"SELECT COUNT(*) FROM items {where}", args).fetchone()[0]
            rows = self._db.execute(
                f"""
                SELECT id, type, title, year, duration_seconds, added_at, poster_image_id, backdrop_image_id
                FROM items {where}
                ORDER BY added_at DESC
                LIMIT ? OFFSET ?
                """,
                (*args, limit, offset),
            ).fetchall()

        items: List[Dict[str, Any]] = []
        for r in rows:
            items.append(
                {
                    "id": r["id"],
                    "type": r["type"],
                    "title": r["title"],
                    "year": r["year"],
                    "durationSeconds": r["duration_seconds"],
                    "addedAt": r["added_at"],
                    "rating": None,
                    "posterImageId": r["poster_image_id"],
                    "backdropImageId": r["backdrop_image_id"],
                }
            )
        return int(total), items

    def get_library_summaries(self) -> List[Dict[str, Any]]:
        """Returns count and latest updated_at per library in a single query.
        Used by the iOS client to detect library changes without fetching all items.
        """
        with self._lock:
            rows = self._db.execute(
                """
                SELECT library_id, COUNT(*) as count, MAX(updated_at) as last_updated_at
                FROM items
                GROUP BY library_id
                """
            ).fetchall()
        return [
            {
                "libraryId": r["library_id"],
                "count": r["count"],
                "lastUpdatedAt": r["last_updated_at"],
            }
            for r in rows
        ]

    def search_items(
        self, query: str, limit: int, offset: int
    ) -> Tuple[int, List[Dict[str, Any]]]:
        """Search items by title (case-insensitive substring match)."""
        search_pattern = f"%{query}%"
        with self._lock:
            total = self._db.execute(
                "SELECT COUNT(*) FROM items WHERE title LIKE ? COLLATE NOCASE",
                (search_pattern,),
            ).fetchone()[0]
            rows = self._db.execute(
                """
                SELECT id, type, title, year, duration_seconds, added_at, poster_image_id, backdrop_image_id
                FROM items
                WHERE title LIKE ? COLLATE NOCASE
                ORDER BY title ASC
                LIMIT ? OFFSET ?
                """,
                (search_pattern, limit, offset),
            ).fetchall()

        items: List[Dict[str, Any]] = []
        for r in rows:
            items.append(
                {
                    "id": r["id"],
                    "type": r["type"],
                    "title": r["title"],
                    "year": r["year"],
                    "durationSeconds": r["duration_seconds"],
                    "addedAt": r["added_at"],
                    "rating": None,
                    "posterImageId": r["poster_image_id"],
                    "backdropImageId": r["backdrop_image_id"],
                }
            )
        return int(total), items

    def get_item_path(self, item_id: str) -> Optional[str]:
        with self._lock:
            row = self._db.execute("SELECT path FROM items WHERE id = ?", (item_id,)).fetchone()
        return str(row["path"]) if row else None

    def get_item_detail(self, item_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            row = self._db.execute(
                "SELECT id, type, title, year, summary, cast_json, duration_seconds, poster_image_id, backdrop_image_id FROM items WHERE id = ?",
                (item_id,),
            ).fetchone()
        if not row:
            return None
        cast = []
        try:
            if row["cast_json"]:
                cast = json.loads(row["cast_json"])
        except Exception:
            cast = []
        return {
            "id": row["id"],
            "type": row["type"],
            "title": row["title"],
            "originalTitle": None,
            "year": row["year"],
            "durationSeconds": row["duration_seconds"],
            "contentRating": None,
            "summary": row["summary"],
            "genres": [],
            "cast": cast,
            "images": {"poster": {"id": row["poster_image_id"]}, "backdrop": {"id": row["backdrop_image_id"]}},
        }

    def get_image(self, image_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            row = self._db.execute("SELECT id, kind, mime, path FROM images WHERE id = ?", (image_id,)).fetchone()
        if not row:
            return None
        return {"id": row["id"], "kind": row["kind"], "mime": row["mime"], "path": row["path"]}

    def upsert_progress(
        self, user_id: str, item_id: str, position_seconds: int, duration_seconds: int
    ) -> None:
        now = _utc_now_iso()
        with self._lock, self._db:
            self._db.execute(
                """
                INSERT INTO progress(item_id, user_id, position_seconds, duration_seconds, updated_at)
                VALUES(?,?,?,?,?)
                ON CONFLICT(item_id, user_id) DO UPDATE SET
                  position_seconds=excluded.position_seconds,
                  duration_seconds=excluded.duration_seconds,
                  updated_at=excluded.updated_at
                """,
                (item_id, user_id, position_seconds, duration_seconds, now),
            )

    def get_progress(self, user_id: str, item_id: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            row = self._db.execute(
                "SELECT position_seconds, duration_seconds, updated_at FROM progress WHERE user_id = ? AND item_id = ?",
                (user_id, item_id),
            ).fetchone()
        if not row:
            return None
        return {
            "positionSeconds": int(row["position_seconds"]),
            "durationSeconds": int(row["duration_seconds"]),
            "updatedAt": str(row["updated_at"]),
        }

    def get_progress_batch(self, user_id: str, item_ids: List[str]) -> Dict[str, Dict[str, Any]]:
        """Fetch progress for multiple items in a single query."""
        if not item_ids:
            return {}
        placeholders = ",".join("?" * len(item_ids))
        with self._lock:
            rows = self._db.execute(
                f"SELECT item_id, position_seconds, duration_seconds, updated_at FROM progress WHERE user_id = ? AND item_id IN ({placeholders})",
                (user_id, *item_ids),
            ).fetchall()
        return {
            row["item_id"]: {
                "positionSeconds": int(row["position_seconds"]),
                "durationSeconds": int(row["duration_seconds"]),
                "updatedAt": str(row["updated_at"]),
            }
            for row in rows
        }

    def create_pairing_code(self, code: str, user_id: str, username: str, expires_at: str) -> None:
        now = _utc_now_iso()
        with self._lock, self._db:
            self._db.execute(
                """
                INSERT INTO pairing_codes(code, user_id, username, expires_at, created_at)
                VALUES(?,?,?,?,?)
                """,
                (code, user_id, username, expires_at, now),
            )

    def get_pairing_code(self, code: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            row = self._db.execute(
                "SELECT code, user_id, username, expires_at FROM pairing_codes WHERE code = ?",
                (code,),
            ).fetchone()
        if not row:
            return None
        return {
            "code": row["code"],
            "userId": row["user_id"],
            "username": row["username"],
            "expiresAt": row["expires_at"],
        }

    def delete_pairing_code(self, code: str) -> None:
        with self._lock, self._db:
            self._db.execute("DELETE FROM pairing_codes WHERE code = ?", (code,))

    def cleanup_expired_pairing_codes(self) -> None:
        now = _utc_now_iso()
        with self._lock, self._db:
            self._db.execute("DELETE FROM pairing_codes WHERE expires_at < ?", (now,))


@dataclasses.dataclass
class PlaybackSession:
    item_id: str
    path: str
    kind: str  # direct|hls
    created_at: float
    hls_dir: Optional[str] = None


class App:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.store = Store(cfg.db_path)
        self.playback_sessions: Dict[str, PlaybackSession] = {}
        self._pb_lock = threading.Lock()
        self.last_scan_at: float = 0.0

    def issue_token(self, user_id: str, username: str) -> str:
        payload = {
            "sub": user_id,
            "usr": username,
            "iat": int(time.time()),
            "exp": int(time.time() + 30 * 24 * 3600),
        }
        payload_b64 = _b64url_encode(_json_bytes(payload))
        sig = hmac.new(self.cfg.jwt_secret.encode("utf-8"), payload_b64.encode("ascii"), hashlib.sha256).digest()
        return payload_b64 + "." + _b64url_encode(sig)

    def verify_token(self, token: str) -> Optional[Dict[str, Any]]:
        try:
            payload_b64, sig_b64 = token.split(".", 1)
            expected = hmac.new(
                self.cfg.jwt_secret.encode("utf-8"), payload_b64.encode("ascii"), hashlib.sha256
            ).digest()
            if not hmac.compare_digest(expected, _b64url_decode(sig_b64)):
                return None
            payload = json.loads(_b64url_decode(payload_b64).decode("utf-8"))
            if int(payload.get("exp", 0)) < int(time.time()):
                return None
            return payload
        except Exception:
            return None

    def configured_libraries(self) -> List[Dict[str, Any]]:
        libs: List[Dict[str, Any]] = [
            {"id": "lib_movies", "title": "Movies", "kind": "movies"},
            {"id": "lib_tv", "title": "TV Shows", "kind": "tv"},
            {"id": "lib_home", "title": "Home Videos", "kind": "home"},
        ]
        return libs

    def scan_all(self) -> None:
        libs = [
            ("lib_movies", "movies", self.cfg.movies_path),
            ("lib_tv", "tv", self.cfg.tv_path),
            ("lib_home", "home", self.cfg.home_path),
        ]
        exts = {".mp4", ".m4v", ".mov", ".mkv", ".avi", ".ts"}
        for lib_id, kind, root in libs:
            if not root:
                continue
            root_path = Path(root).expanduser().resolve()
            if not root_path.exists():
                continue
            for p in root_path.rglob("*"):
                if not p.is_file():
                    continue
                if p.suffix.lower() not in exts:
                    continue
                item_type = "video"
                if kind == "movies":
                    item_type = "movie"
                elif kind == "tv":
                    item_type = "episode"
                elif kind == "home":
                    item_type = "homeVideo"

                item_id = _item_id_from_path(str(p))
                title = _title_from_filename(p.name)
                summary, cast_json = _try_parse_nfo(p)
                poster_id, backdrop_id = _discover_artwork(self.store, p)
                added_at = dt.datetime.fromtimestamp(p.stat().st_mtime, tz=dt.timezone.utc).isoformat().replace(
                    "+00:00", "Z"
                )

                show_id: Optional[str] = None
                show_title: Optional[str] = None
                season_number: Optional[int] = None
                episode_number: Optional[int] = None
                if kind == "tv":
                    show_id, show_title, season_number, episode_number = _parse_tv_metadata(p, root_path)

                self.store.upsert_item(
                    item_id=item_id,
                    library_id=lib_id,
                    item_type=item_type,
                    title=title,
                    path=str(p),
                    added_at=added_at,
                    summary=summary,
                    cast_json=cast_json,
                    poster_image_id=poster_id,
                    backdrop_image_id=backdrop_id,
                    year=None,
                    duration_seconds=None,
                    show_id=show_id,
                    show_title=show_title,
                    season_number=season_number,
                    episode_number=episode_number,
                )
        self.last_scan_at = time.time()

    def create_playback_session(self, item_id: str, path: str) -> Tuple[str, PlaybackSession]:
        ext = Path(path).suffix.lower()
        wants_hls = ext not in {".mp4", ".m4v", ".mov"}
        hls_available = shutil.which("ffmpeg") is not None
        kind = "hls" if wants_hls and hls_available else "direct"
        sid = "sess_" + base64.urlsafe_b64encode(os.urandom(12)).rstrip(b"=").decode("ascii")
        hls_dir: Optional[str] = None
        if kind == "hls":
            hls_dir = str(Path(os.environ.get("DSVIDEO_HLS_TMP", "/tmp")).joinpath(f"dsvideo_hls_{sid}"))
            Path(hls_dir).mkdir(parents=True, exist_ok=True)
        sess = PlaybackSession(item_id=item_id, path=path, kind=kind, created_at=time.time(), hls_dir=hls_dir)
        with self._pb_lock:
            self.playback_sessions[sid] = sess

        if kind == "hls" and hls_dir:
            threading.Thread(target=_generate_hls, args=(path, hls_dir), daemon=True).start()

        return sid, sess

    def get_playback_session(self, sid: str) -> Optional[PlaybackSession]:
        with self._pb_lock:
            return self.playback_sessions.get(sid)

    def generate_pairing_code(self, user_id: str, username: str) -> str:
        """Generate a 6-digit pairing code valid for 10 minutes."""
        code = "".join(str(os.urandom(1)[0] % 10) for _ in range(6))
        expires_at = dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=10)
        self.store.create_pairing_code(code, user_id, username, expires_at.isoformat().replace("+00:00", "Z"))
        # Cleanup expired codes periodically
        if int(time.time()) % 60 < 5:  # Roughly once per minute
            self.store.cleanup_expired_pairing_codes()
        return code

    def exchange_pairing_code(self, code: str) -> Optional[Dict[str, Any]]:
        """Exchange pairing code for user info. Returns None if invalid/expired."""
        pairing = self.store.get_pairing_code(code)
        if not pairing:
            return None
        expires = dt.datetime.fromisoformat(pairing["expiresAt"].replace("Z", "+00:00"))
        if expires < dt.datetime.now(dt.timezone.utc):
            self.store.delete_pairing_code(code)
            return None
        # Code is valid; delete it (single-use)
        self.store.delete_pairing_code(code)
        return {"userId": pairing["userId"], "username": pairing["username"]}


class Handler(BaseHTTPRequestHandler):
    server_version = "DSVideoBackend/0.1"

    def do_GET(self) -> None:  # noqa: N802
        self._dispatch()

    def do_POST(self) -> None:  # noqa: N802
        self._dispatch()

    def log_message(self, fmt: str, *args: Any) -> None:
        # Quiet default logs; keep one-line.
        print(f"{self.command} {self.path} - {fmt % args}")

    @property
    def app(self) -> App:
        # ThreadingHTTPServer sets this attribute.
        return self.server.app  # type: ignore[attr-defined]

    def _dispatch(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path

        # API routing
        if not path.startswith("/api/v1/"):
            _write_error(self, HTTPStatus.NOT_FOUND, "not_found")
            return

        # Public endpoints
        if path == "/api/v1/auth/quickconnect/resolve" and self.command == "POST":
            return self._qc_resolve()
        if path == "/api/v1/auth/login" and self.command == "POST":
            return self._login()
        if path == "/api/v1/auth/logout" and self.command == "POST":
            return _write_json(self, HTTPStatus.OK, {"ok": True})
        if path == "/api/v1/auth/pairing/generate" and self.command == "POST":
            return self._generate_pairing_code()
        if path == "/api/v1/auth/pairing/exchange" and self.command == "POST":
            return self._exchange_pairing_code()

        user = self._require_auth()
        if user is None:
            return

        # Authenticated endpoints
        if path == "/api/v1/libraries" and self.command == "GET":
            return _write_json(self, HTTPStatus.OK, {"libraries": self.app.configured_libraries()})

        # Lightweight summary: count + lastUpdatedAt per library in one DB query.
        # Used by the iOS client to detect changes without fetching all items.
        if path == "/api/v1/libraries/summary" and self.command == "GET":
            return _write_json(self, HTTPStatus.OK, {"libraries": self.app.store.get_library_summaries()})

        if path == "/api/v1/items" and self.command == "GET":
            qs = parse_qs(parsed.query)
            library_id = (qs.get("libraryId") or [None])[0]
            limit = _clamp(_parse_int((qs.get("limit") or [None])[0], 50), 1, 200)
            offset = _clamp(_parse_int((qs.get("offset") or [None])[0], 0), 0, 1_000_000)
            total, items = self.app.store.get_items(library_id, limit, offset)
            # Attach progress for this user (batch fetch for efficiency)
            item_ids = [it["id"] for it in items]
            progress_map = self.app.store.get_progress_batch(user["sub"], item_ids)
            for it in items:
                prog = progress_map.get(it["id"])
                if prog:
                    it["progress"] = prog
            return _write_json(self, HTTPStatus.OK, {"total": total, "items": items})

        if path == "/api/v1/search" and self.command == "GET":
            qs = parse_qs(parsed.query)
            query = (qs.get("q") or [""])[0].strip()
            if not query:
                return _write_json(self, HTTPStatus.OK, {"total": 0, "items": []})
            limit = _clamp(_parse_int((qs.get("limit") or [None])[0], 50), 1, 200)
            offset = _clamp(_parse_int((qs.get("offset") or [None])[0], 0), 0, 1_000_000)
            total, items = self.app.store.search_items(query, limit, offset)
            # Attach progress for this user
            item_ids = [it["id"] for it in items]
            progress_map = self.app.store.get_progress_batch(user["sub"], item_ids)
            for it in items:
                prog = progress_map.get(it["id"])
                if prog:
                    it["progress"] = prog
            return _write_json(self, HTTPStatus.OK, {"total": total, "items": items})

        m = re.fullmatch(r"/api/v1/items/([^/]+)", path)
        if m and self.command == "GET":
            item_id = m.group(1)
            detail = self.app.store.get_item_detail(item_id)
            if not detail:
                return _write_error(self, HTTPStatus.NOT_FOUND, "not_found")
            return _write_json(self, HTTPStatus.OK, detail)

        m = re.fullmatch(r"/api/v1/images/([^/]+)", path)
        if m and self.command == "GET":
            image_id = m.group(1)
            img = self.app.store.get_image(image_id)
            if not img:
                return _write_error(self, HTTPStatus.NOT_FOUND, "not_found")
            return self._serve_image(img)

        m = re.fullmatch(r"/api/v1/items/([^/]+)/playback", path)
        if m and self.command == "GET":
            item_id = m.group(1)
            fpath = self.app.store.get_item_path(item_id)
            if not fpath:
                return _write_error(self, HTTPStatus.NOT_FOUND, "not_found")
            sid, sess = self.app.create_playback_session(item_id, fpath)
            prog = self.app.store.get_progress(user["sub"], item_id)
            resume = int(prog["positionSeconds"]) if prog else 0
            if sess.kind == "direct":
                return _write_json(
                    self,
                    HTTPStatus.OK,
                    {
                        "kind": "direct",
                        "streamUrl": f"{self.app.cfg.base_url}/api/v1/playback/{sid}/stream",
                        "subtitles": [],
                        "audioTracks": [],
                        "resumePositionSeconds": resume,
                    },
                )
            # HLS not generated in dev env unless ffmpeg exists; client can fall back to /stream.
            return _write_json(
                self,
                HTTPStatus.OK,
                {
                    "kind": "hls",
                    "hlsMasterUrl": f"{self.app.cfg.base_url}/api/v1/playback/{sid}/master.m3u8",
                    "subtitles": [],
                    "audioTracks": [],
                    "resumePositionSeconds": resume,
                },
            )

        if path == "/api/v1/progress" and self.command == "GET":
            qs = parse_qs(parsed.query)
            raw_ids = (qs.get("ids") or [""])[0]
            item_ids = [i for i in raw_ids.split(",") if i][:500]
            result = self.app.store.get_progress_batch(user["sub"], item_ids) if item_ids else {}
            return _write_json(self, HTTPStatus.OK, {"progress": result})

        m = re.fullmatch(r"/api/v1/items/([^/]+)/progress", path)
        if m and self.command == "POST":
            item_id = m.group(1)
            data = _read_json(self)
            pos = int(data.get("positionSeconds", -1))
            dur = int(data.get("durationSeconds", -1))
            if pos < 0 or dur <= 0:
                return _write_error(self, HTTPStatus.BAD_REQUEST, "invalid_progress")
            self.app.store.upsert_progress(user["sub"], item_id, pos, dur)
            return _write_json(self, HTTPStatus.OK, {"ok": True})

        m = re.fullmatch(r"/api/v1/playback/([^/]+)/stream", path)
        if m and self.command == "GET":
            sid = m.group(1)
            sess = self.app.get_playback_session(sid)
            if not sess:
                return _write_error(self, HTTPStatus.NOT_FOUND, "not_found")
            return self._serve_range_file(sess.path)

        # HLS (dev stub)
        m = re.fullmatch(r"/api/v1/playback/([^/]+)/master\.m3u8", path)
        if m and self.command == "GET":
            sid = m.group(1)
            sess = self.app.get_playback_session(sid)
            if not sess or sess.kind != "hls" or not sess.hls_dir:
                return _write_error(self, HTTPStatus.NOT_FOUND, "not_found")
            master = Path(sess.hls_dir) / "master.m3u8"
            if not master.exists():
                return _write_error(self, HTTPStatus.NOT_FOUND, "hls_not_ready")
            return self._serve_static_file(master, "application/vnd.apple.mpegurl")

        m = re.fullmatch(r"/api/v1/playback/([^/]+)/([^/]+)\.m3u8", path)
        if m and self.command == "GET":
            sid, variant = m.group(1), m.group(2)
            sess = self.app.get_playback_session(sid)
            if not sess or sess.kind != "hls" or not sess.hls_dir:
                return _write_error(self, HTTPStatus.NOT_FOUND, "not_found")
            f = Path(sess.hls_dir) / f"{variant}.m3u8"
            if not f.exists():
                return _write_error(self, HTTPStatus.NOT_FOUND, "not_found")
            return self._serve_static_file(f, "application/vnd.apple.mpegurl")

        m = re.fullmatch(r"/api/v1/playback/([^/]+)/segments/([^/]+)", path)
        if m and self.command == "GET":
            sid, name = m.group(1), m.group(2)
            if ".." in name or "/" in name or "\\" in name:
                return _write_error(self, HTTPStatus.BAD_REQUEST, "invalid_segment")
            sess = self.app.get_playback_session(sid)
            if not sess or sess.kind != "hls" or not sess.hls_dir:
                return _write_error(self, HTTPStatus.NOT_FOUND, "not_found")
            f = Path(sess.hls_dir) / name
            if not f.exists():
                return _write_error(self, HTTPStatus.NOT_FOUND, "not_found")
            return self._serve_static_file(f, "video/MP2T")

        if path == "/api/v1/admin/status" and self.command == "GET":
            return _write_json(
                self,
                HTTPStatus.OK,
                {
                    "ok": True,
                    "version": "0.1.0-dev",
                    "baseUrl": self.app.cfg.base_url,
                    "dbPath": self.app.cfg.db_path,
                    "libraries": [
                        {"id": "lib_movies", "path": self.app.cfg.movies_path},
                        {"id": "lib_tv", "path": self.app.cfg.tv_path},
                        {"id": "lib_home", "path": self.app.cfg.home_path},
                    ],
                    "lastScanAt": dt.datetime.fromtimestamp(self.app.last_scan_at, tz=dt.timezone.utc)
                    .isoformat()
                    .replace("+00:00", "Z")
                    if self.app.last_scan_at
                    else None,
                    "playbackSessions": len(self.app.playback_sessions),
                },
            )

        if path == "/api/v1/admin/scan" and self.command == "POST":
            threading.Thread(target=self.app.scan_all, daemon=True).start()
            return _write_json(self, HTTPStatus.ACCEPTED, {"ok": True})

        # --- TV endpoints ---

        if path == "/api/v1/tv/shows" and self.command == "GET":
            qs = parse_qs(parsed.query)
            library_id = (qs.get("libraryId") or ["lib_tv"])[0]
            with self.app.store._lock:
                rows = self.app.store._db.execute(
                    """
                    SELECT show_id, show_title,
                           MIN(year) as year,
                           COUNT(DISTINCT CASE WHEN season_number IS NOT NULL THEN season_number END) as season_count,
                           COUNT(*) as episode_count,
                           MAX(poster_image_id) as poster_image_id
                    FROM items
                    WHERE library_id = ? AND show_id IS NOT NULL
                    GROUP BY show_id
                    ORDER BY show_title ASC
                    """,
                    (library_id,),
                ).fetchall()
            shows = [
                {
                    "id": r["show_id"],
                    "title": r["show_title"],
                    "year": r["year"],
                    "seasonCount": r["season_count"],
                    "episodeCount": r["episode_count"],
                    "posterImageId": r["poster_image_id"],
                }
                for r in rows
            ]
            return _write_json(self, HTTPStatus.OK, {"shows": shows})

        m = re.fullmatch(r"/api/v1/tv/shows/([^/]+)/seasons", path)
        if m and self.command == "GET":
            show_id = m.group(1)
            qs = parse_qs(parsed.query)
            library_id = (qs.get("libraryId") or ["lib_tv"])[0]
            with self.app.store._lock:
                rows = self.app.store._db.execute(
                    """
                    SELECT season_number, COUNT(*) as episode_count
                    FROM items
                    WHERE library_id = ? AND show_id = ? AND season_number IS NOT NULL
                    GROUP BY season_number
                    ORDER BY season_number ASC
                    """,
                    (library_id, show_id),
                ).fetchall()
            seasons = [
                {"seasonNumber": r["season_number"], "episodeCount": r["episode_count"]}
                for r in rows
            ]
            return _write_json(self, HTTPStatus.OK, {"seasons": seasons})

        m = re.fullmatch(r"/api/v1/tv/shows/([^/]+)/episodes", path)
        if m and self.command == "GET":
            show_id = m.group(1)
            qs = parse_qs(parsed.query)
            library_id = (qs.get("libraryId") or ["lib_tv"])[0]
            season_str = (qs.get("season") or [None])[0]
            if season_str is None:
                return _write_error(self, HTTPStatus.BAD_REQUEST, "missing_season")
            season = _parse_int(season_str, -1)
            if season < 0:
                return _write_error(self, HTTPStatus.BAD_REQUEST, "invalid_season")
            with self.app.store._lock:
                rows = self.app.store._db.execute(
                    """
                    SELECT id, type, title, year, duration_seconds, added_at,
                           poster_image_id, backdrop_image_id,
                           season_number, episode_number
                    FROM items
                    WHERE library_id = ? AND show_id = ? AND season_number = ?
                    ORDER BY episode_number ASC
                    """,
                    (library_id, show_id, season),
                ).fetchall()
            items: List[Dict[str, Any]] = []
            for r in rows:
                items.append(
                    {
                        "id": r["id"],
                        "type": r["type"],
                        "title": r["title"],
                        "year": r["year"],
                        "durationSeconds": r["duration_seconds"],
                        "addedAt": r["added_at"],
                        "rating": None,
                        "posterImageId": r["poster_image_id"],
                        "backdropImageId": r["backdrop_image_id"],
                        "seasonNumber": r["season_number"],
                        "episodeNumber": r["episode_number"],
                    }
                )
            # Attach progress
            item_ids = [it["id"] for it in items]
            progress_map = self.app.store.get_progress_batch(user["sub"], item_ids)
            for it in items:
                prog = progress_map.get(it["id"])
                if prog:
                    it["progress"] = prog
            return _write_json(self, HTTPStatus.OK, {"total": len(items), "items": items})

        _write_error(self, HTTPStatus.NOT_FOUND, "not_found")

    def _require_auth(self) -> Optional[Dict[str, Any]]:
        h = self.headers.get("Authorization", "")
        if not h.startswith("Bearer "):
            _write_error(self, HTTPStatus.UNAUTHORIZED, "missing_token")
            return None
        token = h.removeprefix("Bearer ").strip()
        payload = self.app.verify_token(token)
        if not payload:
            _write_error(self, HTTPStatus.UNAUTHORIZED, "invalid_token")
            return None
        return payload

    def _login(self) -> None:
        data = _read_json(self)
        username = str(data.get("username", "")).strip()
        password = str(data.get("password", "")).strip()
        if not username or not password:
            return _write_error(self, HTTPStatus.BAD_REQUEST, "missing_credentials")

        # v1: accept any non-empty credentials (dev).
        # v2: validate against DSM (SYNO.API.Auth) and enforce share permissions.
        user_id = "u_" + _sanitize_id(username)
        token = self.app.issue_token(user_id, username)
        return _write_json(self, HTTPStatus.OK, {"token": token, "user": {"id": user_id, "username": username, "displayName": username}})

    def _qc_resolve(self) -> None:
        data = _read_json(self)
        qc_id = str(data.get("quickConnectId", "")).strip()
        if not qc_id:
            return _write_error(self, HTTPStatus.BAD_REQUEST, "missing_quickconnect_id")

        payload = {
            "version": 1,
            "command": "get_server_info",
            "stop_when_error": False,
            "stop_when_success": False,
            "id": "dsm_portal",
            "serverID": qc_id,
        }
        req = urllib.request.Request(
            "https://global.quickconnect.to/Serv.php",
            data=_json_bytes(payload),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                raw = resp.read()
        except urllib.error.URLError:
            return _write_error(self, HTTPStatus.BAD_GATEWAY, "quickconnect_resolve_failed")

        try:
            out = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return _write_error(self, HTTPStatus.BAD_GATEWAY, "quickconnect_resolve_failed")

        candidates: List[Dict[str, str]] = []
        server = out.get("server") if isinstance(out, dict) else None
        if isinstance(server, dict):
            ext = server.get("external")
            if isinstance(ext, dict):
                ip = str(ext.get("ip") or "").strip()
                for scheme in ("https", "http"):
                    ports = ext.get(scheme)
                    if ip and isinstance(ports, list):
                        for p in ports:
                            try:
                                pn = int(p)
                            except (TypeError, ValueError):
                                continue
                            candidates.append({"baseUrl": f"{scheme}://{ip}:{pn}", "kind": "direct"})

        # Conservative dedupe
        seen = set()
        uniq: List[Dict[str, str]] = []
        for c in candidates:
            key = f"{c.get('kind')}|{c.get('baseUrl')}"
            if key in seen:
                continue
            seen.add(key)
            uniq.append(c)
        return _write_json(self, HTTPStatus.OK, {"candidates": uniq})

    def _generate_pairing_code(self) -> None:
        """Generate pairing code. Requires auth (user must be logged in)."""
        user = self._require_auth()
        if user is None:
            return
        code = self.app.generate_pairing_code(user["sub"], user.get("usr", ""))
        return _write_json(self, HTTPStatus.OK, {"code": code, "expiresInSeconds": 600})

    def _exchange_pairing_code(self) -> None:
        """Exchange pairing code for session token. Public endpoint."""
        data = _read_json(self)
        code = str(data.get("code", "")).strip()
        if not code or len(code) != 6 or not code.isdigit():
            return _write_error(self, HTTPStatus.BAD_REQUEST, "invalid_pairing_code")
        user_info = self.app.exchange_pairing_code(code)
        if not user_info:
            return _write_error(self, HTTPStatus.BAD_REQUEST, "invalid_or_expired_pairing_code")
        # Issue token for the user
        token = self.app.issue_token(user_info["userId"], user_info["username"])
        return _write_json(
            self,
            HTTPStatus.OK,
            {"token": token, "user": {"id": user_info["userId"], "username": user_info["username"], "displayName": user_info["username"]}},
        )

    def _serve_range_file(self, path: str) -> None:
        # Security: verify path is within allowed directories
        allowed_roots = [self.app.cfg.movies_path, self.app.cfg.tv_path, self.app.cfg.home_path]
        if not _is_path_within_allowed(path, allowed_roots):
            return _write_error(self, HTTPStatus.FORBIDDEN, "access_denied")

        p = Path(path)
        if not p.exists() or not p.is_file():
            return _write_error(self, HTTPStatus.NOT_FOUND, "not_found")

        size = p.stat().st_size
        range_header = self.headers.get("Range")
        if not range_header:
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.end_headers()
            with p.open("rb") as f:
                self.wfile.write(f.read())
            return

        # Only support single range: bytes=start-end
        m = re.fullmatch(r"bytes=(\d+)-(\d*)", range_header.strip())
        if not m:
            return _write_error(self, HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE, "invalid_range")

        start = int(m.group(1))
        end = int(m.group(2)) if m.group(2) else size - 1
        if start < 0 or start >= size or end < start:
            return _write_error(self, HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE, "invalid_range")
        end = min(end, size - 1)
        length = end - start + 1

        self.send_response(HTTPStatus.PARTIAL_CONTENT)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(length))
        self.end_headers()

        with p.open("rb") as f:
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk = f.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def _serve_image(self, img: Dict[str, Any]) -> None:
        # Security: verify path is within allowed directories
        img_path = str(img["path"])
        allowed_roots = [self.app.cfg.movies_path, self.app.cfg.tv_path, self.app.cfg.home_path]
        if not _is_path_within_allowed(img_path, allowed_roots):
            return _write_error(self, HTTPStatus.FORBIDDEN, "access_denied")

        p = Path(img_path)
        if not p.exists() or not p.is_file():
            return _write_error(self, HTTPStatus.NOT_FOUND, "not_found")
        raw = p.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", str(img["mime"]))
        self.send_header("Cache-Control", "public, max-age=86400")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _serve_static_file(self, path: Path, content_type: str) -> None:
        raw = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def _mime_from_path(p: Path) -> str:
    ext = p.suffix.lower()
    if ext == ".png":
        return "image/png"
    return "image/jpeg"


def _image_id_from_path(p: Path) -> str:
    digest = hashlib.sha256(str(p.resolve()).encode("utf-8")).hexdigest()
    return f"img_{digest}"


def _discover_artwork(store: Store, video_path: Path) -> Tuple[Optional[str], Optional[str]]:
    """
    DS Video commonly shows poster art; we mimic by looking for adjacent files:
    - <video>.jpg/.png
    - poster.jpg / folder.jpg / cover.jpg
    - fanart.jpg / backdrop.jpg
    """
    directory = video_path.parent
    stem = video_path.stem

    poster_candidates = [
        directory / f"{stem}.jpg",
        directory / f"{stem}.png",
        directory / "poster.jpg",
        directory / "folder.jpg",
        directory / "cover.jpg",
    ]
    backdrop_candidates = [
        directory / "fanart.jpg",
        directory / "backdrop.jpg",
        directory / "background.jpg",
    ]

    poster_id: Optional[str] = None
    for c in poster_candidates:
        if c.exists() and c.is_file():
            poster_id = _image_id_from_path(c)
            store.upsert_image(poster_id, "poster", _mime_from_path(c), str(c))
            break

    backdrop_id: Optional[str] = None
    for c in backdrop_candidates:
        if c.exists() and c.is_file():
            backdrop_id = _image_id_from_path(c)
            store.upsert_image(backdrop_id, "backdrop", _mime_from_path(c), str(c))
            break

    return poster_id, backdrop_id


def _try_parse_nfo(video_path: Path) -> Tuple[Optional[str], Optional[str]]:
    """
    Very small .nfo reader. Supports common Kodi-like tags:
    - <plot>...</plot>
    - <outline>...</outline>
    - <actor><name>..</name><role>..</role></actor>
    """
    directory = video_path.parent
    stem = video_path.stem
    candidates = [
        directory / f"{stem}.nfo",
        directory / "movie.nfo",
        directory / "tvshow.nfo",
    ]
    for c in candidates:
        if not c.exists() or not c.is_file():
            continue
        try:
            raw = c.read_text("utf-8", errors="ignore")
        except OSError:
            continue
        summary: Optional[str] = None
        for tag in ("plot", "outline"):
            m = re.search(rf"<{tag}>(.*?)</{tag}>", raw, flags=re.IGNORECASE | re.DOTALL)
            if m and not summary:
                txt = re.sub(r"\\s+", " ", m.group(1)).strip()
                if txt:
                    summary = txt

        cast: List[Dict[str, Any]] = []
        for actor_block in re.findall(r"<actor>(.*?)</actor>", raw, flags=re.IGNORECASE | re.DOTALL):
            name_m = re.search(r"<name>(.*?)</name>", actor_block, flags=re.IGNORECASE | re.DOTALL)
            role_m = re.search(r"<role>(.*?)</role>", actor_block, flags=re.IGNORECASE | re.DOTALL)
            name = re.sub(r"\\s+", " ", (name_m.group(1) if name_m else "")).strip()
            role = re.sub(r"\\s+", " ", (role_m.group(1) if role_m else "")).strip()
            if name:
                cast.append({"id": None, "name": name, "role": role or None, "imageId": None})

        cast_json = json.dumps(cast, ensure_ascii=False) if cast else None
        return summary, cast_json

    return None, None


def _parse_tv_metadata(file_path: Path, tv_root: Path):
    """Returns (show_id, show_title, season_number, episode_number) from path structure."""
    try:
        rel = file_path.relative_to(tv_root)
        parts = rel.parts  # e.g. ("Breaking Bad", "Season 2", "S02E05 - Title.mkv")
    except ValueError:
        return None, None, None, None

    show_title = parts[0] if len(parts) >= 2 else None
    show_id = _sanitize_id(show_title) if show_title else None

    season_number = None
    if len(parts) >= 3:
        # Try "Season N" or "S0N" from directory name
        m = re.search(r'[Ss](?:eason\s*)?(\d{1,2})', parts[1])
        if m:
            season_number = int(m.group(1))

    episode_number = None
    fname = parts[-1]
    # Match S01E05, 1x05, or "Episode 5"
    m = re.search(r'[Ss]\d{1,2}[Ee](\d{1,3})', fname)
    if m:
        episode_number = int(m.group(1))
    else:
        m = re.search(r'\d{1,2}x(\d{1,3})', fname)
        if m:
            episode_number = int(m.group(1))

    return show_id, show_title, season_number, episode_number


def _generate_hls(input_path: str, out_dir: str) -> None:
    """
    Generate HLS files into out_dir using ffmpeg.

    Output structure:
    - master.m3u8 (single variant, v1)
    - segments in the same directory (seg_XXXXX.ts)
    """
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return
    try:
        subprocess.run(
            [
                ffmpeg,
                "-y",
                "-i",
                input_path,
                "-c:v",
                "libx264",
                "-c:a",
                "aac",
                "-preset",
                "veryfast",
                "-crf",
                "22",
                "-f",
                "hls",
                "-hls_time",
                "6",
                "-hls_playlist_type",
                "vod",
                "-hls_segment_filename",
                str(Path(out_dir) / "seg_%05d.ts"),
                str(Path(out_dir) / "master.m3u8"),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except Exception:
        return


def run() -> None:
    cfg = Config.load()
    app = App(cfg)
    # Best-effort initial scan
    threading.Thread(target=app.scan_all, daemon=True).start()

    httpd = ThreadingHTTPServer((cfg.listen_host, cfg.listen_port), Handler)
    httpd.app = app  # type: ignore[attr-defined]

    print(f"DS video backend listening on {cfg.listen_host}:{cfg.listen_port} (base={cfg.base_url})")
    httpd.serve_forever()


if __name__ == "__main__":
    run()

