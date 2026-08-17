package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"database/sql"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"dsvideo/backend/internal/metadata"
	"dsvideo/backend/internal/normalize"
	"dsvideo/backend/internal/transcode"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/golang-jwt/jwt/v5"
	_ "modernc.org/sqlite"
)

//go:embed web/*
var webContent embed.FS

// BuildVersion is set at build time via -ldflags.
var BuildVersion = "dev"

type Config struct {
	ListenAddr string
	BaseURL    string
	JWTSecret  string

	MoviesPath string
	TVPath     string
	HomePath   string

	DBPath string

	// Transcode settings
	FFmpegPath   string
	FFprobePath  string
	TranscodeDir string
	// TASK-729: hardware transcode. HWAccel = auto|vaapi|qsv|off (default auto —
	// detect and silently fall back to software). VAAPIDevice = DRM render node.
	HWAccel     string
	VAAPIDevice string

	// MaxFFmpeg is the process-wide ceiling on concurrent ffmpeg invocations across
	// ALL subsystems (HLS transcode, trickplay sprites, subtitle conversion). TASK-752:
	// 0 = auto (max(1, NumCPU/2)). Overridable via DSVIDEO_MAX_FFMPEG. On the 4-core
	// NAS auto yields 2 — sized to avoid the OOM/CPU-kill that produced intermittent
	// "transcode busy" / "resource unavailable" playback failures under load.
	MaxFFmpeg int

	// Metadata settings
	TMDbAPIKey    string
	ImageCacheDir string

	// AdminUser is the DSM username permitted to mutate server-global state
	// (tmdb_api_key + other global settings) and to hit /admin/*. TASK-791/811:
	// the backend otherwise has no role model — every authed DSM user is equal, so a
	// low-priv user could swap the global TMDb key or trigger rescans (DoS). When set
	// (env DSVIDEO_ADMIN_USER) only this user is admin. When empty, the first user to
	// authenticate is recorded as owner (settings key owner_username) and becomes admin
	// — a fresh-NAS default so the installing user is the admin without extra config.
	AdminUser string

	// Security: when true, a DS Video User-Agent presenting an unknown SID is
	// granted a local session WITHOUT validating the SID against DSM. This was the
	// historical default to work around fragile DS Video builds, but it lets anyone
	// on the network forge a session. Default false — only enable on a trusted LAN
	// where a specific DS Video client misbehaves, and never when port-forwarded.
	AllowUnvalidatedDSVideo bool

	// TASK-755 auto-normalize. When enabled, non-DirectPlay files found by the scanner
	// are converted to MP4+H.264/HEVC+AAC in the background (idle-aware, one at a time)
	// so playback is always instant. Originals are moved to OriginalsDir after a verified
	// conversion and reclaimed NormalizeRetentionDays later.
	AutoNormalize          bool
	OriginalsDir           string // backup tree for converted-away originals
	NormalizeRetentionDays int    // days to keep originals before the reaper deletes them
	NormalizeMaxHeight     int    // re-encode resolution cap (never upscales)
}

type Server struct {
	cfg Config
	db  *sql.DB

	mu             sync.RWMutex
	playSessions   map[string]PlaySession
	lastScanAt     time.Time
	scanInProgress atomic.Bool // guards against concurrent background scans

	// Transcode components
	prober         *transcode.Prober
	hlsGenerator   *transcode.HLSGenerator
	cleanupManager *transcode.CleanupManager

	// TASK-755 auto-normalize. nil when DSVIDEO_AUTO_NORMALIZE is off. The scanner
	// Enqueues non-DirectPlay items here; the worker converts them in the background
	// (idle-aware, sharing the ffmpegLimiter) and self-heals the DB on success. The
	// playback handler consults its IsConverting set for the tiny mid-swap 409 window.
	normalizeWorker *normalize.NormalizeWorker

	// Metadata components
	tmdbMu        sync.RWMutex
	tmdbClient    *metadata.TMDbClient
	imageCache    *metadata.ImageCache
	metaMu        sync.Mutex
	metaInFlight  map[string]bool // lowercase title → in-progress guard
	metaSemaphore chan struct{}   // limits concurrent TMDb API calls

	// Serializes progress writes to avoid SQLite busy-timeout under concurrent playback.
	progressMu sync.Mutex

	// Serializes the first-user-wins owner claim (TASK-791/811) so two simultaneous
	// first logins can't both win the owner_username row.
	ownerMu sync.Mutex

	// Trick-play generation guards (TASK-740). Lazy sprite generation runs ffmpeg,
	// so concurrent requests for the same item must collapse to one job. The
	// total-concurrency cap is no longer a separate trickplay semaphore — TASK-752
	// routes trickplay through the shared ffmpegLimiter below so it shares ONE budget
	// with HLS transcode and subtitle conversion.
	trickplayMu       sync.Mutex
	trickplayInFlight map[string]chan struct{} // itemID → closed when its job finishes

	// Embedded-subtitle extraction guards (/playback non-blocking subs fix, follow-up
	// to TASK-752). Extraction runs ffmpeg, which on the 4-core NAS takes 15s+ for an MKV
	// with embedded text subs — far too long to hold the HTTP request open (clients time
	// out at -1001). So /playback NEVER extracts inline: it schedules a background worker
	// and the track appears on the next play. Concurrent plays of the same title must not
	// double-extract the same stream, so collapse them with a per-(itemID:streamIndex)
	// singleflight guard, mirroring trickplayInFlight above. Key = itemID + ":" + index.
	subExtractMu       sync.Mutex
	subExtractInFlight map[string]chan struct{} // "itemID:streamIndex" → closed when its job finishes

	// ffmpegLimiter is the single, process-wide ffmpeg admission budget shared by HLS
	// transcode, trickplay, and subtitle conversion (TASK-752). The HLSGenerator also
	// holds a reference (injected at startup); the Server holds it for the trickplay
	// path. Trickplay TryAcquires (yields when saturated); playback Acquires (waits).
	ffmpegLimiter *transcode.FFmpegLimiter

	// Token revocation list: jti → expiry unix timestamp.
	// This map is a fast in-memory lookup backed by the persistent `revoked_tokens`
	// SQLite table (schema in the migrations block). On revoke (e.g. logout) the jti
	// is written to both the map and the table; on startup the table is warmed back
	// into this map (see warmRevokedTokens), so a revoked token stays revoked across
	// restarts until its natural JWT expiry. Expired entries are purged from both the
	// map and the table by the background purge loop and at startup. (Persistence was
	// TASK-309, now shipped — this is no longer in-memory-only.)
	revokedTokens sync.Map

	// Pairing codes: code → pairingEntry (tvOS ↔ iOS device pairing)
	pairingMu    sync.Mutex
	pairingCodes map[string]pairingEntry

	// Rate limiter for unauthenticated auth endpoints (login, pairing exchange).
	// Keyed by remote IP; value is *authRateEntry.
	authRateMu    sync.Mutex
	authRateLimit sync.Map

	// Cached sync sequence counters (TASK-579). Eliminates the DB SELECT on every
	// heartbeat/status call. Zero means uninitialised — getSyncSeqs falls back to DB.
	// Updated by incrementSeq and by inline item_seq updates during scan.
	cachedItemSeq     atomic.Int64
	cachedProgressSeq atomic.Int64
}

// authRateEntry tracks per-IP attempt counts for auth endpoints.
type authRateEntry struct {
	count     int
	windowEnd time.Time
}

// pairingEntry stores the state for a single pending tvOS pairing code.
type pairingEntry struct {
	userID    string
	username  string
	expiresAt time.Time
	exchanged bool
}

type PlaySession struct {
	ItemID    string
	Path      string
	Kind      string // "direct" | "hls" | "remux"
	HLSDir    string
	CreatedAt time.Time
	// LastAccess is bumped every time getSession reads this entry (segment/playlist
	// fetch). The playSessions reaper (P0-1) uses it as the idle clock so an actively
	// playing session is never evicted mid-stream — only ones idle past the grace window.
	LastAccess   time.Time
	PlaybackMode transcode.PlaybackMode
	Transcoding  bool
}

func main() {
	log.Printf("DS Video backend starting... (build=%s)", BuildVersion)
	cfg := loadConfig()
	log.Printf("Config: listen=%s db=%s movies=%s tv=%s",
		cfg.ListenAddr, cfg.DBPath, cfg.MoviesPath, cfg.TVPath)
	if cfg.JWTSecret == "" || cfg.JWTSecret == "dev-insecure-change-me" {
		log.Fatal("DSVIDEO_JWT_SECRET is not set or is using the insecure default. " +
			"Set a strong random secret before starting the server.")
	}

	// Use WAL mode for concurrent reads during writes, and busy timeout
	// WAL mode: readers never block writers, writers only block other writers.
	// WAL mode: concurrent readers are allowed even during writes.
	// busy_timeout lets writers wait up to 30s instead of failing immediately.
	// wal_autocheckpoint=500: checkpoint WAL after ~2MB of writes to prevent bloat.
	// synchronous=NORMAL: safe with WAL — only full fsync on checkpoint, not every commit.
	dbConnStr := cfg.DBPath + "?_pragma=busy_timeout(30000)&_pragma=journal_mode(WAL)&_pragma=synchronous(1)&_pragma=wal_autocheckpoint(500)"
	log.Printf("Opening database: %s", cfg.DBPath)
	db, err := sql.Open("sqlite", dbConnStr)
	if err != nil {
		log.Fatalf("open db: %v", err)
	}
	defer db.Close()

	// WAL mode allows concurrent readers alongside a single writer, so a higher
	// connection limit reduces pool starvation under concurrent HTTP handlers
	// (remux streams, progress writes, episode fetches, heartbeat).
	db.SetMaxOpenConns(16)
	db.SetMaxIdleConns(4)

	// Verify PRAGMAs applied — modernc DSN params apply per-connection on first use,
	// so ping to force a connection open and confirm WAL mode is active.
	if _, err := db.Exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=500; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=30000"); err != nil {
		log.Fatalf("db pragma setup: %v", err)
	}

	if err := migrate(db); err != nil {
		log.Fatalf("migrate: %v", err)
	}

	// Purge expired revoked token rows from a previous run, then warm the in-memory
	// revocation cache from any non-expired rows. This ensures tokens revoked before
	// a restart are still rejected without requiring a SQLite lookup on every request.
	now := time.Now().Unix()
	if _, err := db.Exec(`DELETE FROM revoked_tokens WHERE expires_at < ?`, now); err != nil {
		log.Printf("revoked_tokens cleanup: %v", err)
	}
	var warmRows *sql.Rows
	// warmRevokedTokens is populated into s.revokedTokens after s is constructed below.
	type revokedRow struct {
		jti       string
		expiresAt int64
	}
	var revokedCache []revokedRow
	if warmRows, err = db.Query(`SELECT jti, expires_at FROM revoked_tokens WHERE expires_at >= ?`, now); err != nil {
		log.Printf("revoked_tokens warm load: %v", err)
	} else {
		for warmRows.Next() {
			var row revokedRow
			if warmRows.Scan(&row.jti, &row.expiresAt) == nil {
				revokedCache = append(revokedCache, row)
			}
		}
		warmRows.Close()
		log.Printf("Loaded %d non-expired revoked token(s) from DB", len(revokedCache))
	}

	// Bootstrap seq counters if they are 0 but rows already exist.
	// This handles the case where progress/items were written before seq tracking
	// was implemented, preventing clients from skipping the initial progress fetch.
	_, _ = db.Exec(`
		UPDATE sync_state SET value = (SELECT COUNT(*) FROM progress)
		WHERE key = 'progress_seq' AND value = 0 AND (SELECT COUNT(*) FROM progress) > 0;
		UPDATE sync_state SET value = COALESCE((SELECT MAX(change_seq) FROM items), 0)
		WHERE key = 'item_seq' AND value = 0 AND (SELECT COUNT(*) FROM items) > 0;
	`)

	// Initialize transcode components
	prober := transcode.NewProber(cfg.FFprobePath)

	hlsConfig := transcode.DefaultHLSConfig()
	hlsConfig.FFmpegPath = cfg.FFmpegPath
	hlsConfig.TempDir = cfg.TranscodeDir
	hlsConfig.HWAccel = cfg.HWAccel
	hlsConfig.VAAPIDevice = cfg.VAAPIDevice
	// An HLS transcode runs ffmpeg for the whole title, so each playing video holds
	// a slot for its full duration. MaxConcurrent=1 meant a single lingering session
	// (e.g. the user backed out without the client sending Stop) blocked ALL new
	// playback with "transcode busy". Allow a few concurrent transcodes, and the
	// generator evicts the oldest idle session when the cap is reached.
	hlsConfig.MaxConcurrent = 3
	hlsGenerator := transcode.NewHLSGenerator(hlsConfig)

	// TASK-752: one shared ffmpeg admission budget across every subsystem that spawns
	// ffmpeg. The old design had TWO uncoordinated pools (HLS MaxConcurrent=3 plus a
	// separate size-2 trickplay semaphore, with subtitle conversion ungated), allowing
	// 5+ concurrent ffmpeg processes on a 4-core/3.8GB box with no HW encoder. The
	// kernel OOM/CPU-killed them and HLS playlist generation missed the client's 30s
	// window → intermittent "transcode busy"/"resource unavailable". The shared budget
	// caps TOTAL ffmpeg concurrency. Auto-size = max(1, NumCPU/2); override via
	// DSVIDEO_MAX_FFMPEG. HLS session admission/eviction (MaxConcurrent) is unchanged;
	// this gates actual process launches.
	ffmpegBudget := cfg.MaxFFmpeg
	if ffmpegBudget <= 0 {
		ffmpegBudget = transcode.DefaultFFmpegConcurrency()
	}
	ffmpegLimiter := transcode.NewFFmpegLimiter(ffmpegBudget)
	hlsGenerator.SetFFmpegLimiter(ffmpegLimiter)
	log.Printf("[transcode] shared ffmpeg concurrency budget: %d", ffmpegBudget)

	cleanupConfig := transcode.DefaultCleanupConfig()
	cleanupConfig.TempDir = cfg.TranscodeDir
	cleanupManager := transcode.NewCleanupManager(cleanupConfig, hlsGenerator)

	// Initialize metadata components
	// Check settings table for TMDb key first, then fall back to env var
	var tmdbAPIKey string
	if row := db.QueryRow("SELECT value FROM settings WHERE key = 'tmdb_api_key' AND user_id = ''"); row != nil {
		var dbKey string
		if err := row.Scan(&dbKey); err == nil && dbKey != "" {
			tmdbAPIKey = dbKey
		}
	}
	if tmdbAPIKey == "" {
		tmdbAPIKey = cfg.TMDbAPIKey
	}

	var tmdbClient *metadata.TMDbClient
	if tmdbAPIKey != "" {
		tmdbClient = metadata.NewTMDbClient(tmdbAPIKey)
		log.Println("TMDb metadata provider enabled")
	} else {
		log.Println("TMDb API key not configured - metadata lookup disabled")
	}
	imageCache := metadata.NewImageCache(cfg.ImageCacheDir)

	s := &Server{
		cfg:            cfg,
		db:             db,
		playSessions:   map[string]PlaySession{},
		prober:         prober,
		hlsGenerator:   hlsGenerator,
		cleanupManager: cleanupManager,
		tmdbClient:     tmdbClient,
		imageCache:     imageCache,
		metaInFlight:   make(map[string]bool),
		metaSemaphore:  make(chan struct{}, 5), // max 5 concurrent TMDb lookups
		pairingCodes:   make(map[string]pairingEntry),

		trickplayInFlight:  make(map[string]chan struct{}),
		subExtractInFlight: make(map[string]chan struct{}),
		ffmpegLimiter:      ffmpegLimiter,
	}

	// TASK-755: construct the auto-normalize worker (gated on DSVIDEO_AUTO_NORMALIZE).
	// It is built here, next to the other transcode components, so it can share the
	// ONE ffmpegLimiter and reference the HLS generator + playSessions for idle
	// detection. The worker's goroutine and retention reaper are started below
	// alongside the other background loops.
	if cfg.AutoNormalize {
		// Resolve concrete ffmpeg/ffprobe paths. The HLS config uses cfg.FFmpegPath
		// (which may be empty → auto-detect); mirror that resolution for the worker so
		// it launches the SAME bundled binaries, not whatever a bare "ffmpeg" resolves to.
		normFFmpeg := cfg.FFmpegPath
		if normFFmpeg == "" {
			if p, ferr := findFFmpeg(); ferr == nil {
				normFFmpeg = p
			}
		}
		normFFprobe := prober.FFprobePath // already resolved by NewProber above

		if normFFmpeg == "" || normFFprobe == "" {
			log.Printf("[normalize] auto-normalize enabled but ffmpeg/ffprobe not found (ffmpeg=%q ffprobe=%q) — disabling", normFFmpeg, normFFprobe)
		} else {
			// Idle = no live HLS transcode AND no playSession touched in the last 60s.
			// Background normalization only starts when nobody is watching, so a re-encode
			// can never steal CPU/ffmpeg slots from a viewer. The 60s grace covers the gap
			// between a client pausing/seeking and its next segment fetch.
			const playbackIdleGrace = 60 * time.Second
			isIdle := func() bool {
				if s.hlsGenerator != nil && s.hlsGenerator.ActiveSessions() != 0 {
					return false
				}
				now := time.Now()
				s.mu.RLock()
				defer s.mu.RUnlock()
				for _, ps := range s.playSessions {
					if now.Sub(ps.LastAccess) < playbackIdleGrace {
						return false
					}
				}
				return true
			}
			// Codec-update callback: re-probe the new file and update the DB so
			// needs_transcode flips to 0 and change_seq bumps (clients see DirectPlay).
			// Worf P0-2: a different-path conversion (.mkv→.mp4) moves the file, so we
			// repoint the item's `path` column to newPath on the SAME id. The id stays
			// hex(originalPath) — re-keying would orphan progress/watchlist FKs — but the
			// playback handler resolves the file via the path column, so the existing item
			// now plays the converted file and no duplicate row appears on the next scan.
			updateCodec := func(itemID, newPath string) {
				if s.prober == nil {
					return
				}
				pctx, pcancel := context.WithTimeout(context.Background(), 30*time.Second)
				defer pcancel()
				if pr, perr := s.prober.Probe(pctx, newPath); perr == nil {
					s.updateCodecInfoRepath(itemID, newPath, pr)
				} else {
					log.Printf("[normalize] post-convert re-probe failed for %s: %v", itemID, perr)
				}
			}
			s.normalizeWorker = normalize.NewNormalizeWorker(
				normFFmpeg, normFFprobe, cfg.OriginalsDir, cfg.NormalizeMaxHeight,
				ffmpegLimiter, isIdle, updateCodec,
			)
			log.Printf("[normalize] auto-normalize enabled (originals=%s retention=%dd maxHeight=%d)",
				cfg.OriginalsDir, cfg.NormalizeRetentionDays, cfg.NormalizeMaxHeight)
		}
	}

	// Warm the in-memory revocation cache from rows loaded above.
	for _, row := range revokedCache {
		s.revokedTokens.Store(row.jti, row.expiresAt)
	}

	// Restore persisted WebAPI sessions (DS Video sessions survive backend restarts)
	loadPersistedSessions(db)

	// Start cleanup manager
	cleanupManager.Start(context.Background())
	defer cleanupManager.Stop()

	// P0-1: reap idle playSessions. The map was written on every /playback but NEVER
	// deleted (no stop path), so each play leaked one entry forever → slow OOM on the
	// 3.8GB box. The HLS CleanupManager already reaps the generator's own session map +
	// temp dirs on a tick; this loop is its sibling for the HTTP-layer playSessions map.
	// Every 5 min we collect entries idle (no segment/playlist fetch) past the grace
	// window UNDER the lock, then tear down each victim's transcode OUTSIDE the lock —
	// StopSession takes the generator's own lock, so calling it while holding s.mu would
	// nest two locks and risk a deadlock. A well-behaved client also releases promptly
	// via POST /playback/{id}/stop; this is the safety net for clients that just vanish.
	go func() {
		const playSessionIdleGrace = 30 * time.Minute
		ticker := time.NewTicker(5 * time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			now := time.Now()
			// Phase 1: collect victim IDs (and their kind) under the lock, delete the
			// map entries, but do NOT call StopSession here — keep the critical section
			// pure map work and never nest the generator lock inside s.mu.
			var hlsVictims []string
			s.mu.Lock()
			for id, ps := range s.playSessions {
				if now.Sub(ps.LastAccess) <= playSessionIdleGrace {
					continue
				}
				if ps.Kind == "hls" {
					hlsVictims = append(hlsVictims, id)
				}
				delete(s.playSessions, id)
			}
			s.mu.Unlock()

			// Phase 2: tear down each HLS transcode + temp dir OUTSIDE the lock.
			for _, id := range hlsVictims {
				if s.hlsGenerator != nil {
					if err := s.hlsGenerator.StopSession(id); err != nil {
						log.Printf("[playSessions] reaper StopSession %s: %v", id, err)
					}
				}
			}
			if n := len(hlsVictims); n > 0 {
				log.Printf("[playSessions] reaped %d idle HLS session(s)", n)
			}
		}
	}()

	// Periodically purge expired in-memory caches:
	//   - revokedTokens: entries past their JWT exp timestamp
	//   - webAPISessions: sessions older than 24 hours (also removed from SQLite)
	//   - idMappings: per-session ID caches not accessed in 7 days
	//   - authRateLimit: per-IP rate limit entries whose window has expired
	go func() {
		ticker := time.NewTicker(15 * time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			// Revoked token list — purge expired entries from both in-memory map and SQLite.
			now := time.Now().Unix()
			s.revokedTokens.Range(func(k, v any) bool {
				if exp, ok := v.(int64); ok && now > exp {
					s.revokedTokens.Delete(k)
				}
				return true
			})
			if _, dbErr := s.db.Exec(`DELETE FROM revoked_tokens WHERE expires_at < ?`, now); dbErr != nil {
				log.Printf("[purge] revoked_tokens cleanup: %v", dbErr)
			}

			// Auth rate limit entries — delete entries whose window has expired.
			// sync.Map Range+Delete is safe without an external mutex.
			nowT := time.Now()
			s.authRateLimit.Range(func(k, v any) bool {
				if entry, ok := v.(*authRateEntry); ok && nowT.After(entry.windowEnd) {
					s.authRateLimit.Delete(k)
				}
				return true
			})

			// WebAPI sessions — evict after 24 hours
			if evicted := webAPISessions.CleanupExpired(24*time.Hour, s.db); evicted > 0 {
				log.Printf("[WebAPI] Evicted %d expired session(s) from in-memory store", evicted)
			}

			// Orphaned progress rows — delete rows whose item no longer exists.
			//
			// Measured on a live server: 45 of 201 rows (22%) referenced items that had been
			// deleted or renamed. They are served to every client by /progress/all on every
			// sync, they sit in each client's outbox where the server permanently 404s them
			// (the stall path 14e72cf had to work around), and they never expire on their own
			// because nothing deleted them when the item went away.
			//
			// A row is orphaned only when its item_id is absent from items; that is a pure
			// referential check, so there is no heuristic here and no risk of removing
			// progress for a title the user still has. Deliberately NOT a foreign key with
			// ON DELETE CASCADE: the items table is rebuilt by the scanner, and a cascade
			// would drop progress during a rescan window.
			if res, dbErr := s.db.Exec(
				`DELETE FROM progress WHERE item_id NOT IN (SELECT id FROM items)`,
			); dbErr != nil {
				log.Printf("[purge] orphaned progress cleanup: %v", dbErr)
			} else if n, _ := res.RowsAffected(); n > 0 {
				log.Printf("[purge] removed %d orphaned progress row(s)", n)
				s.incrementSeq("progress_seq")
			}

			// Pairing codes — remove expired entries
			s.pairingMu.Lock()
			now2 := time.Now()
			for code, entry := range s.pairingCodes {
				if now2.After(entry.expiresAt) {
					delete(s.pairingCodes, code)
				}
			}
			s.pairingMu.Unlock()

			// Per-session ID mappings — evict after 7 days of no access
			if evicted := cleanupExpiredIDMappings(7 * 24 * time.Hour); evicted > 0 {
				log.Printf("[WebAPI] Evicted %d expired ID mapping(s)", evicted)
			}
		}
	}()

	// Periodic background scanner — runs every 5 minutes regardless of client activity.
	// This ensures the DB stays current when files are added/removed via the filesystem,
	// regardless of whether the iOS app or browser player has made any API calls.
	// The scanner is guarded by scanInProgress so concurrent runs can't stack up.
	go func() {
		// Kick off an initial scan shortly after startup (give the HTTP server a moment
		// to start) so new installs populate the DB without waiting 5 minutes.
		time.Sleep(5 * time.Second)
		if s.scanInProgress.CompareAndSwap(false, true) {
			go func() {
				defer s.scanInProgress.Store(false)
				if err := s.scanAll(context.Background()); err != nil {
					log.Printf("startup scan failed: %v", err)
				}
			}()
		}
		ticker := time.NewTicker(5 * time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			if s.scanInProgress.CompareAndSwap(false, true) {
				go func() {
					defer s.scanInProgress.Store(false)
					if err := s.scanAll(context.Background()); err != nil {
						log.Printf("periodic scan failed: %v", err)
					}
				}()
			}
		}
	}()

	// TASK-755: start the auto-normalize worker goroutine and its hourly retention
	// reaper. Gated on the worker having been constructed above (auto-normalize on +
	// ffmpeg/ffprobe found). Both run for the process lifetime on a background context.
	if s.normalizeWorker != nil {
		s.normalizeWorker.Start(context.Background())
		// Worf P2-5 (TASK-755): the retention reaper deletes everything older than N days
		// under OriginalsDir. DSVIDEO_ORIGINALS_DIR is user-overridable; if it's empty, a
		// filesystem root, or a media root (or a parent of one), the reaper would delete the
		// user's actual movies. Validate before arming it: on failure we still let the worker
		// run conversions (originals are backed up safely) but REFUSE to start the reaper, so
		// backups simply accumulate rather than risk nuking the library.
		if reason := validateOriginalsDir(cfg.OriginalsDir, cfg.MoviesPath, cfg.TVPath, cfg.HomePath); reason != "" {
			log.Printf("[normalize] retention reaper DISABLED — unsafe originals dir %q: %s", cfg.OriginalsDir, reason)
		} else {
			s.normalizeWorker.StartRetentionReaper(context.Background(), cfg.NormalizeRetentionDays)
		}
	}

	r := chi.NewRouter()
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(redactSensitiveParams) // must run before Logger to prevent token leakage in logs
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)
	r.Use(bodyLimitMiddleware) // TASK-810: cap request bodies to avoid NAS OOM DoS

	// Serve web player
	webFS, err := fs.Sub(webContent, "web")
	if err != nil {
		log.Fatalf("failed to create web filesystem: %v", err)
	}
	serveIndex := func(w http.ResponseWriter, r *http.Request) {
		data, err := fs.ReadFile(webFS, "index.html")
		if err != nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(data)
	}
	r.Get("/", serveIndex)
	r.Get("/web", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/", http.StatusTemporaryRedirect)
	})
	r.Handle("/web/*", http.StripPrefix("/web/", http.FileServer(http.FS(webFS))))

	// -------------------------
	// Video Station WebAPI Compatibility Layer
	// -------------------------
	// These endpoints allow the official DS Video iOS app to connect
	// to this server as if it were a genuine Video Station instance.
	r.Get("/webapi/query.cgi", s.handleWebAPIQuery)
	r.Post("/webapi/query.cgi", s.handleWebAPIQuery)
	r.Get("/webapi/entry.cgi", s.handleWebAPIEntry)
	r.Post("/webapi/entry.cgi", s.handleWebAPIEntry)
	r.Get("/webapi/VideoStation/poster.cgi", s.handleWebAPIPosterCGI)
	r.Get("/webapi/VideoStation/vtestreaming.cgi/*", s.handleWebAPIVTEStreaming)
	r.Post("/webapi/VideoStation/vtestreaming.cgi", s.handleWebAPIVTEStreamingOpen)
	r.Post("/webapi/VideoStation/vtestreaming.cgi/*", s.handleWebAPIVTEStreamingOpen)

	// DSVideoServer-prefixed routes — used when nginx proxies /webapi/DSVideoServer/ to us.
	// The query.cgi response points VideoStation APIs here so DSM's entry.cgi isn't intercepted.
	r.Get("/webapi/DSVideoServer/entry.cgi", s.handleWebAPIEntry)
	r.Post("/webapi/DSVideoServer/entry.cgi", s.handleWebAPIEntry)
	r.Get("/webapi/DSVideoServer/poster.cgi", s.handleWebAPIPosterCGI)
	r.Get("/webapi/DSVideoServer/vtestreaming.cgi/*", s.handleWebAPIVTEStreaming)
	r.Post("/webapi/DSVideoServer/vtestreaming.cgi", s.handleWebAPIVTEStreamingOpen)
	r.Post("/webapi/DSVideoServer/vtestreaming.cgi/*", s.handleWebAPIVTEStreamingOpen)

	// Handle portal alias prefix (/dsvideo/) — DSM nginx may proxy with prefix intact
	r.Get("/dsvideo", func(w http.ResponseWriter, req *http.Request) {
		http.Redirect(w, req, "/dsvideo/", http.StatusMovedPermanently)
	})
	r.Get("/dsvideo/", serveIndex)
	r.Route("/dsvideo/api/v1", func(sub chi.Router) {
		registerAPIRoutes(sub, s)
	})

	r.Route("/api/v1", func(sub chi.Router) {
		registerAPIRoutes(sub, s)
	})

	// Catch-all: log any request that doesn't match defined routes.
	// This helps detect paths DS Video uses that we haven't handled yet.
	r.NotFound(func(w http.ResponseWriter, req *http.Request) {
		body, _ := io.ReadAll(io.LimitReader(req.Body, 200))
		log.Printf("[WebAPI] UNHANDLED %s %s UA=%q body=%q", req.Method, req.URL.String(), req.Header.Get("User-Agent"), string(body))
		http.NotFound(w, req)
	})

	// Advertise via Bonjour/mDNS so iOS and tvOS clients can discover this server
	// without manual IP entry. Uses the OS dns-sd tool (available on both macOS and
	// Synology DSM). Failures are non-fatal — server still works without it.
	go advertiseMDNS(cfg.ListenAddr)

	// Warn if DSVIDEO_BASE_URL is not configured — relay/QC stream URLs will be wrong.
	if strings.HasPrefix(cfg.BaseURL, "http://localhost") || strings.HasPrefix(cfg.BaseURL, "https://localhost") {
		log.Printf("WARNING: DSVIDEO_BASE_URL not set — stream URLs will use Host header heuristic. Set DSVIDEO_BASE_URL to the public URL of this server for reliable QuickConnect/relay playback.")
	}
	log.Printf("DS Video backend listening on %s", cfg.ListenAddr)
	if err := http.ListenAndServe(cfg.ListenAddr, r); err != nil {
		log.Fatal(err)
	}
}

// advertiseMDNS registers a _dsvideo._tcp Bonjour service so clients on the
// local network can discover this server without manual IP configuration.
// Uses dns-sd (available on macOS and Synology DSM) or avahi-publish (Linux NAS).
// Both commands must run indefinitely to keep the service registered — we keep
// them alive and restart on unexpected exit with a backoff loop.
func advertiseMDNS(listenAddr string) {
	_, portStr, err := net.SplitHostPort(listenAddr)
	if err != nil {
		log.Printf("[mDNS] Could not parse listen address %q: %v", listenAddr, err)
		return
	}

	hostname, _ := os.Hostname()
	if hostname == "" {
		hostname = "DSVideoServer"
	}

	// Prefer dns-sd (macOS / Synology DSM with Bonjour), fall back to avahi-publish.
	binary, args := mdnsBinary(portStr, hostname)
	if binary == "" {
		log.Printf("[mDNS] Neither dns-sd nor avahi-publish found — mDNS advertisement unavailable")
		return
	}

	log.Printf("[mDNS] Advertising _dsvideo._tcp on port %s via %s", portStr, binary)

	backoff := time.Second
	for {
		cmd := exec.Command(binary, args...)
		if err := cmd.Run(); err != nil {
			log.Printf("[mDNS] %s exited (%v) — restarting in %s", binary, err, backoff)
			time.Sleep(backoff)
			if backoff < 30*time.Second {
				backoff *= 2
			}
		} else {
			// Clean exit — back off briefly then restart to maintain registration.
			backoff = time.Second
			time.Sleep(backoff)
		}
	}
}

func mdnsBinary(portStr, hostname string) (string, []string) {
	if _, err := exec.LookPath("dns-sd"); err == nil {
		return "dns-sd", []string{
			"-R", "DSVideoServer", "_dsvideo._tcp", ".", portStr,
			"version=1", "host=" + hostname,
		}
	}
	if _, err := exec.LookPath("avahi-publish"); err == nil {
		return "avahi-publish", []string{
			"-s", "DSVideoServer", "_dsvideo._tcp", portStr,
			"version=1", "host=" + hostname,
		}
	}
	return "", nil
}

// registerAPIRoutes mounts all /api/v1 routes onto r.
// Called for both the /api/v1 and /dsvideo/api/v1 prefixes so that route
// definitions are never duplicated.
func registerAPIRoutes(r chi.Router, s *Server) {
	// Unauthenticated routes
	r.Post("/auth/quickconnect/resolve", s.handleQuickConnectResolve)
	r.Post("/auth/login", s.handleLogin)
	r.Post("/auth/logout", s.handleLogout)

	// Pairing exchange is unauthenticated — the code itself is the credential
	r.Post("/auth/pairing/exchange", s.handlePairingExchange)

	// Playback streams don't require auth — session ID is the security token
	r.Get("/playback/{sessionId}/stream", s.handlePlaybackStream)
	// P0-1: explicit release so a well-behaved client frees its session (and any HLS
	// transcode + temp dir) immediately instead of waiting on the idle reaper. Same auth
	// model as the stream routes — the session ID is the credential. Idempotent.
	r.Post("/playback/{sessionId}/stop", s.handlePlaybackStop)
	r.Get("/playback/{sessionId}/master.m3u8", s.handleHLSFile("master.m3u8"))
	// fMP4 HLS writes the init segment and the .m4s media segments at the session
	// ROOT (init.mp4, segment_NNNNN.m4s, ABR v0_init.mp4 / v0_NNNNN.m4s), and the
	// playlist references them as bare names — so they're requested at the session
	// root, NOT under /segments/. Without these routes every fMP4 transcode 404s
	// its init+segments → "Playback Failed: resource unavailable". The suffix
	// routes are matched before the {variant}.m3u8 wildcard by chi.
	r.Get("/playback/{sessionId}/init.mp4", s.handleHLSSegmentRoot)
	r.Get("/playback/{sessionId}/{name}.m4s", s.handleHLSSegmentRoot)
	r.Get("/playback/{sessionId}/{name}.ts", s.handleHLSSegmentRoot)
	r.Get("/playback/{sessionId}/{variant}.m3u8", s.handleHLSVariant)
	r.Get("/playback/{sessionId}/segments/{name}", s.handleHLSSegment)

	// TMDb proxy and version stay public: neither reveals anything about THIS library.
	// (The TMDb proxy is still an outbound-fetch primitive — tracked separately.)
	r.Get("/tmdb/image", s.handleTMDbImageProxy)
	r.Get("/version", s.handleVersion)

	// Images are PUBLIC — deliberately, for now. See the security note below.
	//
	// KNOWN ISSUE (accepted, tracked): item IDs are hex(absolute path), so an anonymous
	// caller who can reach this port can probe /api/v1/images/<hex> and read 200-vs-404 to
	// enumerate every title on the NAS and confirm its directory layout. There is no rate
	// limit on this route. It leaks the catalog and the folder tree — NOT credentials,
	// tokens, video content, or write access; every other route stays authenticated.
	//
	// This was briefly locked behind authMiddleware, which broke every poster in the
	// embedded web UI: an <img> tag cannot send an Authorization header, so it has no way
	// to authenticate an image load. (The native iOS/tvOS clients are unaffected — they
	// fetch images in code and set the Bearer header themselves.) A ?token= query fallback
	// was tried and rejected valid tokens on the deployed server for reasons not yet
	// understood, so it was reverted rather than left half-working.
	//
	// The correct fix is client-side and needs no URL token: have the web UI fetch each
	// image with fetch() + the Authorization header and hand the result to <img> as a blob
	// URL. Credentials stay in headers — which also matters because URLs land in access
	// logs and browser history. Re-gate this route at the same time as that lands.
	r.Get("/images/{id}", s.handleImage)

	r.Group(func(r chi.Router) {
		r.Use(s.authMiddleware)
		r.Get("/sync/heartbeat", s.handleSyncHeartbeat)

		// TASK-740: trick-play scrubbing previews. The .vtt request lazily generates
		// the sprite + VTT (cached per item) via ffmpeg, so it MUST be authenticated —
		// an unauthenticated generation trigger lets anyone spin up arbitrary ffmpeg
		// jobs and DoS the NAS. The client sends the Bearer token on both requests.
		r.Get("/trickplay/{itemId}/trickplay.vtt", s.handleTrickplayVTT)
		r.Get("/trickplay/{itemId}/trickplay.jpg", s.handleTrickplaySprite)

		// Pairing generate requires auth — caller's identity seeds the tvOS token
		r.Post("/auth/pairing/generate", s.handlePairingGenerate)
		r.Post("/auth/refresh", s.handleTokenRefresh)

		// Delta sync endpoints
		r.Get("/sync/status", s.handleSyncStatus)
		r.Get("/sync/items", s.handleSyncItems)
		r.Get("/sync/deleted", s.handleSyncDeleted)

		r.Get("/libraries", s.handleLibraries)
		r.Get("/libraries/summary", s.handleLibrariesSummary)
		r.Get("/items", s.handleItems)
		r.Get("/items/{id}", s.handleItemDetail)
		r.Get("/items/{id}/playback", s.handlePlayback)
		r.Get("/progress/all", s.handleProgressAll)
		r.Get("/progress", s.handleProgressBatch)
		r.Post("/items/{id}/progress", s.handleProgress)
		r.Get("/items/{id}/tmdb-search", s.handleItemTMDbSearch)
		r.Post("/items/{id}/tmdb-fix", s.handleItemTMDbFix)

		// TV Shows
		r.Get("/shows", s.handleShowsList)
		r.Get("/shows/{showName}", s.handleShowDetail)
		r.Get("/tv/shows", s.handleTVShowsList)
		r.Get("/tv/shows/{showId}/seasons", s.handleTVShowSeasons)
		r.Get("/tv/shows/{showId}/episodes", s.handleTVShowEpisodes)
		r.Get("/tv/shows/{showId}/tmdb-search", s.handleTVShowTMDbSearch)
		r.Post("/tv/shows/{showId}/tmdb-fix", s.handleTVShowTMDbFix)

		// Settings
		r.Get("/settings", s.handleGetSettings)
		r.Put("/settings", s.handlePutSettings)

		// Playlists
		r.Get("/playlists", s.handleListPlaylists)
		r.Post("/playlists", s.handleCreatePlaylist)
		r.Get("/playlists/{id}", s.handleGetPlaylist)
		r.Delete("/playlists/{id}", s.handleDeletePlaylist)
		r.Post("/playlists/{id}/items", s.handleAddPlaylistItem)
		r.Delete("/playlists/{id}/items/{itemId}", s.handleRemovePlaylistItem)

		// Downloads (bookmarks)
		r.Get("/downloads", s.handleListDownloads)
		r.Post("/downloads/{itemId}", s.handleAddDownload)
		r.Delete("/downloads/{itemId}", s.handleRemoveDownload)

		// Watchlist
		r.Get("/watchlist", s.handleWatchlistGet)
		r.Get("/watchlist/{itemId}", s.handleWatchlistCheck)
		r.Post("/watchlist/{itemId}", s.handleWatchlistAdd)
		r.Delete("/watchlist/{itemId}", s.handleWatchlistRemove)

		r.Get("/admin/status", s.handleAdminStatus)
		r.Get("/admin/normalize/status", s.handleAdminNormalizeStatus)
		r.Post("/admin/scan", s.handleAdminScan)
		r.Get("/search", s.handleSearch)
	})
}

func loadConfig() Config {
	get := func(key, def string) string {
		if v := strings.TrimSpace(os.Getenv(key)); v != "" {
			return v
		}
		return def
	}
	getBool := func(key string, def bool) bool {
		v := strings.TrimSpace(os.Getenv(key))
		if v == "" {
			return def
		}
		return strings.EqualFold(v, "true") || v == "1"
	}
	getInt := func(key string, def int) int {
		n, err := strconv.Atoi(get(key, ""))
		if err != nil || n <= 0 {
			return def
		}
		return n
	}

	// Defaults are developer-friendly; SPK install should override via env/config.
	port := get("DSVIDEO_PORT", "8080")

	// TASK-755: default the originals backup tree to a sibling of the video library
	// so it lives on the same volume (rename-into-backup is then instant/atomic) but
	// OUTSIDE any indexed root (the scanner SkipDirs it). Prefer the dirname of
	// MoviesPath (e.g. /volume1/video/Movies → /volume1/video/_dsvideo_originals);
	// fall back to the TV path's parent, else a temp dir for dev. Overridable.
	originalsDefault := filepath.Join(os.TempDir(), "_dsvideo_originals")
	if mp := strings.TrimSpace(os.Getenv("DSVIDEO_MOVIES_PATH")); mp != "" {
		originalsDefault = filepath.Join(filepath.Dir(filepath.Clean(mp)), "_dsvideo_originals")
	} else if tp := strings.TrimSpace(os.Getenv("DSVIDEO_TV_PATH")); tp != "" {
		originalsDefault = filepath.Join(filepath.Dir(filepath.Clean(tp)), "_dsvideo_originals")
	}

	return Config{
		ListenAddr: ":" + port,
		BaseURL:    get("DSVIDEO_BASE_URL", "http://localhost:"+port),
		JWTSecret:  get("DSVIDEO_JWT_SECRET", "dev-insecure-change-me"),

		MoviesPath: get("DSVIDEO_MOVIES_PATH", ""),
		TVPath:     get("DSVIDEO_TV_PATH", ""),
		HomePath:   get("DSVIDEO_HOME_PATH", ""),

		DBPath: get("DSVIDEO_DB_PATH", "./dsvideo.db"),

		// Transcode settings
		FFmpegPath:   get("DSVIDEO_FFMPEG_PATH", ""),  // Empty = auto-detect
		FFprobePath:  get("DSVIDEO_FFPROBE_PATH", ""), // Empty = auto-detect
		TranscodeDir: get("DSVIDEO_TRANSCODE_DIR", filepath.Join(os.TempDir(), "dsvideo_transcode")),
		HWAccel:      get("DSVIDEO_HW_ACCEL", "auto"),
		VAAPIDevice:  get("DSVIDEO_VAAPI_DEVICE", "/dev/dri/renderD128"),
		// TASK-752: shared ffmpeg concurrency ceiling. Empty/0/invalid = auto-size
		// from CPU count at startup. Set explicitly only to override the default.
		MaxFFmpeg: func() int {
			n, err := strconv.Atoi(get("DSVIDEO_MAX_FFMPEG", "0"))
			if err != nil || n < 0 {
				return 0
			}
			return n
		}(),

		// Metadata settings
		TMDbAPIKey:    get("DSVIDEO_TMDB_API_KEY", ""),
		ImageCacheDir: get("DSVIDEO_IMAGE_CACHE_DIR", filepath.Join(os.TempDir(), "dsvideo_images")),

		// TASK-791/811: admin/owner for server-global mutations. Empty = first-user-wins.
		AdminUser: get("DSVIDEO_ADMIN_USER", ""),

		// Security — default false. Opt in only with an explicit "1"/"true".
		AllowUnvalidatedDSVideo: strings.EqualFold(get("DSVIDEO_ALLOW_UNVALIDATED_DSVIDEO", ""), "true") ||
			get("DSVIDEO_ALLOW_UNVALIDATED_DSVIDEO", "") == "1",

		// TASK-755 auto-normalize — on by default so a fresh NAS self-heals to all-DirectPlay.
		AutoNormalize:          getBool("DSVIDEO_AUTO_NORMALIZE", true),
		OriginalsDir:           get("DSVIDEO_ORIGINALS_DIR", originalsDefault),
		NormalizeRetentionDays: getInt("DSVIDEO_NORMALIZE_RETENTION_DAYS", 7),
		// 1080 (not 720): normalization REPLACES the original, which is then reaped after
		// the retention window — so this cap is a permanent, irreversible downscale of the
		// user's library, not a playback-time choice. Capping at 720 would silently destroy
		// every 1080p/4K source. 1080 preserves the common case; a 4K source still gets
		// downscaled, which is the intended trade on a CPU-only NAS.
		NormalizeMaxHeight: getInt("DSVIDEO_NORMALIZE_MAX_HEIGHT", 1080),
	}
}

func migrate(db *sql.DB) error {
	// Step 1: Create tables with base schema (for fresh installs)
	_, err := db.Exec(`
CREATE TABLE IF NOT EXISTS items (
  id TEXT PRIMARY KEY,
  library_id TEXT NOT NULL,
  type TEXT NOT NULL,
  title TEXT NOT NULL,
  year INTEGER,
  path TEXT NOT NULL,
  duration_seconds INTEGER,
  added_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS progress (
  item_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  position_seconds INTEGER NOT NULL,
  duration_seconds INTEGER NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (item_id, user_id)
);

CREATE TABLE IF NOT EXISTS transcode_sessions (
  session_id TEXT PRIMARY KEY,
  video_id TEXT,
  mode TEXT,
  output_path TEXT,
  started_at TEXT,
  completed_at TEXT
);

CREATE TABLE IF NOT EXISTS images (
  id TEXT PRIMARY KEY,
  tmdb_path TEXT,
  image_type TEXT,
  cached_path TEXT,
  cached_at TEXT
);

CREATE TABLE IF NOT EXISTS settings (
  key TEXT NOT NULL,
  user_id TEXT NOT NULL DEFAULT '',
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (key, user_id)
);

CREATE TABLE IF NOT EXISTS playlists (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  title TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS playlist_items (
  playlist_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  position INTEGER NOT NULL DEFAULT 0,
  added_at TEXT NOT NULL,
  PRIMARY KEY (playlist_id, item_id),
  FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS downloads (
  item_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  marked_at TEXT NOT NULL,
  PRIMARY KEY (item_id, user_id)
);

CREATE TABLE IF NOT EXISTS webapi_sessions (
  sid        TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL,
  username   TEXT NOT NULL,
  token      TEXT NOT NULL,
  device_id  TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS watchlist (
  item_id  TEXT NOT NULL,
  user_id  TEXT NOT NULL,
  added_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  PRIMARY KEY (item_id, user_id)
);
`)
	if err != nil {
		return fmt.Errorf("create tables: %w", err)
	}

	// Step 2: Add columns if they don't exist (for upgrades from older versions).
	// Use PRAGMA table_info to guard each ALTER TABLE so we never attempt to add
	// a column that already exists — avoids "duplicate column name" log noise on
	// every launch after the column is already present.
	type colMigration struct {
		column string
		sql    string
	}
	migrations := []colMigration{
		{"video_codec", "ALTER TABLE items ADD COLUMN video_codec TEXT"},
		{"audio_codec", "ALTER TABLE items ADD COLUMN audio_codec TEXT"},
		{"container", "ALTER TABLE items ADD COLUMN container TEXT"},
		{"needs_transcode", "ALTER TABLE items ADD COLUMN needs_transcode BOOLEAN DEFAULT FALSE"},
		{"tmdb_id", "ALTER TABLE items ADD COLUMN tmdb_id INTEGER"},
		{"imdb_id", "ALTER TABLE items ADD COLUMN imdb_id TEXT"},
		{"overview", "ALTER TABLE items ADD COLUMN overview TEXT"},
		{"poster_path", "ALTER TABLE items ADD COLUMN poster_path TEXT"},
		{"backdrop_path", "ALTER TABLE items ADD COLUMN backdrop_path TEXT"},
		{"rating", "ALTER TABLE items ADD COLUMN rating REAL"},
		{"genres", "ALTER TABLE items ADD COLUMN genres TEXT"},
		{"director", "ALTER TABLE items ADD COLUMN director TEXT"},
		{"cast_names", "ALTER TABLE items ADD COLUMN cast_names TEXT"},
		{"content_rating", "ALTER TABLE items ADD COLUMN content_rating TEXT"},
		{"original_title", "ALTER TABLE items ADD COLUMN original_title TEXT"},
		{"show_name", "ALTER TABLE items ADD COLUMN show_name TEXT"},
		{"season_number", "ALTER TABLE items ADD COLUMN season_number INTEGER"},
		{"episode_number", "ALTER TABLE items ADD COLUMN episode_number INTEGER"},
		{"episode_title", "ALTER TABLE items ADD COLUMN episode_title TEXT"},
		{"metadata_fetched_at", "ALTER TABLE items ADD COLUMN metadata_fetched_at TEXT"},
		// Delta sync support
		{"change_seq", "ALTER TABLE items ADD COLUMN change_seq INTEGER NOT NULL DEFAULT 0"},
		// TASK-571: store show_folder_id at scan time so it is stable across TVPath config changes
		{"show_folder_id", "ALTER TABLE items ADD COLUMN show_folder_id TEXT"},
		// TASK-728: media specs for quality/format badges (4K/HDR/Atmos) on the client
		{"video_width", "ALTER TABLE items ADD COLUMN video_width INTEGER"},
		{"video_height", "ALTER TABLE items ADD COLUMN video_height INTEGER"},
		{"audio_channels", "ALTER TABLE items ADD COLUMN audio_channels INTEGER"},
	}
	for _, m := range migrations {
		var exists bool
		_ = db.QueryRow(`SELECT COUNT(*) > 0 FROM pragma_table_info('items') WHERE name=?`, m.column).Scan(&exists)
		if !exists {
			if _, err := db.Exec(m.sql); err != nil {
				return fmt.Errorf("migration %s: %w", m.column, err)
			}
		}
	}

	// progress.write_seq — a MONOTONIC per-write ordinal, so two writes in the same second
	// can still be ordered.
	//
	// The conditional upsert used to break ties on updated_at, which is RFC3339 and therefore
	// only 1-second granular. Within one second it fell back to "larger position wins", which
	// silently DISCARDED any legitimate position-reducing write — an explicit "mark unwatched"
	// (position 0) or a rewind issued in the same second as a prior write vanished, and the
	// handler still answered {"ok":true}. Reproduced against the live server: POST 4000 then
	// POST 0 in the same second left the row at 4000.
	// write_seq is allocated from the same monotone counter that drives delta sync, so ordering
	// is exact regardless of clock granularity or skew.
	{
		var exists bool
		_ = db.QueryRow(`SELECT COUNT(*) > 0 FROM pragma_table_info('progress') WHERE name='write_seq'`).Scan(&exists)
		if !exists {
			if _, err := db.Exec(`ALTER TABLE progress ADD COLUMN write_seq INTEGER NOT NULL DEFAULT 0`); err != nil {
				return fmt.Errorf("migration progress.write_seq: %w", err)
			}
		}
	}

	// Step 3: Create indexes AFTER columns are guaranteed to exist
	indexes := []string{
		"CREATE INDEX IF NOT EXISTS idx_items_library_added ON items(library_id, added_at)",
		"CREATE INDEX IF NOT EXISTS idx_items_tmdb_id ON items(tmdb_id)",
		"CREATE INDEX IF NOT EXISTS idx_items_change_seq ON items(change_seq)",
		// Episode query indexes — prevent full table scans under concurrent load
		"CREATE INDEX IF NOT EXISTS idx_items_path ON items(path)",
		"CREATE INDEX IF NOT EXISTS idx_items_library_show ON items(library_id, show_name)",
		"CREATE INDEX IF NOT EXISTS idx_items_library_season ON items(library_id, show_name, season_number)",
	}
	for _, idx := range indexes {
		if _, err := db.Exec(idx); err != nil {
			return fmt.Errorf("create index: %w", err)
		}
	}

	// Step 4: Create sync_state and deleted_items tables (delta sync)
	_, err = db.Exec(`
CREATE TABLE IF NOT EXISTS sync_state (
  key   TEXT PRIMARY KEY,
  value INTEGER NOT NULL DEFAULT 0
);
INSERT OR IGNORE INTO sync_state(key, value) VALUES ('item_seq', 0);
INSERT OR IGNORE INTO sync_state(key, value) VALUES ('progress_seq', 0);

CREATE TABLE IF NOT EXISTS deleted_items (
  item_id    TEXT NOT NULL,
  change_seq INTEGER NOT NULL,
  deleted_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_deleted_items_seq ON deleted_items(change_seq);
`)
	if err != nil {
		return fmt.Errorf("create sync_state: %w", err)
	}

	// Step 5: Persistent JWT revocation table.
	// Stores revoked JTIs so they survive server restarts.
	_, err = db.Exec(`
CREATE TABLE IF NOT EXISTS revoked_tokens (
  jti        TEXT PRIMARY KEY,
  revoked_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_revoked_expires ON revoked_tokens(expires_at);
`)
	if err != nil {
		return fmt.Errorf("create revoked_tokens: %w", err)
	}

	return nil
}

// -------------------------
// Sync State Helpers
// -------------------------

// incrementSeq atomically increments a sync counter and returns the new value.
// Returns 0 and logs an error if the DB write fails (TASK-611).
// Also updates the in-memory cache so getSyncSeqs avoids a DB round-trip (TASK-579).
func (s *Server) incrementSeq(key string) int64 {
	var newVal int64
	if err := s.db.QueryRow(
		`UPDATE sync_state SET value = value + 1 WHERE key = ? RETURNING value`, key,
	).Scan(&newVal); err != nil {
		log.Printf("[incrementSeq] failed to increment %q: %v", key, err)
		return 0
	}
	switch key {
	case "item_seq":
		s.cachedItemSeq.Store(newVal)
	case "progress_seq":
		s.cachedProgressSeq.Store(newVal)
	}
	return newVal
}

// getSyncSeqs returns the current item_seq and progress_seq.
// Reads from in-memory atomic cache when initialised; falls back to a DB query
// on first call (zero values) so the cache warms up automatically (TASK-579).
func (s *Server) getSyncSeqs() (itemSeq, progressSeq int64) {
	itemSeq = s.cachedItemSeq.Load()
	progressSeq = s.cachedProgressSeq.Load()
	if itemSeq != 0 || progressSeq != 0 {
		return
	}
	// Cache uninitialised — read from DB once and populate it.
	rows, err := s.db.Query(`SELECT key, value FROM sync_state WHERE key IN ('item_seq','progress_seq')`)
	if err != nil {
		return 0, 0
	}
	defer rows.Close()
	for rows.Next() {
		var k string
		var v int64
		if rows.Scan(&k, &v) == nil {
			switch k {
			case "item_seq":
				itemSeq = v
				s.cachedItemSeq.Store(v)
			case "progress_seq":
				progressSeq = v
				s.cachedProgressSeq.Store(v)
			}
		}
	}
	return
}

// -------------------------
// TMDb Client Helper
// -------------------------

// getTMDbClient returns a TMDb client based on the request.
// If the client provides an X-TMDb-API-Key header, use that (allows per-user keys).
// Otherwise, fall back to the server's configured client.
func (s *Server) getTMDbClient(r *http.Request) *metadata.TMDbClient {
	clientKey := r.Header.Get("X-TMDb-API-Key")
	if clientKey != "" {
		return metadata.NewTMDbClient(clientKey)
	}
	s.tmdbMu.RLock()
	client := s.tmdbClient
	s.tmdbMu.RUnlock()
	return client
}

// -------------------------
// Logging Middleware
// -------------------------

// redactSensitiveParams replaces the values of sensitive query parameters with
// "[REDACTED]" in the request URL before chi's Logger middleware sees it.
// This prevents session tokens sent as _sid= or token= query params from
// appearing verbatim in Synology package log files.
// NOTE: only r.URL is modified — the actual query string seen by handlers is
// unaffected because this runs before routing resolves to a handler.
// maxRequestBodyBytes caps any inbound request body. TASK-810: the JSON endpoints decode
// r.Body with no limit; on an internet-exposed NAS a single multi-GB POST would stream
// into the decoder and OOM-kill the process. Every legitimate request here (JSON control
// endpoints, WebAPI form login) is well under 1 MB; media streaming routes are all GET
// with no body, so a global cap is safe. MaxBytesReader also makes the server close the
// connection once the limit is exceeded rather than draining the oversized body.
const maxRequestBodyBytes = 1 << 20 // 1 MiB

func bodyLimitMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Body != nil {
			r.Body = http.MaxBytesReader(w, r.Body, maxRequestBodyBytes)
		}
		next.ServeHTTP(w, r)
	})
}

func redactSensitiveParams(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if q := r.URL.Query(); q.Has("_sid") || q.Has("token") {
			if q.Has("_sid") {
				q.Set("_sid", "[REDACTED]")
			}
			if q.Has("token") {
				q.Set("token", "[REDACTED]")
			}
			sanitized := *r.URL
			sanitized.RawQuery = q.Encode()
			r2 := r.WithContext(r.Context())
			r2.URL = &sanitized
			next.ServeHTTP(w, r2)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// -------------------------
// Auth
// -------------------------

type loginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
	OTP      string `json:"otp,omitempty"`
}

type loginResponse struct {
	Token string `json:"token"`
	User  struct {
		ID          string `json:"id"`
		Username    string `json:"username"`
		DisplayName string `json:"displayName"`
	} `json:"user"`
}

// checkAuthRateLimit enforces a fixed-window rate limit on auth endpoints.
// Allows up to 10 attempts per 60-second window per IP.
// Returns true (and writes a 429 response) when the limit is exceeded.
// Stale windows are cleaned up on each call for that IP.
func (s *Server) checkAuthRateLimit(w http.ResponseWriter, r *http.Request) bool {
	const maxAttempts = 10
	const windowSeconds = 60

	// Use net.SplitHostPort to correctly parse the host from RemoteAddr.
	// This handles both IPv4 ("1.2.3.4:port") and IPv6 ("[::1]:port") correctly.
	// strings.LastIndex would corrupt IPv6 keys by truncating at the last colon.
	ip := r.RemoteAddr
	if host, _, err := net.SplitHostPort(ip); err == nil {
		ip = host
	}

	now := time.Now()
	raw, _ := s.authRateLimit.LoadOrStore(ip, &authRateEntry{count: 0, windowEnd: now.Add(windowSeconds * time.Second)})
	entry := raw.(*authRateEntry)

	s.authRateMu.Lock()
	// If the window has expired, reset it
	if now.After(entry.windowEnd) {
		entry.count = 0
		entry.windowEnd = now.Add(windowSeconds * time.Second)
	}
	entry.count++
	exceeded := entry.count > maxAttempts
	s.authRateMu.Unlock()

	if exceeded {
		w.Header().Set("Retry-After", "60")
		writeErr(w, http.StatusTooManyRequests, "rate_limit_exceeded")
		return true
	}
	return false
}

func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if s.checkAuthRateLimit(w, r) {
		return
	}
	var req loginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_json")
		return
	}
	if strings.TrimSpace(req.Username) == "" || strings.TrimSpace(req.Password) == "" {
		writeErr(w, http.StatusBadRequest, "missing_credentials")
		return
	}

	// Authenticate against Synology DSM WebAPI
	dsmUser, err := s.authenticateDSM(r.Context(), req.Username, req.Password, req.OTP, "")
	if err != nil {
		log.Printf("DSM auth failed (username redacted): %v", err)
		// Distinguish a permission denial (correct password, account not authorized
		// for this app) from a bad password so the client can guide the user to
		// DSM → Application Privileges instead of telling them their password is wrong.
		if _, ok := err.(*dsmPermissionError); ok {
			writeErr(w, http.StatusForbidden, "permission_denied")
			return
		}
		writeErr(w, http.StatusUnauthorized, "invalid_credentials")
		return
	}

	userID := "u_" + sanitizeID(dsmUser.Username)
	token, err := s.issueToken(userID, dsmUser.Username)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "token_error")
		return
	}

	var resp loginResponse
	resp.Token = token
	resp.User.ID = userID
	resp.User.Username = dsmUser.Username
	resp.User.DisplayName = dsmUser.DisplayName
	writeJSON(w, http.StatusOK, resp)
}

// DSM user info returned from authentication
type dsmUserInfo struct {
	Username    string
	DisplayName string
	SID         string
}

// dsmTwoFactorError is returned when DSM requires two-factor authentication.
// It carries the raw DSM JSON response so the caller can pass it through
// verbatim to the client, preserving any extra fields (did, types, etc.)
// that the DS Video app needs for the OTP submission round-trip.
type dsmTwoFactorError struct {
	RawResp []byte
}

func (e *dsmTwoFactorError) Error() string { return "2fa_required" }

// dsmPermissionError is returned when DSM accepts the credentials but denies the
// account permission to use this application (DSM error 402). Distinct from
// invalid credentials so the client can tell the user it's a permissions issue,
// not a wrong password.
type dsmPermissionError struct{}

func (e *dsmPermissionError) Error() string { return "permission_denied" }

// authenticateDSM validates credentials against Synology DSM WebAPI.
// Uses auth.cgi (DSM legacy endpoint) instead of entry.cgi to avoid a
// forwarding loop — our nginx intercepts entry.cgi but not auth.cgi.
func (s *Server) authenticateDSM(ctx context.Context, username, password, otp, did string) (*dsmUserInfo, error) {
	// Use auth.cgi (not entry.cgi) so the call doesn't loop back through our
	// nginx location block. DSM 7 still supports auth.cgi for SYNO.API.Auth.
	dsmURL := "http://localhost:5000/webapi/auth.cgi"

	// Version 6 is the minimum that supports otp_code for 2FA.
	//
	// NOTE ON `session`: this used to send session=DSVideo, which is NOT a real DSM
	// application name. DSM validates `session` against installed applications and denies
	// the login with error 402 when it does not match one — but ONLY for non-admin users,
	// because admins bypass application privilege checks entirely. The bug was therefore
	// invisible to the NAS owner (an admin) and blocked every ordinary user, no matter what
	// was ticked in Control Panel → Application Privileges. Granting "DSVideoServer" could
	// never help: the server was asking DSM about a different, non-existent app.
	//
	// The session parameter is optional. Omitting it authenticates the account without
	// scoping the session to an application, which is what we want — this package manages
	// its own authorization (JWT + per-user access) and does not rely on DSM to gate it.
	// Verified against a live DSM 7 NAS: a non-admin account that returns 402 with
	// session=DSVideo authenticates successfully with the parameter omitted.
	formData := fmt.Sprintf(
		"api=SYNO.API.Auth&version=6&method=login&account=%s&passwd=%s&format=sid",
		url.QueryEscape(username),
		url.QueryEscape(password),
	)

	// Add OTP if provided (for 2FA)
	if otp != "" {
		formData += "&otp_code=" + url.QueryEscape(otp)
	}

	// Add device ID if provided — used for device trust after successful OTP.
	if did != "" {
		formData += "&did=" + url.QueryEscape(did)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, dsmURL, strings.NewReader(formData))
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	// Never follow redirects: auth.cgi may redirect to entry.cgi which our nginx
	// intercepts, causing a loop. Return the 3xx directly so we can detect it.
	noRedirect := func(req *http.Request, via []*http.Request) error {
		return http.ErrUseLastResponse
	}

	client := &http.Client{
		Timeout:       5 * time.Second,
		CheckRedirect: noRedirect,
	}
	resp, err := client.Do(req)
	if err != nil {
		// If localhost:5000 fails, try 5001 (HTTPS) — also via auth.cgi
		dsmURL = "https://localhost:5001/webapi/auth.cgi"
		req, _ = http.NewRequestWithContext(ctx, http.MethodPost, dsmURL, strings.NewReader(formData))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

		// For localhost DSM HTTPS, accept self-signed certs by checking host only.
		// We don't skip verification globally — we verify that the server name is
		// localhost/127.0.0.1, which is the expected DSM address in this context.
		client = &http.Client{
			Timeout:       5 * time.Second,
			CheckRedirect: noRedirect,
			Transport: &http.Transport{
				TLSClientConfig: &tls.Config{
					InsecureSkipVerify: false,
					VerifyConnection: func(cs tls.ConnectionState) error {
						// Only bypass cert chain validation for the loopback address.
						// Any other hostname will still fail standard verification.
						host := cs.ServerName
						if host == "localhost" || host == "127.0.0.1" || host == "" {
							return nil
						}
						return fmt.Errorf("tls: non-localhost host %q not allowed in localhost-only DSM fallback", host)
					},
				},
			},
		}
		resp, err = client.Do(req)
		if err != nil {
			return nil, fmt.Errorf("dsm request failed: %w", err)
		}
	}
	defer resp.Body.Close()

	// auth.cgi should never redirect a POST — if it does, our entry.cgi intercept
	// would cause a forwarding loop. Treat redirect as DSM unavailable.
	if resp.StatusCode >= 300 {
		location := resp.Header.Get("Location")
		log.Printf("[Auth] auth.cgi returned HTTP %d (Location: %s) — treating as unreachable", resp.StatusCode, location)
		return nil, fmt.Errorf("dsm auth unavailable: redirect %d", resp.StatusCode)
	}

	log.Printf("[Auth] auth.cgi returned HTTP %d", resp.StatusCode)

	// TASK-823: bound the DSM auth response read. auth.cgi returns a small JSON
	// blob; 1 MiB is far more than any legitimate response and caps memory if the
	// (trusted but possibly misbehaving) DSM endpoint streams an unbounded body.
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("dsm auth unavailable: read error")
	}

	var dsmResp struct {
		Success bool `json:"success"`
		Data    struct {
			SID          string `json:"sid"`
			DeviceID     string `json:"device_id"`
			IsPortalPort bool   `json:"is_portal_port"`
		} `json:"data"`
		Error struct {
			Code int `json:"code"`
		} `json:"error"`
	}

	if err := json.Unmarshal(body, &dsmResp); err != nil {
		log.Printf("[Auth] Failed to decode auth.cgi response: %v", err)
		return nil, fmt.Errorf("dsm auth unavailable: decode error")
	}

	log.Printf("[Auth] auth.cgi response: success=%v, error_code=%d", dsmResp.Success, dsmResp.Error.Code)

	if !dsmResp.Success {
		// DSM error codes: 400=no permission, 401=disabled account, 402=denied permission, 403=2FA required, 404=2FA failed
		switch dsmResp.Error.Code {
		case 400:
			return nil, fmt.Errorf("invalid credentials")
		case 401:
			return nil, fmt.Errorf("account disabled")
		case 402:
			// DSM authenticated the password but the account lacks permission to
			// use this application. Standard (non-admin) DSM users hit this until
			// they're granted access in DSM → Control Panel → Application Privileges.
			return nil, &dsmPermissionError{}
		case 403:
			// Carry the raw DSM response so the caller can relay it verbatim
			// to the client — the DS Video app needs any extra fields (did, etc.)
			return nil, &dsmTwoFactorError{RawResp: body}
		case 404:
			return nil, fmt.Errorf("invalid OTP code")
		default:
			return nil, fmt.Errorf("dsm error code %d", dsmResp.Error.Code)
		}
	}

	return &dsmUserInfo{
		Username:    username,
		DisplayName: username, // DSM doesn't return display name in auth response
		SID:         dsmResp.Data.SID,
	}, nil
}

// revokeJWT parses a signed JWT and, if valid, adds its jti to the revocation list
// (in-memory for in-flight requests + persisted so it survives restarts). Safe to call
// with an empty/invalid token — it's a no-op then. TASK-806: shared by REST logout and
// WebAPI logout so a credential logged out in either session plane is revoked in BOTH,
// closing the divergence where a WebAPI logout deleted only the local SID while the
// embedded REST JWT stayed valid.
func (s *Server) revokeJWT(raw string) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return
	}
	tok, err := jwt.Parse(raw, func(token *jwt.Token) (any, error) {
		if token.Method != jwt.SigningMethodHS256 {
			return nil, errors.New("unexpected signing method")
		}
		return []byte(s.cfg.JWTSecret), nil
	})
	if err != nil || !tok.Valid {
		return
	}
	claims, ok := tok.Claims.(jwt.MapClaims)
	if !ok {
		return
	}
	jti, _ := claims["jti"].(string)
	exp, _ := claims["exp"].(float64)
	if jti == "" {
		return
	}
	expUnix := int64(exp)
	// Fast in-memory revocation (for requests already in-flight)
	s.revokedTokens.Store(jti, expUnix)
	// Persistent revocation (survives server restarts)
	if _, dbErr := s.db.Exec(
		`INSERT OR REPLACE INTO revoked_tokens(jti, revoked_at, expires_at) VALUES (?, ?, ?)`,
		jti, time.Now().Unix(), expUnix,
	); dbErr != nil {
		log.Printf("[logout] failed to persist revoked token: %v", dbErr)
	}
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	h := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if strings.HasPrefix(h, prefix) {
		s.revokeJWT(strings.TrimPrefix(h, prefix))
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) issueToken(userID, username string) (string, error) {
	jtiBytes := make([]byte, 16)
	if _, err := rand.Read(jtiBytes); err != nil {
		return "", fmt.Errorf("generate jti: %w", err)
	}
	claims := jwt.MapClaims{
		"sub": userID,
		"usr": username,
		"jti": hex.EncodeToString(jtiBytes),
		"iat": time.Now().Unix(),
		"exp": time.Now().Add(30 * 24 * time.Hour).Unix(),
	}
	t := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return t.SignedString([]byte(s.cfg.JWTSecret))
}

type authedUser struct {
	ID       string
	Username string
}

type ctxKey int

const userKey ctxKey = 1

func (s *Server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Bearer header ONLY. A ?token= query fallback was added alongside the images-route
		// gating, then the route was reverted to public while the fallback was left behind —
		// so every authenticated route accepted a full-privilege JWT in the query string with
		// no caller that needed it. URLs land in access logs, browser history and Referer
		// headers, so that is a credential-leak surface for zero benefit.
		//
		// If the images route is ever re-gated, the correct answer is the blob-URL fetch
		// already implemented in web/index.html (fetch + Authorization header → object URL),
		// NOT a token in a URL.
		h := r.Header.Get("Authorization")
		const prefix = "Bearer "
		raw := ""
		if strings.HasPrefix(h, prefix) {
			raw = strings.TrimSpace(strings.TrimPrefix(h, prefix))
		}
		if raw == "" {
			writeErr(w, http.StatusUnauthorized, "missing_token")
			return
		}

		tok, err := jwt.Parse(raw, func(token *jwt.Token) (any, error) {
			if token.Method != jwt.SigningMethodHS256 {
				return nil, errors.New("unexpected signing method")
			}
			return []byte(s.cfg.JWTSecret), nil
		})
		if err != nil || !tok.Valid {
			writeErr(w, http.StatusUnauthorized, "invalid_token")
			return
		}
		claims, ok := tok.Claims.(jwt.MapClaims)
		if !ok {
			writeErr(w, http.StatusUnauthorized, "invalid_token")
			return
		}

		// FIX-13: in-memory map is warmed from SQLite at startup and kept current via
		// every logout/revocation path, making it the authoritative source of truth.
		// The previous SQLite SELECT COUNT(*) on every authenticated request was O(log n)
		// per request and unnecessary — removing it eliminates a DB round-trip from the
		// hot path without changing correctness.
		if jti, _ := claims["jti"].(string); jti != "" {
			if _, revoked := s.revokedTokens.Load(jti); revoked {
				writeErr(w, http.StatusUnauthorized, "token_revoked")
				return
			}
		}

		sub, _ := claims["sub"].(string)
		usr, _ := claims["usr"].(string)
		if sub == "" {
			writeErr(w, http.StatusUnauthorized, "invalid_token")
			return
		}

		u := authedUser{ID: sub, Username: usr}
		ctx := context.WithValue(r.Context(), userKey, u)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func userFromCtx(ctx context.Context) authedUser {
	u, _ := ctx.Value(userKey).(authedUser)
	return u
}

// ownerUsername returns the persisted owner (settings key owner_username, global row),
// or "" if none has been claimed yet.
func (s *Server) ownerUsername() string {
	var v string
	_ = s.db.QueryRow("SELECT value FROM settings WHERE key = 'owner_username' AND user_id = ''").Scan(&v)
	return v
}

// isAdmin reports whether the authenticated user may mutate server-global state and hit
// /admin/*. TASK-791/811. Precedence:
//  1. If DSVIDEO_ADMIN_USER is configured, ONLY that username (case-insensitive) is admin.
//  2. Otherwise the persisted owner_username (first-user-wins) is admin.
//
// It also lazily claims ownership: when no admin is configured AND no owner is recorded
// yet, the first authenticated caller is written as owner and is treated as admin. This
// makes the installing user the admin on a fresh NAS with zero configuration, while never
// silently promoting a second user once an owner exists.
func (s *Server) isAdmin(u authedUser) bool {
	if u.Username == "" {
		return false
	}
	if configured := strings.TrimSpace(s.cfg.AdminUser); configured != "" {
		return strings.EqualFold(u.Username, configured)
	}

	if owner := s.ownerUsername(); owner != "" {
		return strings.EqualFold(u.Username, owner)
	}

	// No admin configured and no owner yet — claim it for this user under a lock so a
	// race between two first logins resolves to a single winner.
	s.ownerMu.Lock()
	defer s.ownerMu.Unlock()
	if owner := s.ownerUsername(); owner != "" {
		return strings.EqualFold(u.Username, owner)
	}
	now := time.Now().UTC().Format(time.RFC3339)
	if _, err := s.db.Exec(
		`INSERT INTO settings(key, user_id, value, updated_at) VALUES('owner_username','',?,?)
		 ON CONFLICT(key, user_id) DO NOTHING`,
		u.Username, now,
	); err != nil {
		log.Printf("[admin] failed to record owner_username=%q: %v", u.Username, err)
		return false
	}
	log.Printf("[admin] no admin configured — recorded first user %q as owner", u.Username)
	return strings.EqualFold(u.Username, s.ownerUsername())
}

// requireAdmin writes a 403 and returns false when the caller is not admin.
func (s *Server) requireAdmin(w http.ResponseWriter, r *http.Request) bool {
	if s.isAdmin(userFromCtx(r.Context())) {
		return true
	}
	writeErr(w, http.StatusForbidden, "admin_required")
	return false
}

// -------------------------
// Pairing (tvOS ↔ iOS)
// -------------------------

const (
	pairingCodeTTL     = 10 * time.Minute
	pairingCodeSeconds = 600
)

// handlePairingGenerate — POST /api/v1/auth/pairing/generate
// Requires authentication. Called by tvOS to obtain a short code that an iOS
// device can type in to receive a session token for the same account.
func (s *Server) handlePairingGenerate(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())
	if u.ID == "" {
		writeErr(w, http.StatusUnauthorized, "missing_token")
		return
	}

	// Generate a 6-digit numeric code using crypto/rand for uniform distribution.
	codeBuf := make([]byte, 4)
	if _, err := rand.Read(codeBuf); err != nil {
		log.Printf("[pairing] crypto/rand failed: %v", err)
		writeErr(w, http.StatusInternalServerError, "internal_error")
		return
	}
	// Map 4 random bytes to a number in [0, 1_000_000) then zero-pad to 6 digits.
	n := (uint32(codeBuf[0])<<24 | uint32(codeBuf[1])<<16 | uint32(codeBuf[2])<<8 | uint32(codeBuf[3])) % 1_000_000
	code := fmt.Sprintf("%06d", n)

	entry := pairingEntry{
		userID:    u.ID,
		username:  u.Username,
		expiresAt: time.Now().Add(pairingCodeTTL),
	}

	s.pairingMu.Lock()
	s.pairingCodes[code] = entry
	s.pairingMu.Unlock()

	log.Printf("[pairing] generated code for user=%s expires=%s", u.Username, entry.expiresAt.Format(time.RFC3339))

	writeJSON(w, http.StatusOK, map[string]any{
		"code":               code,
		"expires_in_seconds": pairingCodeSeconds,
	})
}

// handlePairingExchange — POST /api/v1/auth/pairing/exchange
// Unauthenticated. Called by iOS with the code the user typed. Returns a full
// JWT session token that the tvOS device (or iOS app acting on its behalf) can
// use from this point forward.
func (s *Server) handlePairingExchange(w http.ResponseWriter, r *http.Request) {
	if s.checkAuthRateLimit(w, r) {
		return
	}
	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_json")
		return
	}
	if req.Code == "" {
		writeErr(w, http.StatusBadRequest, "missing_code")
		return
	}

	s.pairingMu.Lock()
	entry, ok := s.pairingCodes[req.Code]
	if ok {
		if entry.exchanged || time.Now().After(entry.expiresAt) {
			// Mark as consumed or detect expiry — either way, delete and deny.
			delete(s.pairingCodes, req.Code)
			ok = false
		} else {
			entry.exchanged = true
			s.pairingCodes[req.Code] = entry
		}
	}
	s.pairingMu.Unlock()

	if !ok {
		writeErr(w, http.StatusUnauthorized, "invalid_or_expired_code")
		return
	}

	token, err := s.issueToken(entry.userID, entry.username)
	if err != nil {
		log.Printf("[pairing] issueToken failed: %v", err)
		writeErr(w, http.StatusInternalServerError, "token_error")
		return
	}

	log.Printf("[pairing] code exchanged successfully for user=%s", entry.username)

	// Return the same shape as loginResponse so the iOS client can reuse its
	// existing LoginResponse decoder (token + user object).
	writeJSON(w, http.StatusOK, map[string]any{
		"token": token,
		"user": map[string]any{
			"id":          entry.userID,
			"username":    entry.username,
			"displayName": entry.username,
		},
	})
}

// -------------------------
// QuickConnect
// -------------------------

type qcResolveRequest struct {
	QuickConnectID string `json:"quickConnectId"`
}

type qcCandidate struct {
	BaseURL string `json:"baseUrl"`
	Kind    string `json:"kind"`
}

func (s *Server) handleQuickConnectResolve(w http.ResponseWriter, r *http.Request) {
	var req qcResolveRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_json")
		return
	}
	id := strings.TrimSpace(req.QuickConnectID)
	if id == "" {
		writeErr(w, http.StatusBadRequest, "missing_quickconnect_id")
		return
	}
	candidates, err := resolveQuickConnect(r.Context(), id)
	if err != nil {
		writeErr(w, http.StatusBadGateway, "quickconnect_resolve_failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"candidates": candidates})
}

// Minimal resolver based on public reverse-engineering references.
func resolveQuickConnect(ctx context.Context, quickConnectID string) ([]qcCandidate, error) {
	// Endpoint referenced widely for get_server_info
	reqBody := map[string]any{
		"version":           1,
		"command":           "get_server_info",
		"stop_when_error":   false,
		"stop_when_success": false,
		"id":                "dsm_portal",
		"serverID":          quickConnectID,
	}
	b, _ := json.Marshal(reqBody)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://global.quickconnect.to/Serv.php", strings.NewReader(string(b)))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("quickconnect http %d", resp.StatusCode)
	}
	var out map[string]any
	// TASK-823: bound the QuickConnect resolver response. quickconnect.to returns a
	// small candidate list; 1 MiB caps memory against a misbehaving relay.
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&out); err != nil {
		return nil, err
	}

	// Best-effort extraction. The exact structure varies; we keep it robust and conservative.
	var candidates []qcCandidate

	// Many responses include: {"server": {"external": {"ip": "...", "https": [...], "http": [...]}, ...}}
	server, _ := out["server"].(map[string]any)
	if server != nil {
		if ext, _ := server["external"].(map[string]any); ext != nil {
			// external https ports
			if ports, ok := ext["https"].([]any); ok {
				for _, p := range ports {
					if pn, ok := asInt(p); ok && pn > 0 {
						candidates = append(candidates, qcCandidate{
							BaseURL: fmt.Sprintf("https://%s:%d", asString(ext["ip"]), pn),
							Kind:    "direct",
						})
					}
				}
			}
			if ports, ok := ext["http"].([]any); ok {
				for _, p := range ports {
					if pn, ok := asInt(p); ok && pn > 0 {
						candidates = append(candidates, qcCandidate{
							BaseURL: fmt.Sprintf("http://%s:%d", asString(ext["ip"]), pn),
							Kind:    "direct",
						})
					}
				}
			}
		}
		// relay region hints sometimes exist
		if relay, _ := server["relay_region"].(string); relay != "" {
			_ = relay
		}
	}

	// Fallback: if we got nothing, return empty but not error.
	return dedupeCandidates(candidates), nil
}

func dedupeCandidates(in []qcCandidate) []qcCandidate {
	seen := map[string]bool{}
	out := make([]qcCandidate, 0, len(in))
	for _, c := range in {
		key := c.Kind + "|" + c.BaseURL
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, c)
	}
	return out
}

func asString(v any) string {
	s, _ := v.(string)
	return s
}

func asInt(v any) (int, bool) {
	switch t := v.(type) {
	case float64:
		return int(t), true
	case int:
		return t, true
	default:
		return 0, false
	}
}

// -------------------------
// Libraries / Items
// -------------------------

func (s *Server) handleLibraries(w http.ResponseWriter, r *http.Request) {
	libs := []map[string]any{
		{"id": "lib_movies", "title": "Movies", "kind": "movies"},
		{"id": "lib_tv", "title": "TV Shows", "kind": "tv"},
	}
	writeJSON(w, http.StatusOK, map[string]any{"libraries": libs})

	// Trigger a background rescan if the last scan was more than 5 minutes ago.
	// CAS on scanInProgress prevents launching duplicate concurrent scans.
	s.mu.RLock()
	staleScan := time.Since(s.lastScanAt) > 5*time.Minute
	s.mu.RUnlock()
	if staleScan && s.scanInProgress.CompareAndSwap(false, true) {
		go func() {
			defer s.scanInProgress.Store(false)
			if err := s.scanAll(context.Background()); err != nil {
				log.Printf("background scan failed: %v", err)
			}
		}()
	}
}

// handleLibrariesSummary returns per-library item count and latest updated_at in a single
// DB query. Used by the iOS client for incremental cache refresh — one request detects
// additions, removals, and rescans without fetching any item data.
func (s *Server) handleLibrariesSummary(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.QueryContext(r.Context(),
		`SELECT library_id, COUNT(*) as count, MAX(updated_at) as last_updated_at
		 FROM items
		 GROUP BY library_id`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	defer rows.Close()

	type libSummary struct {
		LibraryID     string `json:"libraryId"`
		Count         int    `json:"count"`
		LastUpdatedAt string `json:"lastUpdatedAt"`
	}
	summaries := []libSummary{}
	for rows.Next() {
		var s libSummary
		if err := rows.Scan(&s.LibraryID, &s.Count, &s.LastUpdatedAt); err != nil {
			continue
		}
		summaries = append(summaries, s)
	}
	writeJSON(w, http.StatusOK, map[string]any{"libraries": summaries})
}

func (s *Server) handleItems(w http.ResponseWriter, r *http.Request) {
	libraryID := r.URL.Query().Get("libraryId")
	filter := r.URL.Query().Get("filter")
	folder := r.URL.Query().Get("folder")
	limit := clampInt(parseInt(r.URL.Query().Get("limit"), 10000), 1, 10000)
	offset := clampInt(parseInt(r.URL.Query().Get("offset"), 0), 0, 1_000_000)

	u := userFromCtx(r.Context())

	// Handle "byFolder" filter - returns folder listing
	if filter == "byFolder" && folder == "" && libraryID != "" {
		s.handleItemsByFolder(w, r, libraryID, u)
		return
	}

	// Handle "justWatched" filter
	if filter == "justWatched" {
		s.handleItemsJustWatched(w, r, libraryID, u, limit, offset)
		return
	}

	var where string
	var args []any
	var orderBy string

	switch filter {
	case "justAdded":
		if libraryID != "" {
			where = "WHERE i.library_id = ?"
			args = append(args, libraryID)
		}
		orderBy = "ORDER BY i.added_at DESC"
		limit = 30
	case "byFolder":
		// folder param is set - filter to items in that folder
		if libraryID != "" {
			where = "WHERE i.library_id = ?"
			args = append(args, libraryID)
		}
		if folder != "" {
			if where == "" {
				where = "WHERE "
			} else {
				where += " AND "
			}
			// Match items whose path contains the folder as a directory component
			// Escape SQL LIKE wildcards in user-supplied folder name
			escapedFolder := strings.ReplaceAll(folder, "%", "\\%")
			escapedFolder = strings.ReplaceAll(escapedFolder, "_", "\\_")
			where += "i.path LIKE ? ESCAPE '\\'"
			args = append(args, "%/"+escapedFolder+"/%")
		}
		orderBy = "ORDER BY i.title ASC"
	default:
		// "all" or empty - all items in library
		if libraryID == "" {
			writeErr(w, http.StatusBadRequest, "missing_libraryId")
			return
		}
		where = "WHERE i.library_id = ?"
		args = append(args, libraryID)
		orderBy = "ORDER BY i.title ASC"
	}

	countSQL := "SELECT COUNT(*) FROM items i " + where
	var total int
	if err := s.db.QueryRow(countSQL, args...).Scan(&total); err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}

	// JOIN progress in the main query to avoid N+1 SELECT calls.
	joinArgs := append([]any{u.ID}, args...)
	joinArgs = append(joinArgs, limit, offset)
	rows, err := s.db.Query(
		`SELECT i.id, i.type, i.title, i.year, i.duration_seconds, i.added_at, i.rating,
		        i.poster_path, i.backdrop_path, i.overview,
		        i.show_name, i.season_number, i.episode_number,
		        p.position_seconds, p.duration_seconds, p.updated_at,
		        i.show_folder_id
		 FROM items i
		 LEFT JOIN progress p ON p.item_id = i.id AND p.user_id = ?
		 `+where+` `+orderBy+` LIMIT ? OFFSET ?`,
		joinArgs...,
	)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	defer rows.Close()

	items := make([]map[string]any, 0)
	for rows.Next() {
		var id, typ, title, addedAt string
		var year, duration, seasonNumber, episodeNumber sql.NullInt64
		var rating sql.NullFloat64
		var posterPath, backdropPath, overview, showName sql.NullString
		var progPos, progDur sql.NullInt64
		var progUpdatedAt sql.NullString
		var showFolderIDCol sql.NullString

		if err := rows.Scan(&id, &typ, &title, &year, &duration, &addedAt, &rating,
			&posterPath, &backdropPath, &overview,
			&showName, &seasonNumber, &episodeNumber,
			&progPos, &progDur, &progUpdatedAt,
			&showFolderIDCol); err != nil {
			writeErr(w, http.StatusInternalServerError, "db_error")
			return
		}

		var p map[string]any
		if progPos.Valid {
			p = map[string]any{
				"positionSeconds": progPos.Int64,
				"durationSeconds": progDur.Int64,
				"updatedAt":       progUpdatedAt.String,
			}
		}

		item := map[string]any{
			"id":              id,
			"type":            typ,
			"title":           title,
			"year":            nullIntToAny(year),
			"durationSeconds": nullIntToAny(duration),
			"addedAt":         addedAt,
			"rating":          nullFloatToAny(rating),
			"posterImageId":   nil,
			"backdropImageId": nil,
		}

		if posterPath.Valid && posterPath.String != "" {
			item["posterImageId"] = id
		}
		if backdropPath.Valid && backdropPath.String != "" {
			item["backdropImageId"] = id
		}
		if showName.Valid && showName.String != "" {
			item["showName"] = showName.String
		}
		if seasonNumber.Valid {
			item["seasonNumber"] = seasonNumber.Int64
		}
		if episodeNumber.Valid {
			item["episodeNumber"] = episodeNumber.Int64
		}
		if showFolderIDCol.Valid && showFolderIDCol.String != "" {
			item["showFolderId"] = showFolderIDCol.String
		}
		if p != nil {
			item["progress"] = p
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"total": total, "items": items})
}

func (s *Server) handleSearch(w http.ResponseWriter, r *http.Request) {
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	limit := clampInt(parseInt(r.URL.Query().Get("limit"), 50), 1, 200)
	offset := clampInt(parseInt(r.URL.Query().Get("offset"), 0), 0, 1_000_000)

	if q == "" {
		writeJSON(w, http.StatusOK, map[string]any{"total": 0, "items": []any{}})
		return
	}

	u := userFromCtx(r.Context())
	pattern := "%" + q + "%"

	var total int
	if err := s.db.QueryRow(
		"SELECT COUNT(*) FROM items i WHERE LOWER(i.title) LIKE LOWER(?)",
		pattern,
	).Scan(&total); err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}

	// JOIN progress to avoid N+1 SELECT calls per result row.
	rows, err := s.db.Query(
		`SELECT i.id, i.type, i.title, i.year, i.duration_seconds, i.added_at, i.rating,
		        i.poster_path, i.backdrop_path,
		        p.position_seconds, p.duration_seconds, p.updated_at
		 FROM items i
		 LEFT JOIN progress p ON p.item_id = i.id AND p.user_id = ?
		 WHERE LOWER(i.title) LIKE LOWER(?)
		 ORDER BY i.title ASC
		 LIMIT ? OFFSET ?`,
		u.ID, pattern, limit, offset,
	)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	defer rows.Close()

	items := make([]map[string]any, 0)
	for rows.Next() {
		var id, typ, title, addedAt string
		var year, duration sql.NullInt64
		var rating sql.NullFloat64
		var posterPath, backdropPath sql.NullString
		var progPos, progDur sql.NullInt64
		var progUpdatedAt sql.NullString

		if err := rows.Scan(&id, &typ, &title, &year, &duration, &addedAt, &rating,
			&posterPath, &backdropPath,
			&progPos, &progDur, &progUpdatedAt); err != nil {
			writeErr(w, http.StatusInternalServerError, "db_error")
			return
		}

		var p map[string]any
		if progPos.Valid {
			p = map[string]any{
				"positionSeconds": progPos.Int64,
				"durationSeconds": progDur.Int64,
				"updatedAt":       progUpdatedAt.String,
			}
		}

		item := map[string]any{
			"id":              id,
			"type":            typ,
			"title":           title,
			"year":            nullIntToAny(year),
			"durationSeconds": nullIntToAny(duration),
			"addedAt":         addedAt,
			"rating":          nullFloatToAny(rating),
			"posterImageId":   nil,
			"backdropImageId": nil,
		}

		if posterPath.Valid && posterPath.String != "" {
			item["posterImageId"] = id
		}
		if backdropPath.Valid && backdropPath.String != "" {
			item["backdropImageId"] = id
		}

		if p != nil {
			item["progress"] = p
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"total": total, "items": items})
}

func (s *Server) handleItemsByFolder(w http.ResponseWriter, r *http.Request, libraryID string, u authedUser) {
	// Get the library root path to compute relative folders
	var libRoot string
	switch libraryID {
	case "lib_movies":
		libRoot = s.cfg.MoviesPath
	case "lib_tv":
		libRoot = s.cfg.TVPath
	default:
		writeErr(w, http.StatusBadRequest, "invalid_library")
		return
	}

	rows, err := s.db.Query("SELECT path FROM items WHERE library_id = ?", libraryID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	defer rows.Close()

	folderCounts := map[string]int{}
	for rows.Next() {
		var path string
		if err := rows.Scan(&path); err != nil {
			continue
		}
		// Get the relative path from library root, extract first directory
		rel := strings.TrimPrefix(path, filepath.Clean(libRoot)+"/")
		parts := strings.SplitN(rel, "/", 2)
		if len(parts) > 1 {
			// Has a subdirectory
			folderCounts[parts[0]]++
		} else {
			// Root-level file
			folderCounts[""]++
		}
	}

	folders := make([]map[string]any, 0, len(folderCounts))
	for name, count := range folderCounts {
		if name == "" {
			continue
		}
		folders = append(folders, map[string]any{
			"name":  name,
			"count": count,
		})
	}

	writeJSON(w, http.StatusOK, map[string]any{"folders": folders})
}

func (s *Server) handleItemsJustWatched(w http.ResponseWriter, r *http.Request, libraryID string, u authedUser, limit, offset int) {
	var where string
	var args []any

	args = append(args, u.ID)
	if libraryID != "" {
		where = "AND i.library_id = ?"
		args = append(args, libraryID)
	}

	countSQL := `SELECT COUNT(*) FROM items i
		INNER JOIN progress p ON p.item_id = i.id AND p.user_id = ?
		WHERE 1=1 ` + where
	var total int
	if err := s.db.QueryRow(countSQL, args...).Scan(&total); err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}

	rows, err := s.db.Query(
		`SELECT i.id, i.type, i.title, i.year, i.duration_seconds, i.added_at, i.rating, i.poster_path, i.backdrop_path, i.overview
		 FROM items i
		 INNER JOIN progress p ON p.item_id = i.id AND p.user_id = ?
		 WHERE 1=1 `+where+` ORDER BY p.updated_at DESC LIMIT ? OFFSET ?`,
		append(args, limit, offset)...,
	)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}

	// Drain rows to a slice first so the cursor is closed before the batch progress query.
	type jwRow struct {
		id, typ, title, addedAt            string
		year, duration                     sql.NullInt64
		rating                             sql.NullFloat64
		posterPath, backdropPath, overview sql.NullString
	}
	var rawRows []jwRow
	for rows.Next() {
		var r jwRow
		if err := rows.Scan(&r.id, &r.typ, &r.title, &r.year, &r.duration, &r.addedAt, &r.rating, &r.posterPath, &r.backdropPath, &r.overview); err != nil {
			rows.Close()
			writeErr(w, http.StatusInternalServerError, "db_error")
			return
		}
		rawRows = append(rawRows, r)
	}
	rows.Close()

	// Batch-fetch progress for all returned items in a single query.
	ids := make([]string, len(rawRows))
	for i, r := range rawRows {
		ids[i] = r.id
	}
	progressMap := s.getProgressBatch(u.ID, ids)

	items := make([]map[string]any, 0, len(rawRows))
	for _, r := range rawRows {
		item := map[string]any{
			"id":              r.id,
			"type":            r.typ,
			"title":           r.title,
			"year":            nullIntToAny(r.year),
			"durationSeconds": nullIntToAny(r.duration),
			"addedAt":         r.addedAt,
			"rating":          nullFloatToAny(r.rating),
			"posterImageId":   nil,
			"backdropImageId": nil,
		}

		if r.posterPath.Valid && r.posterPath.String != "" {
			item["posterImageId"] = r.id
		}
		if r.backdropPath.Valid && r.backdropPath.String != "" {
			item["backdropImageId"] = r.id
		}

		if p, ok := progressMap[r.id]; ok {
			item["progress"] = p
		}
		items = append(items, item)
	}
	writeJSON(w, http.StatusOK, map[string]any{"total": total, "items": items})
}

func (s *Server) handleItemDetail(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	row := s.db.QueryRow(`
		SELECT id, library_id, type, title, year, duration_seconds,
		       original_title, overview, rating, genres, director, cast_names,
		       content_rating, poster_path, backdrop_path, tmdb_id, imdb_id,
		       show_name, season_number, episode_number, episode_title, change_seq,
		       video_codec, audio_codec, container, video_width, video_height, audio_channels
		FROM items WHERE id = ?`, id)

	var itemID, libraryID, typ, title string
	var year, duration, tmdbID, seasonNum, episodeNum, changeSeq sql.NullInt64
	var originalTitle, overview, genres, director, castNames sql.NullString
	var contentRating, posterPath, backdropPath, imdbID sql.NullString
	var showName, episodeTitle sql.NullString
	var rating sql.NullFloat64
	var videoCodec, audioCodec, container sql.NullString
	var videoWidth, videoHeight, audioChannels sql.NullInt64

	if err := row.Scan(&itemID, &libraryID, &typ, &title, &year, &duration,
		&originalTitle, &overview, &rating, &genres, &director, &castNames,
		&contentRating, &posterPath, &backdropPath, &tmdbID, &imdbID,
		&showName, &seasonNum, &episodeNum, &episodeTitle, &changeSeq,
		&videoCodec, &audioCodec, &container, &videoWidth, &videoHeight, &audioChannels); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeErr(w, http.StatusNotFound, "not_found")
			return
		}
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}

	// Parse genres from comma-separated string
	var genreList []string
	if genres.Valid && genres.String != "" {
		genreList = strings.Split(genres.String, ",")
	}

	// Parse cast from comma-separated string
	var castList []map[string]any
	if castNames.Valid && castNames.String != "" {
		for _, name := range strings.Split(castNames.String, ",") {
			castList = append(castList, map[string]any{"name": strings.TrimSpace(name)})
		}
	}

	// Build images object
	images := map[string]any{
		"poster":   map[string]any{"id": nil},
		"backdrop": map[string]any{"id": nil},
	}
	if posterPath.Valid && posterPath.String != "" {
		images["poster"] = map[string]any{"id": itemID}
	}
	if backdropPath.Valid && backdropPath.String != "" {
		images["backdrop"] = map[string]any{"id": itemID}
	}

	resp := map[string]any{
		"id":              itemID,
		"type":            typ,
		"title":           title,
		"originalTitle":   nullStringToAny(originalTitle),
		"year":            nullIntToAny(year),
		"durationSeconds": nullIntToAny(duration),
		"contentRating":   nullStringToAny(contentRating),
		"summary":         nullStringToAny(overview),
		"rating":          nullFloatToAny(rating),
		"genres":          genreList,
		"cast":            castList,
		"director":        nullStringToAny(director),
		"images":          images,
		"tmdbId":          nullIntToAny(tmdbID),
		"imdbId":          nullStringToAny(imdbID),
		"changeSeq":       nullIntToAny(changeSeq),
		// TASK-728: media specs for client quality/format badges (4K/HDR/Atmos) and
		// a tech-spec row. Null when the item hasn't been fully probed yet.
		"videoCodec":    nullStringToAny(videoCodec),
		"audioCodec":    nullStringToAny(audioCodec),
		"container":     nullStringToAny(container),
		"width":         nullIntToAny(videoWidth),
		"height":        nullIntToAny(videoHeight),
		"audioChannels": nullIntToAny(audioChannels),
	}

	// Add TV-specific fields
	if typ == "episode" {
		resp["showName"] = nullStringToAny(showName)
		resp["seasonNumber"] = nullIntToAny(seasonNum)
		resp["episodeNumber"] = nullIntToAny(episodeNum)
		resp["episodeTitle"] = nullStringToAny(episodeTitle)
	}

	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handleShowsList(w http.ResponseWriter, r *http.Request) {
	if s.cfg.TVPath == "" {
		writeJSON(w, http.StatusOK, map[string]any{"shows": []any{}})
		return
	}
	u := userFromCtx(r.Context())
	tvRoot := filepath.Clean(s.cfg.TVPath) + "/"

	rows, err := s.db.Query(`
		SELECT id, path, show_name, year, rating, poster_path, backdrop_path, overview, genres
		FROM items WHERE library_id = 'lib_tv'`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	defer rows.Close()

	type showInfo struct {
		folderName  string // folder on disk (used as key and for matching)
		displayName string // TMDb name if available, else folder name
		year        sql.NullInt64
		rating      sql.NullFloat64
		poster      string
		backdrop    string
		overview    string
		genres      string
		count       int
		firstID     string // first episode ID with poster
	}

	// Group by folder name (first directory component relative to TV root)
	showMap := map[string]*showInfo{}
	showOrder := []string{}

	for rows.Next() {
		var id, path string
		var showName sql.NullString
		var year sql.NullInt64
		var rating sql.NullFloat64
		var posterPath, backdropPath, overview, genres sql.NullString

		if err := rows.Scan(&id, &path, &showName, &year, &rating, &posterPath, &backdropPath, &overview, &genres); err != nil {
			continue
		}

		// Always group by folder name from path for consistency
		var folderName string
		rel := strings.TrimPrefix(path, tvRoot)
		parts := strings.SplitN(rel, "/", 2)
		if len(parts) > 1 {
			folderName = parts[0]
		} else {
			// Root-level file, use filename without extension
			base := filepath.Base(path)
			folderName = strings.TrimSuffix(base, filepath.Ext(base))
		}

		if folderName == "" {
			continue
		}

		info, exists := showMap[folderName]
		if !exists {
			info = &showInfo{folderName: folderName, displayName: folderName}
			showMap[folderName] = info
			showOrder = append(showOrder, folderName)
		}

		// Prefer TMDb show_name as display name
		if showName.Valid && showName.String != "" && info.displayName == info.folderName {
			info.displayName = showName.String
		}

		info.count++
		if year.Valid && (!info.year.Valid || year.Int64 < info.year.Int64) {
			info.year = year
		}
		if rating.Valid && (!info.rating.Valid || rating.Float64 > info.rating.Float64) {
			info.rating = rating
		}
		if posterPath.Valid && posterPath.String != "" && info.poster == "" {
			info.poster = posterPath.String
			info.firstID = id
		}
		if backdropPath.Valid && backdropPath.String != "" && info.backdrop == "" {
			info.backdrop = backdropPath.String
		}
		if overview.Valid && overview.String != "" && info.overview == "" {
			info.overview = overview.String
		}
		if genres.Valid && genres.String != "" && info.genres == "" {
			info.genres = genres.String
		}
	}

	// Sort alphabetically by display name
	sortedKeys := make([]string, len(showOrder))
	copy(sortedKeys, showOrder)
	sort.Slice(sortedKeys, func(i, j int) bool {
		return strings.ToLower(showMap[sortedKeys[i]].displayName) < strings.ToLower(showMap[sortedKeys[j]].displayName)
	})

	shows := make([]map[string]any, 0, len(sortedKeys))
	for _, key := range sortedKeys {
		info := showMap[key]

		show := map[string]any{
			"showName":      info.displayName,
			"folderName":    info.folderName,
			"year":          nullIntToAny(info.year),
			"rating":        nullFloatToAny(info.rating),
			"posterImageId": nil,
			"overview":      nil,
			"episodeCount":  info.count,
		}

		if info.overview != "" {
			show["overview"] = info.overview
		}
		if info.firstID != "" {
			show["posterImageId"] = info.firstID
		}

		_ = u // available for future watched count queries
		shows = append(shows, show)
	}

	writeJSON(w, http.StatusOK, map[string]any{"shows": shows})
}

func (s *Server) handleShowDetail(w http.ResponseWriter, r *http.Request) {
	if s.cfg.TVPath == "" {
		writeErr(w, http.StatusNotFound, "not_found")
		return
	}
	showName := chi.URLParam(r, "showName")
	if showName == "" {
		writeErr(w, http.StatusBadRequest, "missing_show_name")
		return
	}

	// URL decode the show name
	decoded, err := url.PathUnescape(showName)
	if err == nil {
		showName = decoded
	}
	if strings.Contains(showName, "/") || strings.Contains(showName, "..") {
		writeErr(w, http.StatusBadRequest, "invalid_show_id")
		return
	}

	u := userFromCtx(r.Context())
	tvRoot := filepath.Clean(s.cfg.TVPath) + "/"
	folderPrefix := tvRoot + showName + "/"

	// Match items by folder path only — show_name is not unique across folders
	// (e.g. two folders named "MacGyver 1985" and "MacGyver" can both have show_name="MacGyver")
	matchWhere := "path LIKE ?"
	matchArgs := []any{folderPrefix + "%"}

	// Get show-level metadata from first episode with data
	var year sql.NullInt64
	var rating sql.NullFloat64
	var posterPath, backdropPath, overview, genres, director sql.NullString
	s.db.QueryRow(`
		SELECT MAX(year), MAX(rating), MAX(poster_path), MAX(backdrop_path),
		       MAX(overview), MAX(genres), MAX(director)
		FROM items WHERE `+matchWhere+` AND library_id = 'lib_tv'`, matchArgs...).Scan(
		&year, &rating, &posterPath, &backdropPath, &overview, &genres, &director)

	// Get all episodes grouped by season
	rows, err := s.db.Query(`
		SELECT id, title, season_number, episode_number, episode_title, duration_seconds, poster_path
		FROM items
		WHERE `+matchWhere+` AND library_id = 'lib_tv'
		ORDER BY COALESCE(season_number, 0), COALESCE(episode_number, 0)`,
		matchArgs...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	defer rows.Close()

	type episode struct {
		data   map[string]any
		season int
	}
	var episodes []episode
	seasonSet := map[int]bool{}

	for rows.Next() {
		var id, title string
		var seasonNum, episodeNum, duration sql.NullInt64
		var epTitle, epPoster sql.NullString

		if err := rows.Scan(&id, &title, &seasonNum, &episodeNum, &epTitle, &duration, &epPoster); err != nil {
			continue
		}

		// Get progress for this episode
		p, _ := s.getProgress(u.ID, id)

		watched := false
		if p != nil {
			pos, _ := p["positionSeconds"].(int)
			dur, _ := p["durationSeconds"].(int)
			if dur > 0 && float64(pos)/float64(dur) >= 0.85 {
				watched = true
			}
		}

		sn := 1
		if seasonNum.Valid {
			sn = int(seasonNum.Int64)
		}
		seasonSet[sn] = true

		ep := map[string]any{
			"id":              id,
			"title":           nullStringToAny(epTitle),
			"episodeNumber":   nullIntToAny(episodeNum),
			"seasonNumber":    sn,
			"durationSeconds": nullIntToAny(duration),
			"watched":         watched,
			"progress":        p,
		}

		episodes = append(episodes, episode{data: ep, season: sn})
	}

	// Build seasons array
	seasons := make([]map[string]any, 0)
	for sn := range seasonSet {
		var seasonEps []map[string]any
		for _, ep := range episodes {
			if ep.season == sn {
				seasonEps = append(seasonEps, ep.data)
			}
		}
		seasons = append(seasons, map[string]any{
			"seasonNumber": sn,
			"episodes":     seasonEps,
		})
	}

	// Sort seasons by number — use a safe type switch to avoid panics if DB
	// returns int64 (SQLite scanner default) instead of int.
	toSeasonInt := func(v any) int {
		switch x := v.(type) {
		case int:
			return x
		case int64:
			return int(x)
		default:
			return 0
		}
	}
	for i := 0; i < len(seasons); i++ {
		for j := i + 1; j < len(seasons); j++ {
			si := toSeasonInt(seasons[i]["seasonNumber"])
			sj := toSeasonInt(seasons[j]["seasonNumber"])
			if si > sj {
				seasons[i], seasons[j] = seasons[j], seasons[i]
			}
		}
	}

	// Build images
	images := map[string]any{
		"poster":   map[string]any{"id": nil},
		"backdrop": map[string]any{"id": nil},
	}
	// Pick the artwork-bearing episode DETERMINISTICALLY.
	//
	// These queries had no ORDER BY, so which episode's art represented the show was
	// whatever SQLite happened to return first — and that could change between scans.
	// It matters most for a folder whose subfolders are separate series rather than
	// seasons (the library has one: "X-Men - ANIME Series and CARTOON Series", holding
	// both an anime and a cartoon show). matchWhere scopes to the first path segment,
	// so without an ordering the anime's poster could represent the cartoon.
	//
	// ORDER BY path makes the choice stable and picks the first episode in on-disk order,
	// which is the closest thing to "the show's own artwork" available without changing
	// how shows are grouped. Grouping is deliberately left alone: of 82 show folders, ~40
	// nest season directories correctly and only one nests distinct series, so deepening
	// the heuristic would break 40 shows to fix one.
	if posterPath.Valid && posterPath.String != "" {
		var firstEpID string
		s.db.QueryRow("SELECT id FROM items WHERE "+matchWhere+" AND poster_path IS NOT NULL AND poster_path != '' AND library_id = 'lib_tv' ORDER BY path LIMIT 1",
			matchArgs...).Scan(&firstEpID)
		if firstEpID != "" {
			images["poster"] = map[string]any{"id": firstEpID}
		}
	}
	if backdropPath.Valid && backdropPath.String != "" {
		var firstEpID string
		s.db.QueryRow("SELECT id FROM items WHERE "+matchWhere+" AND backdrop_path IS NOT NULL AND backdrop_path != '' AND library_id = 'lib_tv' ORDER BY path LIMIT 1",
			matchArgs...).Scan(&firstEpID)
		if firstEpID != "" {
			images["backdrop"] = map[string]any{"id": firstEpID}
		}
	}

	var genreList []string
	if genres.Valid && genres.String != "" {
		genreList = strings.Split(genres.String, ",")
	}

	// Use TMDb show_name as display name if available
	displayName := showName
	var tmdbName sql.NullString
	// Same determinism problem as the artwork queries above.
	s.db.QueryRow("SELECT show_name FROM items WHERE "+matchWhere+" AND show_name IS NOT NULL AND show_name != '' AND library_id = 'lib_tv' ORDER BY path LIMIT 1",
		matchArgs...).Scan(&tmdbName)
	if tmdbName.Valid && tmdbName.String != "" {
		displayName = tmdbName.String
	}

	resp := map[string]any{
		"showName": displayName,
		"year":     nullIntToAny(year),
		"rating":   nullFloatToAny(rating),
		"summary":  nullStringToAny(overview),
		"genres":   genreList,
		"director": nullStringToAny(director),
		"images":   images,
		"seasons":  seasons,
	}

	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handleImage(w http.ResponseWriter, r *http.Request) {
	imageID := chi.URLParam(r, "id")
	if imageID == "" {
		writeErr(w, http.StatusBadRequest, "missing_image_id")
		return
	}

	// Check if it's a TMDb path reference (starts with /)
	// These come from poster_path or backdrop_path stored in database
	tmdbPath := r.URL.Query().Get("tmdb")
	width := r.URL.Query().Get("w")

	if tmdbPath != "" {
		// Fetch from TMDb and cache
		if s.imageCache == nil {
			writeErr(w, http.StatusServiceUnavailable, "image_cache_unavailable")
			return
		}

		size := metadata.ParseImageSize(width)
		cachedPath, err := s.imageCache.GetOrCacheTMDbImage(r.Context(), tmdbPath, metadata.ImageTypePoster, size)
		if err != nil {
			log.Printf("Failed to cache TMDb image %s: %v", tmdbPath, err)
			writeErr(w, http.StatusNotFound, "image_not_found")
			return
		}

		w.Header().Set("Cache-Control", "public, max-age=604800") // 7 days
		http.ServeFile(w, r, cachedPath)
		return
	}

	// Look up image by ID in database
	var tmdbPathDB sql.NullString
	var imageType sql.NullString
	var cachedPath sql.NullString

	err := s.db.QueryRow(
		"SELECT tmdb_path, image_type, cached_path FROM images WHERE id = ?",
		imageID,
	).Scan(&tmdbPathDB, &imageType, &cachedPath)

	if err == nil && cachedPath.Valid {
		// Serve from cache
		if _, err := os.Stat(cachedPath.String); err == nil {
			// IMAGE-CACHE FIX: this is the hot path (image already cached on the
			// server, served by ID) and was the ONLY image path missing a
			// Cache-Control header. Without it the client's URLCache won't persist
			// posters, so every cold launch re-downloaded all artwork over the
			// network (~10-15s of blank posters). Match the 7-day TTL the other
			// image paths already set. Client caching is unchanged.
			w.Header().Set("Cache-Control", "public, max-age=604800") // 7 days
			http.ServeFile(w, r, cachedPath.String)
			return
		}
	}

	if err == nil && tmdbPathDB.Valid {
		// Fetch and cache from TMDb
		size := metadata.ParseImageSize(width)
		imgType := metadata.ImageTypePoster
		if imageType.Valid {
			imgType = metadata.ImageType(imageType.String)
		}

		cached, err := s.imageCache.GetOrCacheTMDbImage(r.Context(), tmdbPathDB.String, imgType, size)
		if err != nil {
			writeErr(w, http.StatusNotFound, "image_not_found")
			return
		}

		// Update cache path in database
		_, _ = s.db.Exec(
			"UPDATE images SET cached_path = ?, cached_at = ? WHERE id = ?",
			cached, time.Now().UTC().Format(time.RFC3339), imageID,
		)

		w.Header().Set("Cache-Control", "public, max-age=604800") // 7 days
		http.ServeFile(w, r, cached)
		return
	}

	// Try to look up by item ID (for poster/backdrop)
	var posterPath, backdropPath sql.NullString
	err = s.db.QueryRow(
		"SELECT poster_path, backdrop_path FROM items WHERE id = ?",
		imageID,
	).Scan(&posterPath, &backdropPath)

	if err != nil {
		writeErr(w, http.StatusNotFound, "image_not_found")
		return
	}

	// Determine which image to serve based on query param
	imageTypeParam := r.URL.Query().Get("type")
	var path string
	var imgType metadata.ImageType

	if imageTypeParam == "backdrop" && backdropPath.Valid {
		path = backdropPath.String
		imgType = metadata.ImageTypeBackdrop
	} else if posterPath.Valid {
		path = posterPath.String
		imgType = metadata.ImageTypePoster
	} else if backdropPath.Valid {
		path = backdropPath.String
		imgType = metadata.ImageTypeBackdrop
	} else {
		writeErr(w, http.StatusNotFound, "no_image_available")
		return
	}

	size := metadata.ParseImageSize(width)
	cached, err := s.imageCache.GetOrCacheTMDbImage(r.Context(), path, imgType, size)
	if err != nil {
		log.Printf("Failed to cache image: %v", err)
		writeErr(w, http.StatusNotFound, "image_not_found")
		return
	}

	w.Header().Set("Cache-Control", "public, max-age=604800") // 7 days
	http.ServeFile(w, r, cached)
}

// handleTMDbImageProxy proxies a TMDb poster image through the backend so the
// iOS app never constructs direct cdn.tmdb.org URLs.
// GET /api/v1/tmdb/image?path=/abc.jpg
func (s *Server) handleTMDbImageProxy(w http.ResponseWriter, r *http.Request) {
	tmdbPath := strings.TrimSpace(r.URL.Query().Get("path"))
	if tmdbPath == "" {
		writeErr(w, http.StatusBadRequest, "missing_path")
		return
	}
	// Ensure path starts with / and contains no traversal sequences.
	if !strings.HasPrefix(tmdbPath, "/") || strings.Contains(tmdbPath, "..") {
		writeErr(w, http.StatusBadRequest, "invalid_path")
		return
	}

	if s.imageCache == nil {
		writeErr(w, http.StatusServiceUnavailable, "image_cache_unavailable")
		return
	}

	width := r.URL.Query().Get("w")
	size := metadata.ParseImageSize(width)
	cachedPath, err := s.imageCache.GetOrCacheTMDbImage(r.Context(), tmdbPath, metadata.ImageTypePoster, size)
	if err != nil {
		log.Printf("[TMDbProxy] failed to proxy %s: %v", tmdbPath, err)
		writeErr(w, http.StatusBadGateway, "image_fetch_failed")
		return
	}

	w.Header().Set("Cache-Control", "public, max-age=604800") // 7 days
	http.ServeFile(w, r, cachedPath)
}

// -------------------------
// Playback
// -------------------------

func (s *Server) handlePlayback(w http.ResponseWriter, r *http.Request) {
	itemID := chi.URLParam(r, "id")

	// Query item with codec info
	var path string
	var videoCodec, audioCodec, container sql.NullString
	var needsTranscode sql.NullBool
	// durationSeconds is the authoritative full runtime from the scan-time probe. We
	// return it in the playback response so the client can show a correct scrubber
	// even while transcoding: a live-window HLS playlist only reports the duration
	// generated SO FAR (the file transcodes at ~5x realtime, so most isn't written at
	// playback start), which made AVPlayer's scrubber pin to the end. The client uses
	// this value instead of playerItem.duration when it's larger.
	var itemDuration sql.NullInt64
	err := s.db.QueryRow(
		"SELECT path, video_codec, audio_codec, container, needs_transcode, duration_seconds FROM items WHERE id = ?",
		itemID,
	).Scan(&path, &videoCodec, &audioCodec, &container, &needsTranscode, &itemDuration)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeErr(w, http.StatusNotFound, "not_found")
			return
		}
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}

	// Security: verify the DB-stored path is within a configured media root.
	// Prevents path traversal if the database is tampered with. TASK-800: shared with
	// trickplay + subtitle extraction via pathWithinMediaRoot so every path→ffmpeg site
	// enforces the same guard, not just playback.
	if !s.pathWithinMediaRoot(path) {
		log.Printf("[Playback] SECURITY: path %q not within any configured media root — rejecting", filepath.Clean(path))
		writeErr(w, http.StatusForbidden, "path_not_allowed")
		return
	}

	// P1-4: verify the file actually exists before doing anything else. The 216 orphaned
	// .mkv rows (external library conversion renamed files out from under the DB) pointed
	// HLS-mode items at a missing file: StartSession would spawn a transcode that never
	// produced master.m3u8, and the client hung ~30s in WaitForPlaylist before a 503.
	// Stat the SAME path that gets played downstream (StartSession / ps.Path use `path`,
	// not cleanedPath) so a renamed/missing file fails fast and cleanly with 404.
	if _, err := os.Stat(path); err != nil {
		writeErr(w, http.StatusNotFound, "media_missing")
		return
	}

	// TASK-755: if auto-normalize is mid-swap on this exact item — the brief window
	// where the original is being moved aside and the new .mp4 renamed into place —
	// the file on disk is in flux. Return 409 {"status":"converting"} so the client
	// retries in a moment rather than opening a file that's about to be replaced.
	// IMPORTANT: IsConverting is ONLY true during that tiny mid-swap window, NOT for
	// the whole encode. While an item is merely queued or actively encoding it stays
	// OUT of the set, so normal on-demand playback (the existing transcode path) keeps
	// working — slowly — and the 409 window stays a couple of filesystem renames long.
	if s.normalizeWorker != nil && s.normalizeWorker.IsConverting(itemID) {
		writeJSON(w, http.StatusConflict, map[string]any{"status": "converting"})
		return
	}

	// Determine playback mode based on codec info
	var playbackMode transcode.PlaybackMode
	var probeResult *transcode.ProbeResult

	if videoCodec.Valid && audioCodec.Valid && container.Valid {
		// Use stored codec info
		playbackMode = transcode.DecidePlayback(videoCodec.String, audioCodec.String, container.String)

		// Stale-metadata guard: a wrong FullTranscode decision is catastrophic on this
		// software-only NAS — re-encoding an already-H.264 file runs slower than realtime,
		// so master.m3u8 misses the client's 30s window and playback 503s. This is exactly
		// what the library conversion produces: it rewrites files mpeg4→h264 but the DB row
		// keeps the old "mpeg4" codec, so the server tries to transcode a file that should
		// DirectPlay. (Wrong DirectPlay/Remux decisions are cheap and fail fast, so we only
		// pay the verification cost on the expensive branch.) Re-probe to confirm; if the
		// real codecs disagree, use the truth and self-heal the DB so the next play is fast.
		if playbackMode == transcode.FullTranscode && s.prober != nil {
			ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
			if pr, err := s.prober.Probe(ctx, path); err == nil {
				verified := transcode.DecidePlaybackFromProbe(pr)
				if verified != transcode.FullTranscode {
					log.Printf("[Playback] stale metadata for %s: DB said %s/%s/%s (transcode) but probe says %s/%s/%s (%s) — using probe + healing DB",
						itemID, videoCodec.String, audioCodec.String, container.String,
						pr.VideoCodec, pr.AudioCodec, pr.Container, verified)
					probeResult = pr
					playbackMode = verified
					go s.updateCodecInfo(itemID, pr)
				}
			}
			cancel()
		}
	} else {
		// Fall back to quick probe (file extension heuristics)
		probeResult = transcode.ProbeQuick(path)
		playbackMode = transcode.DecidePlaybackFromProbe(probeResult)

		// Try to probe properly if prober is available
		if s.prober != nil {
			ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
			defer cancel()
			if pr, err := s.prober.Probe(ctx, path); err == nil {
				probeResult = pr
				playbackMode = transcode.DecidePlaybackFromProbe(pr)
				// Update the database with probe results
				go s.updateCodecInfo(itemID, pr)
			}
		}
	}

	// Quality cap: map ?quality= param to a max height for transcoding
	qualityParam := r.URL.Query().Get("quality")
	var maxHeight int
	switch qualityParam {
	case "480p":
		maxHeight = 480
	case "720p":
		maxHeight = 720
	case "1080p":
		maxHeight = 1080
	default:
		maxHeight = 0
	}

	// Web browser clients have stricter codec requirements than native Apple apps.
	// Browsers only support MP4 + H.264 + AAC/MP3 for direct play.
	// HEVC, MKV, AC3, DTS etc. all need transcoding for web playback.
	isWebClient := r.URL.Query().Get("client") == "web"
	if isWebClient && playbackMode == transcode.DirectPlay {
		vc := videoCodec.String
		ac := audioCodec.String
		ct := container.String
		if probeResult != nil {
			vc = probeResult.VideoCodec
			ac = probeResult.AudioCodec
			ct = probeResult.Container
		}
		// Web browsers only reliably play H.264 video (not HEVC/VP9/AV1)
		webVideoOK := vc == "h264"
		webAudioOK := ac == "aac" || ac == "mp3"
		webContainerOK := ct == "mp4" || ct == "mov" || ct == "m4v"
		if !webVideoOK || !webAudioOK || !webContainerOK {
			if webVideoOK {
				playbackMode = transcode.RemuxOnly
			} else {
				playbackMode = transcode.FullTranscode
			}
			log.Printf("[Playback] Web client override: %s (video=%s audio=%s container=%s)", playbackMode, vc, ac, ct)
		}
	}

	sessionID := randID("sess_")

	// Detect subtitle files alongside the video for HLS subtitle renditions.
	subtitleOffset := 0.0
	if v, err := strconv.ParseFloat(r.URL.Query().Get("subtitleOffset"), 64); err == nil {
		subtitleOffset = v
	}
	subtitleTracks := findSubtitleFiles(path, subtitleOffset)
	// TASK-739: also expose text subtitle tracks embedded in the container (e.g. MKV
	// internal SRT/ASS) so they're selectable like external files.
	//
	// /playback non-blocking subs fix (follow-up to TASK-752): this call MUST NOT run
	// ffmpeg synchronously. It only returns tracks whose .srt is ALREADY cached; any
	// missing track is extracted in a limiter-gated background worker and shows up on a
	// later play. We hand it the probe we already did above (probeResult) instead of
	// re-probing inside the request. If probeResult is nil (codec came from the DB, so no
	// live probe ran this request), we skip embedded subs this time — they'll populate on
	// a future play that does probe. findSubtitleFiles (external sidecars) stays
	// synchronous: it's pure filesystem, no ffmpeg.
	subtitleTracks = append(subtitleTracks, s.collectEmbeddedSubtitles(itemID, path, subtitleOffset, probeResult)...)

	// TASK-826: classify each track (full / forced / image) and mark the single best
	// forced track for auto-enable. Runtime comes from the authoritative DB duration,
	// falling back to the live probe; audio language from the probe (empty when the
	// codec came from the DB and no live probe ran this request — then only forced
	// flags/tokens drive classification, cue-density and audio-match are skipped).
	runtimeSecs := 0.0
	if itemDuration.Valid {
		runtimeSecs = float64(itemDuration.Int64)
	} else if probeResult != nil {
		runtimeSecs = probeResult.DurationSecs
	}
	audioLang := ""
	if probeResult != nil {
		audioLang = probeResult.AudioLang
	}
	classifySubtitleTracks(subtitleTracks, runtimeSecs, audioLang)

	ps := PlaySession{
		ItemID:       itemID,
		Path:         path,
		CreatedAt:    time.Now(),
		LastAccess:   time.Now(),
		PlaybackMode: playbackMode,
	}

	// Determine playback kind based on mode
	if playbackMode == transcode.DirectPlay {
		ps.Kind = "direct"
	} else if isWebClient && playbackMode == transcode.RemuxOnly {
		// For web clients needing remux (MKV+H264 or MP4+H264+AC3),
		// stream a remuxed fragmented MP4 in real-time through ffmpeg.
		// This is much faster than full HLS generation (just copies video stream).
		ps.Kind = "remux"
		ps.Transcoding = true
	} else {
		ps.Kind = "hls"
		ps.Transcoding = true

		// Start HLS transcoding session
		if s.hlsGenerator != nil {
			hlsSession, err := s.hlsGenerator.StartSession(r.Context(), sessionID, path, playbackMode, maxHeight, subtitleTracks)
			if err != nil {
				log.Printf("Failed to start transcode session: %v", err)
				writeErr(w, http.StatusServiceUnavailable, "transcode_busy")
				return
			}
			ps.HLSDir = hlsSession.OutputDir
		} else {
			// No HLS generator - fall back to direct serving for web clients
			// (browser may or may not handle the format, but it's better than nothing)
			if isWebClient {
				log.Printf("[Playback] No ffmpeg available, falling back to direct serve for web client")
				ps.Kind = "direct"
				ps.Transcoding = false
			} else {
				// TASK-818: hlsGenerator is constructed unconditionally in NewServer
				// (NewHLSGenerator never returns nil, even when ffmpeg is absent), so
				// this branch is unreachable in practice. The former legacyGenerateHLS
				// fallback spawned a bare, uncancellable ffmpeg that bypassed the shared
				// TASK-752 budget and leaked on session teardown; it has been removed.
				// If we ever do land here, fail cleanly rather than start an untracked
				// transcode.
				log.Printf("[Playback] No HLS generator available for non-web client — cannot transcode")
				writeErr(w, http.StatusServiceUnavailable, "transcode_unavailable")
				return
			}
		}
	}

	s.mu.Lock()
	s.playSessions[sessionID] = ps
	s.mu.Unlock()

	u := userFromCtx(r.Context())
	resume, _ := s.getProgress(u.ID, itemID)
	var resumePos any = 0
	if resume != nil {
		if v, ok := resume["positionSeconds"].(int); ok {
			resumePos = v
		}
	}

	baseURL := requestBaseURL(r, s.cfg.BaseURL)

	// Build chapter list for response
	var chapterList []map[string]any
	if probeResult != nil && len(probeResult.Chapters) > 0 {
		for _, c := range probeResult.Chapters {
			chapterList = append(chapterList, map[string]any{
				"id":        c.ID,
				"title":     c.Title,
				"startSecs": c.StartSecs,
				"endSecs":   c.EndSecs,
			})
		}
	}
	// For direct play, try a quick probe for chapters if we don't already have them
	if chapterList == nil && (ps.Kind == "direct" || ps.Kind == "remux") && s.prober != nil {
		ctx2, cancel2 := context.WithTimeout(r.Context(), 8*time.Second)
		defer cancel2()
		if pr, err := s.prober.Probe(ctx2, path); err == nil && len(pr.Chapters) > 0 {
			for _, c := range pr.Chapters {
				chapterList = append(chapterList, map[string]any{
					"id":        c.ID,
					"title":     c.Title,
					"startSecs": c.StartSecs,
					"endSecs":   c.EndSecs,
				})
			}
		}
	}
	if chapterList == nil {
		chapterList = []map[string]any{}
	}

	qualityOut := qualityParam
	if qualityOut == "" {
		qualityOut = "auto"
	}

	// Build subtitle info for the response so the client knows tracks are available.
	// TASK-826 contract: each entry carries classification + auto-enable metadata.
	// See .claude/scratch/subtitle-api-contract.md for the frozen field list.
	subtitleInfo := make([]map[string]any, 0, len(subtitleTracks))
	for i, t := range subtitleTracks {
		typ := t.Type
		if typ == "" {
			typ = "full"
		}
		subtitleInfo = append(subtitleInfo, map[string]any{
			// url: the HLS subtitle rendition selector index for this track. Clients
			// select the matching #EXT-X-MEDIA rendition (subtitle_<i>) in the master
			// playlist; image subs produce no rendition and carry url "".
			"url":        subtitleTrackURL(baseURL, sessionID, ps.Kind, t, i),
			"language":   t.Language,
			"name":       t.Name,
			"type":       typ,
			"forced":     t.Forced,
			"default":    t.Default,
			"autoEnable": t.AutoEnable,
		})
	}

	if ps.Kind == "direct" || ps.Kind == "remux" {
		writeJSON(w, http.StatusOK, map[string]any{
			"kind":                  "direct",
			"streamUrl":             baseURL + "/api/v1/playback/" + sessionID + "/stream",
			"subtitles":             subtitleInfo,
			"audioTracks":           []any{},
			"resumePositionSeconds": resumePos,
			"durationSeconds":       nullIntToAny(itemDuration),
			"transcoding":           ps.Kind == "remux",
			"chapters":              chapterList,
			"quality":               qualityOut,
		})
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"kind":                  "hls",
		"hlsMasterUrl":          baseURL + "/api/v1/playback/" + sessionID + "/master.m3u8",
		"subtitles":             subtitleInfo,
		"audioTracks":           []any{},
		"resumePositionSeconds": resumePos,
		"durationSeconds":       nullIntToAny(itemDuration),
		"transcoding":           true,
		"transcodeMode":         playbackMode.String(),
		"chapters":              chapterList,
		"quality":               qualityOut,
	})
}

// findSubtitleFiles looks for subtitle files alongside videoPath and returns
// SubtitleTrack entries for each found file. Supports .srt, .ass, .ssa, .vtt.
// Language is inferred from filename suffixes like "movie.en.srt" or "movie.fr.srt".
func findSubtitleFiles(videoPath string, offset float64) []transcode.SubtitleTrack {
	dir := filepath.Dir(videoPath)
	base := strings.TrimSuffix(filepath.Base(videoPath), filepath.Ext(videoPath))

	exts := []string{".srt", ".ass", ".ssa", ".vtt"}
	langNames := map[string]string{
		"en": "English", "fr": "French", "de": "German", "es": "Spanish",
		"it": "Italian", "pt": "Portuguese", "nl": "Dutch", "ru": "Russian",
		"ja": "Japanese", "ko": "Korean", "zh": "Chinese", "ar": "Arabic",
		"pl": "Polish", "sv": "Swedish", "da": "Danish", "fi": "Finnish",
		"no": "Norwegian", "cs": "Czech", "hu": "Hungarian", "ro": "Romanian",
		"tr": "Turkish", "he": "Hebrew", "th": "Thai", "vi": "Vietnamese",
	}

	seen := map[string]bool{}
	var tracks []transcode.SubtitleTrack

	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		nameNoExt := strings.TrimSuffix(name, filepath.Ext(name))
		ext := strings.ToLower(filepath.Ext(name))

		isSubExt := false
		for _, e := range exts {
			if ext == e {
				isSubExt = true
				break
			}
		}
		if !isSubExt {
			continue
		}

		// Must match the video base name exactly or as "base.lang" or "base.lang.forced"
		if nameNoExt != base && !strings.HasPrefix(nameNoExt, base+".") {
			continue
		}

		fullPath := filepath.Join(dir, name)
		if seen[fullPath] {
			continue
		}
		seen[fullPath] = true

		// Infer language + forced/default flags from suffix tokens:
		// "movie.en.forced.srt" → lang "en", forced. "movie.fr.default.srt" → default.
		lang := "und"
		displayName := "Subtitles"
		forced := false
		isDefault := false
		suffix := strings.TrimPrefix(nameNoExt, base)
		if suffix != "" {
			parts := strings.Split(strings.TrimPrefix(suffix, "."), ".")
			for _, p := range parts {
				p = strings.ToLower(p)
				switch p {
				case "forced":
					forced = true
					continue
				case "default":
					isDefault = true
					continue
				case "sdh", "cc":
					// full-dialogue variants — carry no forced/default semantics here
					continue
				}
				if lang == "und" && (len(p) == 2 || len(p) == 3) {
					lang = p
					if n, ok := langNames[p]; ok {
						displayName = n
					} else {
						displayName = strings.ToUpper(p)
					}
				}
			}
		}
		if forced {
			displayName += " (Forced)"
		}

		tracks = append(tracks, transcode.SubtitleTrack{
			Language: lang,
			Name:     displayName,
			Path:     fullPath,
			Offset:   offset,
			Forced:   forced,
			Default:  isDefault,
			// Type is finalized by classifySubtitleTracks (cue-density may promote an
			// untagged sidecar to "forced"); default here to the flag-derived value.
			Type: subTypeFromForced(forced),
		})
	}

	return tracks
}

// subtitleTrackURL returns the fetchable URL for a track's HLS subtitle rendition,
// or "" when there is none. Text subtitles are delivered as in-manifest HLS
// renditions (subtitle_<i>.m3u8, served by the {variant}.m3u8 route). Image subs
// produce no rendition, and direct/remux playback has no HLS manifest at all — both
// yield "". The index i matches the rendition ordinal addSubtitleRenditions assigns.
func subtitleTrackURL(baseURL, sessionID, kind string, t transcode.SubtitleTrack, i int) string {
	if kind != "hls" || t.Type == "image" || t.Path == "" {
		return ""
	}
	return fmt.Sprintf("%s/api/v1/playback/%s/subtitle_%d.m3u8", baseURL, sessionID, i)
}

// forcedCueDensityThreshold is the fraction of runtime below which a text subtitle's
// cue coverage is treated as "translation-only" (forced). A full-dialogue track cues
// almost continuously; a forced track only covers the handful of foreign-language
// scenes, so its cue count relative to a per-minute baseline is tiny. ~0.15 = 15%.
const forcedCueDensityThreshold = 0.15

// subTypeFromForced maps a forced flag to the default subtitle Type. Cue-density may
// later promote a "full" sidecar to "forced" (see classifySubtitleTracks).
func subTypeFromForced(forced bool) string {
	if forced {
		return "forced"
	}
	return "full"
}

// cueCountRe matches SRT/VTT cue timing lines ("00:01:23,456 --> 00:01:25,000").
// Counting these is a cheap proxy for the number of subtitle events in a text file.
var cueCountRe = regexp.MustCompile(`\d{1,2}:\d{2}:\d{2}[.,]\d{1,3}\s*-->`)

// subtitleCueDensity returns the fraction of the runtime "covered" by a text subtitle
// file, normalized against a full-dialogue baseline of ~12 cues/minute. Values well
// below 1.0 indicate sparse (forced/translation-only) coverage. It reads the file
// directly (SRT/VTT/ASS text) — cheap, no ffmpeg — and returns (density, ok). ok is
// false when the file can't be read or runtime is unknown, so callers fall back to
// flags/tokens only. A modest read cap keeps a pathological file from blocking.
func subtitleCueDensity(path string, runtimeSecs float64) (float64, bool) {
	if path == "" || runtimeSecs <= 0 {
		return 0, false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	var cues float64
	switch strings.ToLower(filepath.Ext(path)) {
	case ".ass", ".ssa":
		// ASS/SSA: each dialogue event is a "Dialogue:" line.
		cues = float64(bytes.Count(bytes.ToLower(data), []byte("dialogue:")))
	default:
		// SRT / VTT: count cue timing lines.
		cues = float64(len(cueCountRe.FindAllIndex(data, -1)))
	}
	if cues == 0 {
		return 0, true // parsed fine, genuinely no cues → maximally sparse
	}
	const baselineCuesPerMinute = 12.0
	expected := (runtimeSecs / 60.0) * baselineCuesPerMinute
	if expected <= 0 {
		return 0, false
	}
	return cues / expected, true
}

// classifySubtitleTracks finalizes each track's Type and marks the single best forced
// track for auto-enable. Rules (TASK-826, exact):
//   - A text track is "forced" when its disposition/token already says so, OR its
//     cue-density is below forcedCueDensityThreshold. Image subs stay "image". Full
//     subs are never promoted by density if they carry no forced signal AND density
//     is above threshold.
//   - A forced track AUTO-ENABLES only when audioLang == trackLang. Full subs never
//     auto-enable. At most ONE track gets AutoEnable — the first forced track whose
//     language matches the audio, preferring one already flagged forced/default.
//
// runtimeSecs is the authoritative item runtime; audioLang is the primary audio
// stream's language ("" if unknown). Mutates tracks in place.
func classifySubtitleTracks(tracks []transcode.SubtitleTrack, runtimeSecs float64, audioLang string) {
	audioLang = strings.ToLower(strings.TrimSpace(audioLang))
	for i := range tracks {
		t := &tracks[i]
		if t.Type == "image" {
			t.Forced = false
			t.Default = false
			t.AutoEnable = false
			continue
		}
		if t.Forced {
			t.Type = "forced"
			continue
		}
		// Not flagged forced — try the cue-density heuristic on the actual file.
		if density, ok := subtitleCueDensity(t.Path, runtimeSecs); ok && density < forcedCueDensityThreshold {
			t.Forced = true
			t.Type = "forced"
		} else if t.Type == "" {
			t.Type = "full"
		}
	}

	// Pick at most one auto-enable track: a forced track whose language matches the
	// audio. Prefer a track that was explicitly flagged forced/default over one
	// promoted solely by cue-density (rank), and the earliest such track.
	if audioLang == "" {
		return
	}
	bestIdx := -1
	bestRank := -1
	for i := range tracks {
		t := &tracks[i]
		if t.Type != "forced" {
			continue
		}
		tl := strings.ToLower(strings.TrimSpace(t.Language))
		if tl == "" || tl == "und" || tl != audioLang {
			continue
		}
		rank := 0
		if t.Default {
			rank = 2
		} else if t.Forced {
			rank = 1
		}
		if rank > bestRank {
			bestRank = rank
			bestIdx = i
		}
	}
	if bestIdx >= 0 {
		tracks[bestIdx].AutoEnable = true
	}
}

// embeddedSubLangNames maps ISO language codes to display names for embedded
// subtitle tracks. Shared by the collect/extract paths.
var embeddedSubLangNames = map[string]string{
	"en": "English", "fr": "French", "de": "German", "es": "Spanish",
	"it": "Italian", "pt": "Portuguese", "nl": "Dutch", "ru": "Russian",
	"ja": "Japanese", "ko": "Korean", "zh": "Chinese", "ar": "Arabic",
	"pl": "Polish", "sv": "Swedish", "da": "Danish", "fi": "Finnish",
	"no": "Norwegian", "cs": "Czech", "hu": "Hungarian", "ro": "Romanian",
	"tr": "Turkish", "he": "Hebrew", "th": "Thai", "vi": "Vietnamese",
}

// embeddedSubName derives the display name for an embedded subtitle track,
// matching the original (TASK-739) name/forced-label logic exactly.
func embeddedSubName(sub transcode.EmbeddedSubtitle) string {
	name := "Subtitles"
	if sub.Title != "" {
		name = sub.Title
	} else if n, ok := embeddedSubLangNames[sub.Language]; ok {
		name = n
	} else if sub.Language != "und" && sub.Language != "" {
		name = strings.ToUpper(sub.Language)
	}
	if sub.Forced {
		name += " (Forced)"
	}
	return name
}

// collectEmbeddedSubtitles returns SubtitleTrack entries for text subtitle streams
// embedded in the container (e.g. MKV internal SRT/ASS), for the HLS pipeline to
// consume. Cached across calls under TranscodeDir/embedded_subs/<id>/stream_N.srt.
//
// /playback non-blocking subs fix (follow-up to TASK-752): this function NEVER runs
// ffmpeg on the request path. The original extractEmbeddedSubtitles re-probed inside
// the request AND extracted each missing stream synchronously — on the 4-core NAS that
// blocked /playback for 15s+ (or got ffmpeg OOM-killed), so clients timed out (-1001)
// and playback never started. It also bypassed the shared ffmpegLimiter, re-
// oversubscribing ffmpeg and undoing TASK-752.
//
// New behavior:
//   - Embedded-sub enumeration comes from the probe the caller ALREADY ran (probeResult);
//     no second ffprobe here. If probeResult is nil (codec came from the DB, no live probe
//     this request) we return nil and let a later play that does probe populate them.
//   - A track whose .srt is already cached is returned immediately.
//   - A missing track is scheduled for limiter-gated background extraction and OMITTED
//     from this response (it appears on the next play — the agreed UX).
func (s *Server) collectEmbeddedSubtitles(itemID, videoPath string, offset float64, probeResult *transcode.ProbeResult) []transcode.SubtitleTrack {
	if s.cfg.FFmpegPath == "" {
		return nil
	}
	// TASK-800: never hand a path outside a media root to ffmpeg (probe or extraction).
	// Playback's own guard already covers the /playback path, but this method is the
	// funnel for every embedded-subtitle ffmpeg invocation — enforce it here too so the
	// asymmetry can't be reintroduced by a future caller.
	if !s.pathWithinMediaRoot(videoPath) {
		log.Printf("[subtitles] SECURITY: path %q for item %s not within any media root — skipping ffmpeg", filepath.Clean(videoPath), itemID)
		return nil
	}

	// Smoke-test follow-up: the original /playback non-blocking fix returned early
	// whenever probeResult was nil — but probeResult is nil on the common path
	// (codec info already cached in the DB, so handlePlayback never live-probes).
	// That silently disabled embedded-subtitle extraction for nearly every play.
	//
	// When we have no probe, schedule a one-shot background probe-and-extract instead
	// of doing it inline: a probe is cheap, but it still must NOT sit on the request
	// path (that's the timeout this whole change avoids). The background worker probes
	// for embedded sub streams and extracts any that aren't cached; they become
	// selectable on a later play. We return whatever is ALREADY cached right now.
	if probeResult == nil || len(probeResult.EmbeddedSubs) == 0 {
		if probeResult == nil && s.prober != nil {
			s.scheduleEmbeddedSubProbe(itemID, videoPath, offset)
		}
		return s.cachedEmbeddedSubtitles(itemID, offset)
	}

	cacheDir := filepath.Join(s.cfg.TranscodeDir, "embedded_subs", sanitizeID(itemID))
	var tracks []transcode.SubtitleTrack
	for _, sub := range probeResult.EmbeddedSubs {
		// Image-based subs (PGS/VobSub) are out of scope: surface them so the client
		// can list them, but NEVER extract/OCR. No Path, no cue-density.
		if sub.IsImage {
			tracks = append(tracks, transcode.SubtitleTrack{
				Language:   sub.Language,
				Name:       embeddedSubName(sub),
				Offset:     offset,
				Type:       "image",
				Forced:     false,
				Default:    false,
				AutoEnable: false,
			})
			continue
		}
		destPath := filepath.Join(cacheDir, fmt.Sprintf("stream_%d.srt", sub.Index))
		if _, statErr := os.Stat(destPath); statErr == nil {
			// Already cached — include it now.
			tracks = append(tracks, transcode.SubtitleTrack{
				Language: sub.Language,
				Name:     embeddedSubName(sub),
				Path:     destPath,
				Offset:   offset,
				Forced:   sub.Forced,
				Default:  sub.Default,
				Type:     subTypeFromForced(sub.Forced),
			})
			continue
		}
		// Not cached — extract off the request path. Track is omitted this play and
		// becomes selectable on the next one.
		s.scheduleEmbeddedSubExtract(itemID, videoPath, sub.Index, destPath)
	}
	return tracks
}

// cachedEmbeddedSubtitles returns SubtitleTracks for any embedded subs already
// extracted to this item's cache dir, without probing or extracting. Used on the
// common play where no live probe ran — we serve what's on disk now and let a
// background probe populate the rest for next time.
func (s *Server) cachedEmbeddedSubtitles(itemID string, offset float64) []transcode.SubtitleTrack {
	cacheDir := filepath.Join(s.cfg.TranscodeDir, "embedded_subs", sanitizeID(itemID))
	entries, err := os.ReadDir(cacheDir)
	if err != nil {
		return nil
	}
	var tracks []transcode.SubtitleTrack
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".srt") {
			continue
		}
		// The language/forced metadata isn't on disk; the cached file is keyed by
		// stream index only. Name it generically — a later play that does live-probe
		// will surface the richer name via the probeResult path above.
		tracks = append(tracks, transcode.SubtitleTrack{
			Language: "und",
			Name:     "Subtitles",
			Path:     filepath.Join(cacheDir, e.Name()),
			Offset:   offset,
		})
	}
	return tracks
}

// scheduleEmbeddedSubProbe runs a background probe for an item whose codec info came
// from the DB (so handlePlayback didn't live-probe). It enumerates embedded text sub
// streams and schedules extraction of any not yet cached. Singleflight-guarded per
// item so repeated plays don't spawn duplicate probes. The probe + extraction run off
// the request path — they MUST NOT block playback (the reason /playback stopped doing
// this inline). Best-effort: any failure just means embedded subs stay absent.
func (s *Server) scheduleEmbeddedSubProbe(itemID, videoPath string, offset float64) {
	key := "probe:" + itemID

	s.subExtractMu.Lock()
	if _, inflight := s.subExtractInFlight[key]; inflight {
		s.subExtractMu.Unlock()
		return
	}
	done := make(chan struct{})
	s.subExtractInFlight[key] = done
	s.subExtractMu.Unlock()

	go func() {
		defer func() {
			s.subExtractMu.Lock()
			delete(s.subExtractInFlight, key)
			s.subExtractMu.Unlock()
			close(done)
		}()

		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()
		probe, err := s.prober.Probe(ctx, videoPath)
		if err != nil || probe == nil || len(probe.EmbeddedSubs) == 0 {
			return
		}
		cacheDir := filepath.Join(s.cfg.TranscodeDir, "embedded_subs", sanitizeID(itemID))
		for _, sub := range probe.EmbeddedSubs {
			destPath := filepath.Join(cacheDir, fmt.Sprintf("stream_%d.srt", sub.Index))
			if _, statErr := os.Stat(destPath); statErr == nil {
				continue
			}
			// scheduleEmbeddedSubExtract is itself singleflight-guarded + limiter-gated.
			s.scheduleEmbeddedSubExtract(itemID, videoPath, sub.Index, destPath)
		}
	}()
}

// scheduleEmbeddedSubExtract kicks off a background ffmpeg extraction of one embedded
// subtitle stream. /playback non-blocking subs fix (follow-up to TASK-752).
//
//   - Singleflight per (itemID:streamIndex) via subExtractInFlight so concurrent plays
//     of the same title don't double-extract the same stream (mirrors trickplayInFlight).
//   - Runs on context.Background() (NOT the request context — the request returns
//     immediately and would otherwise cancel the worker), with a 3-minute cap so a wedged
//     ffmpeg can't leak forever.
//   - Acquires the shared ffmpegLimiter (blocking Acquire — correct off the request path,
//     unlike trickplay's TryAcquire) so extraction shares the ONE process-wide ffmpeg
//     budget instead of re-oversubscribing it.
func (s *Server) scheduleEmbeddedSubExtract(itemID, videoPath string, streamIndex int, destPath string) {
	key := itemID + ":" + strconv.Itoa(streamIndex)

	s.subExtractMu.Lock()
	if _, inflight := s.subExtractInFlight[key]; inflight {
		// Another worker is already extracting this exact stream — let it finish.
		s.subExtractMu.Unlock()
		return
	}
	done := make(chan struct{})
	s.subExtractInFlight[key] = done
	s.subExtractMu.Unlock()

	go func() {
		defer func() {
			s.subExtractMu.Lock()
			delete(s.subExtractInFlight, key)
			s.subExtractMu.Unlock()
			close(done)
		}()

		// Detached from the request: a 3-minute ceiling bounds a stuck ffmpeg.
		workerCtx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
		defer cancel()

		// Draw from the shared ffmpeg budget. Blocking Acquire is correct here — this is
		// off the request path, so waiting for a slot costs nothing user-visible and keeps
		// us within the TASK-752 concurrency cap.
		if err := s.ffmpegLimiter.Acquire(workerCtx); err != nil {
			log.Printf("[subs] embedded extract aborted for %s stream %d: %v", itemID, streamIndex, err)
			return
		}
		defer s.ffmpegLimiter.Release()

		// Re-check the cache after acquiring: a prior worker may have produced it while we
		// waited for a limiter slot.
		if _, statErr := os.Stat(destPath); statErr == nil {
			return
		}

		if exErr := transcode.ExtractEmbeddedSubtitle(workerCtx, s.cfg.FFmpegPath, videoPath, streamIndex, destPath); exErr != nil {
			log.Printf("[subs] embedded extract failed for %s stream %d: %v", itemID, streamIndex, exErr)
			return
		}
		log.Printf("[subs] embedded extract done for %s stream %d (available next play)", itemID, streamIndex)
	}()
}

// updateCodecInfo updates the codec info for an item in the database, bumping
// change_seq so delta-sync (WHERE change_seq > since) tells clients the file's codec
// changed. Worf P1-3 (TASK-755): the prior version omitted change_seq, so an item that
// auto-normalize flipped to DirectPlay never propagated — clients kept transcoding the
// converted file forever. We now allocate the next item_seq via incrementSeq (the same
// mechanism the scanner and tmdb paths use) and write it.
func (s *Server) updateCodecInfo(itemID string, probe *transcode.ProbeResult) {
	if probe == nil {
		return
	}
	seq := s.incrementSeq("item_seq")
	_, err := s.db.Exec(
		`UPDATE items SET video_codec = ?, audio_codec = ?, container = ?, needs_transcode = ?, duration_seconds = ?,
		 video_width = ?, video_height = ?, audio_channels = ?, change_seq = ? WHERE id = ?`,
		probe.VideoCodec, probe.AudioCodec, probe.Container, probe.NeedsTranscode,
		int(probe.DurationSecs), probe.Width, probe.Height, probe.AudioChannels, seq, itemID,
	)
	if err != nil {
		log.Printf("Failed to update codec info for %s: %v", itemID, err)
	}
}

// updateCodecInfoRepath is the auto-normalize variant of updateCodecInfo. Worf P0-2
// (TASK-755): a different-path conversion (e.g. Movie.mkv → Movie.mp4) moves the file to
// a NEW path. The item id is derived from the path (id = "it_"+hex(cleanPath) via
// itemIDFromPath), so the converted file's correct id is hex(newPath), not the row's
// current hex(originalPath).
//
// Two cases, decided by comparing the row's current id to itemIDFromPath(newPath):
//
//   - DIFFERENT path (id changes): re-key the row to hex(newPath) AND migrate every loose
//     item_id FK reference (progress/watchlist/downloads/playlist_items), in one tx, via
//     normalize.RekeyAndMigrate. This is the O'Brien residual-defect fix: merely repointing
//     `path` on the old id left the row keyed hex(.mkv) while the file lived at .mp4, so the
//     next library rescan — which derives id from path — upserted a SECOND row keyed
//     hex(.mp4) (a duplicate item for one file). Re-keying to hex(.mp4) means the rescan
//     finds this row by that id and updates it in place: no duplicate. If the re-key tx
//     fails for any reason it rolls back and we fall through to the path-only repoint
//     below, preserving the 404 fix.
//
//   - SAME path (id unchanged, e.g. an mp4 remux that stays Movie.mp4): nothing to re-key;
//     the simple path+codec+change_seq UPDATE on the existing id is correct.
//
// newPath is the on-disk path of the converted file.
func (s *Server) updateCodecInfoRepath(itemID, newPath string, probe *transcode.ProbeResult) {
	if probe == nil {
		return
	}
	cleanPath := filepath.Clean(newPath)
	newID := itemIDFromPath(cleanPath)

	// Different-path conversion → re-key + migrate FK rows in one transaction.
	if newID != itemID {
		seq := s.incrementSeq("item_seq")
		if err := normalize.RekeyAndMigrate(s.db, itemID, newID, cleanPath, probe, seq); err != nil {
			log.Printf("[normalize] re-key %s -> %s (%s) failed, falling back to path-only repoint: %v",
				itemID, newID, cleanPath, err)
			// Fall through to the path-only repoint so the 404 fix still lands even if
			// re-keying failed. A burned item_seq is harmless — delta-sync only relies
			// on change_seq monotonicity, not contiguity.
		} else {
			return
		}
	}

	// Same-path conversion (or re-key fallback): repoint path + codec on the existing id.
	seq := s.incrementSeq("item_seq")
	_, err := s.db.Exec(
		`UPDATE items SET path = ?, video_codec = ?, audio_codec = ?, container = ?, needs_transcode = ?, duration_seconds = ?,
		 video_width = ?, video_height = ?, audio_channels = ?, change_seq = ? WHERE id = ?`,
		cleanPath, probe.VideoCodec, probe.AudioCodec, probe.Container, probe.NeedsTranscode,
		int(probe.DurationSecs), probe.Width, probe.Height, probe.AudioChannels, seq, itemID,
	)
	if err != nil {
		log.Printf("Failed to repoint+update codec info for %s -> %s: %v", itemID, cleanPath, err)
	}
}

// findFFmpeg searches for ffmpeg in common locations.
func findFFmpeg() (string, error) {
	// Try PATH first
	if path, err := exec.LookPath("ffmpeg"); err == nil {
		return path, nil
	}

	// Common Synology locations
	commonPaths := []string{
		"/usr/bin/ffmpeg",
		"/usr/local/bin/ffmpeg",
		"/volume1/@appstore/ffmpeg/bin/ffmpeg",
		"/var/packages/ffmpeg/target/bin/ffmpeg",
	}

	for _, p := range commonPaths {
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
	}

	return "", fmt.Errorf("ffmpeg not found")
}

func (s *Server) handlePlaybackStream(w http.ResponseWriter, r *http.Request) {
	sessionID := chi.URLParam(r, "sessionId")
	ps, ok := s.getSession(sessionID)
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found")
		return
	}

	// Remux mode: pipe through ffmpeg to convert container to fragmented MP4
	// This handles MKV→MP4 remux and audio transcode (AC3/DTS→AAC) in real-time
	if ps.Kind == "remux" {
		s.handleRemuxStream(w, r, ps)
		return
	}

	f, err := os.Open(ps.Path)
	if err != nil {
		writeErr(w, http.StatusNotFound, "not_found")
		return
	}
	defer f.Close()

	st, err := f.Stat()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "stat_failed")
		return
	}
	http.ServeContent(w, r, filepath.Base(ps.Path), st.ModTime(), f)
}

// tailBuffer is a bounded io.Writer that retains only the last `max` bytes
// written to it. It is used to capture the tail of an ffmpeg process's stderr
// for diagnostics without buffering an unbounded amount of progress output.
type tailBuffer struct {
	max int
	buf bytes.Buffer
}

func newTailBuffer(max int) *tailBuffer { return &tailBuffer{max: max} }

func (t *tailBuffer) Write(p []byte) (int, error) {
	n := len(p)
	if _, err := t.buf.Write(p); err != nil {
		return 0, err
	}
	if excess := t.buf.Len() - t.max; excess > 0 {
		// Drop the oldest bytes, keeping only the trailing window.
		t.buf.Next(excess)
	}
	return n, nil
}

func (t *tailBuffer) String() string { return strings.TrimSpace(t.buf.String()) }

// handleRemuxStream serves video by remuxing through ffmpeg to fragmented MP4.
// This is used for web clients when the video codec is compatible (H.264)
// but the container (MKV) or audio codec (AC3/DTS) isn't browser-compatible.
// Much faster than full HLS transcode since video is stream-copied.
func (s *Server) handleRemuxStream(w http.ResponseWriter, r *http.Request, ps PlaySession) {
	ffmpegPath := s.cfg.FFmpegPath
	if ffmpegPath == "" {
		var err error
		ffmpegPath, err = findFFmpeg()
		if err != nil {
			// No ffmpeg available - fall back to direct serving
			log.Printf("[Remux] ffmpeg not found, falling back to direct serve: %v", err)
			f, err := os.Open(ps.Path)
			if err != nil {
				writeErr(w, http.StatusNotFound, "not_found")
				return
			}
			defer f.Close()
			st, err := f.Stat()
			if err != nil {
				writeErr(w, http.StatusInternalServerError, "stat_failed")
				return
			}
			http.ServeContent(w, r, filepath.Base(ps.Path), st.ModTime(), f)
			return
		}
	}

	// P1-2: the web-client realtime remux path spawned ffmpeg directly, bypassing the
	// shared ffmpegLimiter entirely — reopening the TASK-752 oversubscription bug (5+
	// concurrent ffmpeg on a 4-core/3.8GB box with no HW encoder). Draw from the shared
	// budget before launching. Use the REQUEST context: this ffmpeg streams for the whole
	// request, so when the client disconnects the context cancels, Acquire unblocks (if
	// still waiting) and the deferred Release frees the slot. Placed AFTER the ffmpeg-not-
	// found fallback above so a direct-serve (no-ffmpeg) request never consumes a slot.
	if err := s.ffmpegLimiter.Acquire(r.Context()); err != nil {
		writeErr(w, http.StatusServiceUnavailable, "transcode_busy")
		return
	}
	defer s.ffmpegLimiter.Release()

	// Build ffmpeg command: remux to fragmented MP4 for streaming
	// -c:v copy = don't re-encode video (fast!)
	// -c:a aac = transcode audio to AAC (browser-compatible)
	// -movflags = enable fragmented MP4 for progressive streaming
	args := []string{
		"-i", ps.Path,
		"-c:v", "copy",
		"-c:a", "aac",
		"-b:a", "192k",
		"-f", "mp4",
		"-movflags", "frag_keyframe+empty_moov+default_base_moof",
		"pipe:1",
	}

	cmd := exec.Command(ffmpegPath, args...)
	// TASK-822: previously cmd.Stderr = nil discarded all diagnostics, so a failed
	// remux gave the client a broken stream with zero server-side explanation.
	// Capture the tail of stderr (bounded — ffmpeg is chatty with progress lines)
	// and log it on a non-zero exit.
	stderrTail := newTailBuffer(8 << 10) // 8 KiB tail
	cmd.Stderr = stderrTail
	// Run ffmpeg in its own process group so we can signal the whole group on
	// client disconnect — matching the HLS/normalize transcode paths.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "pipe_failed")
		return
	}

	if err := cmd.Start(); err != nil {
		log.Printf("[Remux] Failed to start ffmpeg: %v", err)
		writeErr(w, http.StatusInternalServerError, "ffmpeg_failed")
		return
	}

	// Stream the remuxed MP4 to the client
	w.Header().Set("Content-Type", "video/mp4")
	w.Header().Set("Transfer-Encoding", "chunked")

	// Stop ffmpeg if the client disconnects. Kill the whole process group
	// (negative pid) so no child is orphaned; fall back to killing the process.
	done := r.Context().Done()
	go func() {
		<-done
		if cmd.Process != nil {
			if pgid, gerr := syscall.Getpgid(cmd.Process.Pid); gerr == nil {
				_ = syscall.Kill(-pgid, syscall.SIGKILL)
			} else {
				_ = cmd.Process.Kill()
			}
		}
	}()

	if _, err := io.Copy(w, stdout); err != nil {
		// Client likely disconnected - that's OK
		log.Printf("[Remux] Stream ended: %v", err)
	}

	if werr := cmd.Wait(); werr != nil {
		// Distinguish a real ffmpeg failure from a client-disconnect kill: if the
		// request context is done, the non-zero exit is our own SIGKILL, not a fault.
		if r.Context().Err() == nil {
			if tail := stderrTail.String(); tail != "" {
				log.Printf("[Remux] ffmpeg exited with error for %s: %v\nffmpeg stderr (tail):\n%s", ps.Path, werr, tail)
			} else {
				log.Printf("[Remux] ffmpeg exited with error for %s: %v (no stderr captured)", ps.Path, werr)
			}
		}
	}
}

// trickplayDir returns the cache directory for an item's scrubbing-preview assets.
func (s *Server) trickplayDir(itemID string) string {
	return filepath.Join(s.cfg.TranscodeDir, "trickplay", sanitizeID(itemID))
}

// generateTrickplayOnce runs sprite generation for an item with two guards:
//   - singleflight: concurrent requests for the SAME item collapse to one ffmpeg
//     job; later callers wait for the in-flight job instead of racing on the same
//     output file.
//   - shared ffmpeg limiter (TASK-752): total concurrent ffmpeg work is capped by
//     ONE process-wide budget shared with HLS transcode + subtitle conversion. Unlike
//     live playback, trickplay YIELDS — it TryAcquires with a short timeout and backs
//     off if the budget is saturated by playback, returning a normal failure that the
//     handler maps to "trickplay_unavailable" (the client degrades gracefully). This
//     enforces the invariant: playback always eventually gets a slot, trickplay never
//     starves it.
//
// Returns the result of the (possibly shared) generation attempt.
func (s *Server) generateTrickplayOnce(ctx context.Context, itemID, path, outDir string, dur float64) error {
	// Fast path: already generated.
	if _, err := os.Stat(filepath.Join(outDir, "trickplay.vtt")); err == nil {
		return nil
	}

	s.trickplayMu.Lock()
	if done, inflight := s.trickplayInFlight[itemID]; inflight {
		s.trickplayMu.Unlock()
		// Another request is already generating this item — wait for it.
		select {
		case <-done:
		case <-ctx.Done():
			return ctx.Err()
		}
		if _, err := os.Stat(filepath.Join(outDir, "trickplay.vtt")); err == nil {
			return nil
		}
		return fmt.Errorf("trickplay generation failed (shared job)")
	}
	done := make(chan struct{})
	s.trickplayInFlight[itemID] = done
	s.trickplayMu.Unlock()

	defer func() {
		s.trickplayMu.Lock()
		delete(s.trickplayInFlight, itemID)
		s.trickplayMu.Unlock()
		close(done)
	}()

	// Draw from the shared ffmpeg budget, but YIELD to live playback: try for a slot
	// only briefly. If playback has the budget saturated, back off and let the caller
	// return "trickplay_unavailable" rather than blocking a slot the player needs.
	const trickplayAcquireTimeout = 2 * time.Second
	if !s.ffmpegLimiter.TryAcquire(ctx, trickplayAcquireTimeout) {
		return fmt.Errorf("ffmpeg budget saturated — trickplay deferred")
	}
	defer s.ffmpegLimiter.Release()

	// nice 19 = lowest OS priority, so even once trickplay holds a slot it yields CPU
	// to the playback transcode running at nice 10.
	_, err := transcode.GenerateTrickplay(ctx, s.cfg.FFmpegPath, path, outDir, dur, transcode.TrickplayConfig{
		NicePriority: 19,
	})
	return err
}

// handleTrickplayVTT lazily generates (and caches) the sprite + VTT for an item,
// then serves the VTT. Generation is best-effort; failures return 404 so the client
// simply shows no scrub preview.
func (s *Server) handleTrickplayVTT(w http.ResponseWriter, r *http.Request) {
	itemID := chi.URLParam(r, "itemId")
	var path string
	var duration sql.NullInt64
	if err := s.db.QueryRow("SELECT path, duration_seconds FROM items WHERE id = ?", itemID).Scan(&path, &duration); err != nil {
		writeErr(w, http.StatusNotFound, "not_found")
		return
	}
	// TASK-800: same within-media-root guard playback enforces, before ffmpeg touches the path.
	if !s.pathWithinMediaRoot(path) {
		log.Printf("[trickplay] SECURITY: path %q for item %s not within any media root — rejecting", filepath.Clean(path), itemID)
		writeErr(w, http.StatusForbidden, "path_not_allowed")
		return
	}
	if s.prober == nil || s.cfg.FFmpegPath == "" {
		writeErr(w, http.StatusNotFound, "trickplay_unavailable")
		return
	}
	dur := float64(duration.Int64)
	if dur <= 0 {
		// Fall back to a probe if duration wasn't recorded at scan time.
		if pr, err := s.prober.Probe(r.Context(), path); err == nil {
			dur = pr.DurationSecs
		}
	}
	outDir := s.trickplayDir(itemID)
	if err := s.generateTrickplayOnce(r.Context(), itemID, path, outDir, dur); err != nil {
		log.Printf("[trickplay] generate failed for %s: %v", itemID, err)
		writeErr(w, http.StatusNotFound, "trickplay_unavailable")
		return
	}
	w.Header().Set("Content-Type", "text/vtt")
	w.Header().Set("Cache-Control", "public, max-age=86400")
	http.ServeFile(w, r, filepath.Join(outDir, "trickplay.vtt"))
}

// handleTrickplaySprite serves the previously generated sprite sheet.
func (s *Server) handleTrickplaySprite(w http.ResponseWriter, r *http.Request) {
	itemID := chi.URLParam(r, "itemId")
	spritePath := filepath.Join(s.trickplayDir(itemID), "trickplay.jpg")
	if _, err := os.Stat(spritePath); err != nil {
		writeErr(w, http.StatusNotFound, "not_found")
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "public, max-age=86400")
	http.ServeFile(w, r, spritePath)
}

func (s *Server) handleHLSFile(filename string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sessionID := chi.URLParam(r, "sessionId")
		ps, ok := s.getSession(sessionID)
		if !ok || ps.Kind != "hls" || ps.HLSDir == "" {
			writeErr(w, http.StatusNotFound, "not_found")
			return
		}

		// For the master playlist, block until ffmpeg has written it.
		// ffmpeg generates segments in the background so the file may not
		// exist yet when AVPlayer makes its first request.
		if filename == "master.m3u8" && s.hlsGenerator != nil {
			waitCtx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
			defer cancel()
			if err := s.hlsGenerator.WaitForPlaylist(waitCtx, sessionID, 30*time.Second); err != nil {
				log.Printf("[HLS] Playlist not ready for session %s after 30s: %v", sessionID, err)
				writeErr(w, http.StatusServiceUnavailable, "playlist_not_ready")
				return
			}
		}

		http.ServeFile(w, r, filepath.Join(ps.HLSDir, filename))
	}
}

func (s *Server) handleHLSVariant(w http.ResponseWriter, r *http.Request) {
	// v1: single variant == master
	s.handleHLSFile("master.m3u8")(w, r)
}

func (s *Server) handleHLSSegment(w http.ResponseWriter, r *http.Request) {
	sessionID := chi.URLParam(r, "sessionId")
	name := chi.URLParam(r, "name")
	if strings.Contains(name, "..") || strings.ContainsAny(name, "/\\") {
		writeErr(w, http.StatusBadRequest, "invalid_segment")
		return
	}
	ext := strings.ToLower(filepath.Ext(name))
	allowed := map[string]bool{".m4s": true, ".ts": true, ".mp4": true, ".m3u8": true}
	if !allowed[ext] {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	ps, ok := s.getSession(sessionID)
	if !ok || ps.Kind != "hls" || ps.HLSDir == "" {
		writeErr(w, http.StatusNotFound, "not_found")
		return
	}
	fullPath := filepath.Join(ps.HLSDir, name)
	if !strings.HasPrefix(filepath.Clean(fullPath)+"/", filepath.Clean(ps.HLSDir)+"/") {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	http.ServeFile(w, r, fullPath)
}

// handleHLSSegmentRoot serves an fMP4 init segment or a media segment that lives
// at the session root (init.mp4, segment_NNNNN.m4s, v0_init.mp4, v0_NNNNN.m4s,
// or legacy .ts). The filename is the last path component of the request — chi's
// {name} param drops the extension on suffix routes, so we use the URL path
// directly rather than reconstructing from {name}.
func (s *Server) handleHLSSegmentRoot(w http.ResponseWriter, r *http.Request) {
	sessionID := chi.URLParam(r, "sessionId")
	name := path.Base(r.URL.Path)
	if name == "." || name == "/" || strings.Contains(name, "..") || strings.ContainsAny(name, "/\\") {
		writeErr(w, http.StatusBadRequest, "invalid_segment")
		return
	}
	ext := strings.ToLower(filepath.Ext(name))
	allowed := map[string]bool{".m4s": true, ".ts": true, ".mp4": true}
	if !allowed[ext] {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	ps, ok := s.getSession(sessionID)
	if !ok || ps.Kind != "hls" || ps.HLSDir == "" {
		writeErr(w, http.StatusNotFound, "not_found")
		return
	}
	fullPath := filepath.Join(ps.HLSDir, name)
	if !strings.HasPrefix(filepath.Clean(fullPath)+"/", filepath.Clean(ps.HLSDir)+"/") {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	http.ServeFile(w, r, fullPath)
}

func (s *Server) getSession(sessionID string) (PlaySession, bool) {
	// P0-1: bump LastAccess on every read so the playSessions reaper treats an actively
	// streaming session as live. This needs a write to the map value, so take the full
	// lock rather than RLock (PlaySession is a value, not a pointer — we re-store it).
	s.mu.Lock()
	defer s.mu.Unlock()
	ps, ok := s.playSessions[sessionID]
	if ok {
		ps.LastAccess = time.Now()
		s.playSessions[sessionID] = ps
	}
	return ps, ok
}

// handlePlaybackStop releases a play session immediately at the client's request (P0-1).
// It removes the entry from playSessions under the lock and, for HLS-kind sessions, tears
// down the transcode + temp dir via StopSession OUTSIDE the lock (StopSession takes the
// generator's own lock — don't nest it inside s.mu). Idempotent: an unknown or already-
// reaped session is a no-op and still returns 204, so a client may safely call it on every
// teardown without racing the idle reaper.
func (s *Server) handlePlaybackStop(w http.ResponseWriter, r *http.Request) {
	sessionID := chi.URLParam(r, "sessionId")

	s.mu.Lock()
	ps, ok := s.playSessions[sessionID]
	if ok {
		delete(s.playSessions, sessionID)
	}
	s.mu.Unlock()

	if ok && ps.Kind == "hls" && s.hlsGenerator != nil {
		if err := s.hlsGenerator.StopSession(sessionID); err != nil {
			log.Printf("[playSessions] stop endpoint StopSession %s: %v", sessionID, err)
		}
	}

	w.WriteHeader(http.StatusNoContent)
}

// -------------------------
// Progress
// -------------------------

type progressRequest struct {
	PositionSeconds int `json:"positionSeconds"`
	DurationSeconds int `json:"durationSeconds"`
	// Accepted and IGNORED. Clients send "playing"/"finished"; nothing reads it
	// (grep req.State == 0 hits). It is kept in the struct so an unknown-field decode does
	// not reject the body, and because six client call sites still populate it.
	//
	// It looked like the mechanism behind "mark as finished", but that is derived from
	// position vs duration (PlaybackProgress.isFinished on the client, the rail SQL on the
	// server), and write ordering now comes from progress.write_seq — so there is no
	// behaviour for this field to drive. Do not add logic keyed on it without deciding what
	// happens when an older client omits it entirely.
	State string `json:"state,omitempty"`
}

// itemExists reports whether an items row with this id is present. TASK-797: guards
// progress / watchlist / downloads INSERTs so a scripted client cannot write unbounded
// rows for arbitrary (non-existent) item IDs — which bloats the tables and, for progress,
// bumps progress_seq on every fake write forcing every device into a full re-sync.
func (s *Server) itemExists(itemID string) bool {
	if itemID == "" {
		return false
	}
	var one int
	err := s.db.QueryRow("SELECT 1 FROM items WHERE id = ?", itemID).Scan(&one)
	return err == nil
}

// pathWithinMediaRoot reports whether a DB-stored media path resolves inside one of the
// configured media roots. TASK-800: the same guard handlePlayback applies must run at
// every path→ffmpeg site (trickplay sprite generation, embedded-subtitle extraction) so a
// tampered/mis-scanned items.path can never become an ffmpeg-driven arbitrary-file
// read/probe primitive. Empty roots are ignored; if no root is configured this returns
// false (fail closed).
func (s *Server) pathWithinMediaRoot(path string) bool {
	cleanedPath := filepath.Clean(path)
	for _, root := range []string{s.cfg.MoviesPath, s.cfg.TVPath, s.cfg.HomePath} {
		if root == "" {
			continue
		}
		cleanedRoot := filepath.Clean(root)
		if cleanedPath == cleanedRoot || strings.HasPrefix(cleanedPath, cleanedRoot+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

func (s *Server) handleProgress(w http.ResponseWriter, r *http.Request) {
	itemID := chi.URLParam(r, "id")
	var req progressRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		// Some clients send progress as form data or query params instead of JSON.
		// Be permissive to avoid client-side crashes on transient progress updates.
		_ = r.ParseForm()
		if req.PositionSeconds == 0 {
			req.PositionSeconds, _ = strconv.Atoi(firstNonEmpty(
				r.FormValue("positionSeconds"),
				r.FormValue("position_seconds"),
				r.FormValue("time"),
			))
		}
		if req.DurationSeconds == 0 {
			req.DurationSeconds, _ = strconv.Atoi(firstNonEmpty(
				r.FormValue("durationSeconds"),
				r.FormValue("duration_seconds"),
				r.FormValue("total_time"),
			))
		}
	}
	// Upper bound as well as lower. Without it any client (or a scripted POST) can store a
	// duration larger than a 32-bit int; that row is then handed to every syncing client, and
	// one that narrows to Int32 traps on it at launch — an unrecoverable crash-loop seeded by
	// a single bad write. The clients were fixed to bind 64-bit, but the server must not
	// persist impossible values in the first place. 32 days is far beyond any real title and
	// still leaves 32-bit clients safe.
	const maxProgressSeconds = 32 * 24 * 60 * 60 // 2_764_800
	if req.DurationSeconds <= 0 || req.PositionSeconds < 0 ||
		req.DurationSeconds > maxProgressSeconds || req.PositionSeconds > maxProgressSeconds {
		writeErr(w, http.StatusBadRequest, "invalid_progress")
		return
	}
	// TASK-797: reject progress for a non-existent item BEFORE writing / bumping seq.
	if !s.itemExists(itemID) {
		writeErr(w, http.StatusNotFound, "not_found")
		return
	}
	u := userFromCtx(r.Context())
	now := time.Now().UTC().Format(time.RFC3339)
	s.progressMu.Lock()
	// The upsert is conditional: a write is applied only if it is NEWER than what we hold,
	// or if it meaningfully moves the position within the same title.
	//
	// It used to be unconditional (`DO UPDATE SET position_seconds=excluded...` with no
	// WHERE), which made the server a pure last-write-wins sink and let any client regress
	// another device's position. That is not hypothetical: a replayed backlog from a device
	// that had been offline would overwrite a newer position watched elsewhere, and the
	// client's own outbox comment asserted a "last-writer-wins comparison" here that had
	// never actually existed. Verified against this server: POST 7500 then POST 6000 left
	// the row at 6000, destroying 25 minutes of progress.
	//
	// The rule:
	//   - excluded.updated_at > progress.updated_at  → a genuinely newer write, take it.
	//   - ordering is by write_seq, a monotone per-write ordinal — NOT by updated_at.
	//
	// The previous rule broke ties on updated_at and, within the same second, kept the LARGER
	// position. That silently discarded legitimate position-REDUCING writes: an explicit
	// "mark unwatched" (position 0) or a rewind landing in the same second as a prior write
	// disappeared, while the handler still returned {"ok":true}. Reproduced live: POST 4000
	// then POST 0 in the same second left the row at 4000. RFC3339 is 1-second granular, so no
	// timestamp comparison can order writes inside a second — hence a real sequence number.
	// A deliberate restart-from-zero is now honoured, because it always carries a higher seq.
	// duration is refreshed alongside so a re-probe that corrects runtime still lands.
	writeSeq := s.incrementSeq("progress_seq")
	res, err := s.db.Exec(
		"INSERT INTO progress(item_id, user_id, position_seconds, duration_seconds, updated_at, write_seq) VALUES(?,?,?,?,?,?) "+
			"ON CONFLICT(item_id, user_id) DO UPDATE SET "+
			"position_seconds=excluded.position_seconds, "+
			"duration_seconds=excluded.duration_seconds, "+
			"updated_at=excluded.updated_at, "+
			"write_seq=excluded.write_seq "+
			"WHERE excluded.write_seq > progress.write_seq",
		itemID, u.ID, req.PositionSeconds, req.DurationSeconds, now, writeSeq,
	)
	var rowsAffected int64
	if err == nil {
		rowsAffected, _ = res.RowsAffected()
	}
	s.progressMu.Unlock()
	// NOTE: progress_seq is now bumped ABOVE, before the write, because the value doubles as
	// this row's write_seq — it must be allocated before the statement that stores it. The
	// previous FIX-14 comment described bumping it afterwards purely as a sync-cursor tick;
	// that second bump is gone, so a write no longer advances the counter twice.
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	// Report whether the row actually changed. A superseded write (a lower write_seq losing to
	// a concurrent newer one) is not an error — but answering a flat {"ok":true} for a write
	// the server DISCARDED is how "Mark Unwatched" appeared to work while changing nothing.
	// Clients can now distinguish "stored" from "ignored as stale" instead of trusting 200.
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "applied": rowsAffected > 0})
}

// -------------------------
// Version & Sync Endpoints
// -------------------------

// handleVersion — GET /api/v1/version
func (s *Server) handleVersion(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"serverVersion":    BuildVersion,
		"minClientVersion": "1.0.0",
		"capabilities":     []string{"delta-sync", "heartbeat", "token-refresh", "progress-all"},
	})
}

// handleSyncStatus — GET /api/v1/sync/status
func (s *Server) handleSyncStatus(w http.ResponseWriter, r *http.Request) {
	itemSeq, progressSeq := s.getSyncSeqs()
	// totalItems removed: SELECT COUNT(*) was a full table scan on every status
	// probe (including the reconnect health check on cold NAS DB). The iOS client
	// decodes the field but never uses it for sync logic or display, so it is safe
	// to omit. The field is set to 0 here to keep the response shape stable and
	// avoid breaking older clients that may decode the struct.
	writeJSON(w, http.StatusOK, map[string]any{
		"itemSeq":     itemSeq,
		"progressSeq": progressSeq,
		"totalItems":  0,
	})
}

// handleSyncHeartbeat — GET /api/v1/sync/heartbeat (auth required — TASK-515)
func (s *Server) handleSyncHeartbeat(w http.ResponseWriter, r *http.Request) {
	itemSeq, progressSeq := s.getSyncSeqs()
	writeJSON(w, http.StatusOK, map[string]any{
		"itemSeq":      itemSeq,
		"progressSeq":  progressSeq,
		"serverTimeMs": time.Now().UnixMilli(),
	})
}

// handleSyncItems — GET /api/v1/sync/items?since=N&limit=500
// Returns items with change_seq > since, ordered by change_seq ASC.
// Special case: since=0 returns ALL items (>= 0) so a fresh client gets the
// full library even if items haven't been rescanned and still have change_seq=0.
func (s *Server) handleSyncItems(w http.ResponseWriter, r *http.Request) {
	since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
	// afterRowid is used for offset-style pagination when all change_seq values
	// are equal (e.g. 0 for pre-delta-sync DBs). The client passes the last
	// rowid it received so we can page forward without re-fetching the same rows.
	afterRowid, _ := strconv.ParseInt(r.URL.Query().Get("afterRowid"), 10, 64)
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 1000 {
		limit = 500
	}

	u := userFromCtx(r.Context())

	// Select the right query variant based on since/afterRowid:
	//   since=0 → use >= so pre-scan rows with change_seq=0 are included
	//   afterRowid > 0 → add rowid page filter to avoid re-fetching rows at the same seq
	const queryGTWithRowid = `
		SELECT i.rowid, i.id, i.library_id, i.type, i.title, i.year, i.duration_seconds,
		       i.added_at, i.rating, i.poster_path, i.backdrop_path,
		       i.show_name, i.season_number, i.episode_number, i.change_seq,
		       p.position_seconds, p.duration_seconds, p.updated_at, i.show_folder_id
		FROM items i
		LEFT JOIN progress p ON p.item_id = i.id AND p.user_id = ?
		WHERE i.change_seq > ? AND i.rowid > ?
		ORDER BY i.change_seq ASC, i.rowid ASC
		LIMIT ?`
	const queryGT = `
		SELECT i.rowid, i.id, i.library_id, i.type, i.title, i.year, i.duration_seconds,
		       i.added_at, i.rating, i.poster_path, i.backdrop_path,
		       i.show_name, i.season_number, i.episode_number, i.change_seq,
		       p.position_seconds, p.duration_seconds, p.updated_at, i.show_folder_id
		FROM items i
		LEFT JOIN progress p ON p.item_id = i.id AND p.user_id = ?
		WHERE i.change_seq > ?
		ORDER BY i.change_seq ASC, i.rowid ASC
		LIMIT ?`
	const queryGTEWithRowid = `
		SELECT i.rowid, i.id, i.library_id, i.type, i.title, i.year, i.duration_seconds,
		       i.added_at, i.rating, i.poster_path, i.backdrop_path,
		       i.show_name, i.season_number, i.episode_number, i.change_seq,
		       p.position_seconds, p.duration_seconds, p.updated_at, i.show_folder_id
		FROM items i
		LEFT JOIN progress p ON p.item_id = i.id AND p.user_id = ?
		WHERE i.change_seq >= ? AND i.rowid > ?
		ORDER BY i.change_seq ASC, i.rowid ASC
		LIMIT ?`
	const queryGTE = `
		SELECT i.rowid, i.id, i.library_id, i.type, i.title, i.year, i.duration_seconds,
		       i.added_at, i.rating, i.poster_path, i.backdrop_path,
		       i.show_name, i.season_number, i.episode_number, i.change_seq,
		       p.position_seconds, p.duration_seconds, p.updated_at, i.show_folder_id
		FROM items i
		LEFT JOIN progress p ON p.item_id = i.id AND p.user_id = ?
		WHERE i.change_seq >= ?
		ORDER BY i.change_seq ASC, i.rowid ASC
		LIMIT ?`

	var rows *sql.Rows
	var err error
	switch {
	case since == 0 && afterRowid > 0:
		rows, err = s.db.Query(queryGTEWithRowid, u.ID, since, afterRowid, limit+1)
	case since == 0:
		rows, err = s.db.Query(queryGTE, u.ID, since, limit+1)
	case afterRowid > 0:
		rows, err = s.db.Query(queryGTWithRowid, u.ID, since, afterRowid, limit+1)
	default:
		rows, err = s.db.Query(queryGT, u.ID, since, limit+1)
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	defer rows.Close()

	type syncItem struct {
		ID              string          `json:"id"`
		LibraryID       string          `json:"libraryId"`
		Type            string          `json:"type"`
		Title           string          `json:"title"`
		Year            *int            `json:"year,omitempty"`
		DurationSeconds *int            `json:"durationSeconds,omitempty"`
		AddedAt         string          `json:"addedAt"`
		Rating          *float64        `json:"rating,omitempty"`
		PosterImageID   *string         `json:"posterImageId,omitempty"`
		BackdropImageID *string         `json:"backdropImageId,omitempty"`
		ShowName        *string         `json:"showName,omitempty"`
		ShowFolderID    *string         `json:"showFolderId,omitempty"`
		SeasonNumber    *int            `json:"seasonNumber,omitempty"`
		EpisodeNumber   *int            `json:"episodeNumber,omitempty"`
		ChangeSeq       int64           `json:"changeSeq"`
		Progress        *map[string]any `json:"progress,omitempty"`
	}

	items := make([]syncItem, 0, limit)
	var maxSeq, maxRowid int64
	for rows.Next() {
		var item syncItem
		var rowid int64
		var year, dur, posSeconds, durSeconds sql.NullInt64
		var rating sql.NullFloat64
		var poster, backdrop, showName, showFolderIDCol sql.NullString
		var seasonNum, episodeNum sql.NullInt64
		var progUpdatedAt sql.NullString

		if err := rows.Scan(
			&rowid, &item.ID, &item.LibraryID, &item.Type, &item.Title, &year, &dur,
			&item.AddedAt, &rating, &poster, &backdrop,
			&showName, &seasonNum, &episodeNum, &item.ChangeSeq,
			&posSeconds, &durSeconds, &progUpdatedAt, &showFolderIDCol,
		); err != nil {
			continue
		}
		if rowid > maxRowid {
			maxRowid = rowid
		}
		if year.Valid {
			v := int(year.Int64)
			item.Year = &v
		}
		if dur.Valid {
			v := int(dur.Int64)
			item.DurationSeconds = &v
		}
		if rating.Valid {
			item.Rating = &rating.Float64
		}
		if poster.Valid && poster.String != "" {
			item.PosterImageID = &item.ID
		}
		if backdrop.Valid && backdrop.String != "" {
			item.BackdropImageID = &item.ID
		}
		if showName.Valid {
			item.ShowName = &showName.String
		}
		if seasonNum.Valid {
			v := int(seasonNum.Int64)
			item.SeasonNumber = &v
		}
		if episodeNum.Valid {
			v := int(episodeNum.Int64)
			item.EpisodeNumber = &v
		}
		if showFolderIDCol.Valid && showFolderIDCol.String != "" {
			folderID := showFolderIDCol.String
			item.ShowFolderID = &folderID
		}
		if posSeconds.Valid && durSeconds.Valid {
			p := map[string]any{
				"positionSeconds": posSeconds.Int64,
				"durationSeconds": durSeconds.Int64,
				"updatedAt":       progUpdatedAt.String,
			}
			item.Progress = &p
		}
		if item.ChangeSeq > maxSeq {
			maxSeq = item.ChangeSeq
		}
		items = append(items, item)
	}

	hasMore := len(items) > limit
	if hasMore {
		items = items[:limit]
	}

	// For TV episodes that have no poster_path of their own, fall back to the poster
	// of any sibling episode in the same show that does have one. This lets the client
	// display a show poster in the Just Added / Recently Watched rails even when
	// individual episode images were never downloaded.
	missingPosterFolders := map[string]bool{}
	for _, it := range items {
		if it.PosterImageID == nil && it.ShowFolderID != nil && *it.ShowFolderID != "" {
			missingPosterFolders[*it.ShowFolderID] = true
		}
	}
	if len(missingPosterFolders) > 0 {
		tvRoot := ""
		if s.cfg.TVPath != "" {
			tvRoot = filepath.Clean(s.cfg.TVPath) + "/"
		}
		showPosterID := map[string]string{} // folderID → episode ID that has a poster
		for folder := range missingPosterFolders {
			if tvRoot == "" {
				continue
			}
			esc := strings.ReplaceAll(folder, `\`, `\\`)
			esc = strings.ReplaceAll(esc, "%", `\%`)
			esc = strings.ReplaceAll(esc, "_", `\_`)
			var epID string
			s.db.QueryRow(
				`SELECT id FROM items WHERE path LIKE ? ESCAPE '\' AND library_id = 'lib_tv' AND poster_path IS NOT NULL AND poster_path != '' LIMIT 1`,
				tvRoot+esc+"/%",
			).Scan(&epID)
			if epID != "" {
				showPosterID[folder] = epID
			}
		}
		for i := range items {
			if items[i].PosterImageID == nil && items[i].ShowFolderID != nil {
				if epID, ok := showPosterID[*items[i].ShowFolderID]; ok {
					items[i].PosterImageID = &epID
				}
			}
		}
	}

	// nextSeq is the cursor the client should pass as `since` on the next call.
	// When all items share change_seq=0 (pre-delta-sync DB), maxSeq stays 0 —
	// equal to `since` — so the client would loop forever re-fetching the same page.
	// Use the server's authoritative item_seq when maxSeq won't advance the cursor.
	nextSeq := maxSeq
	if !hasMore && nextSeq <= since {
		serverSeq, _ := s.getSyncSeqs()
		if serverSeq > nextSeq {
			nextSeq = serverSeq
		} else {
			// Server seq is also 0 (nothing scanned yet). Advance past since so
			// the client treats this as "fully synced" and stops paging.
			nextSeq = since + 1
		}
	}

	// nextAfterRowid: when hasMore and the seq cursor can't advance (all items
	// share the same change_seq), the client must page by rowid instead.
	// It should pass afterRowid=<this value> on the next request.
	resp := map[string]any{
		"items":   items,
		"nextSeq": nextSeq,
		"hasMore": hasMore,
	}
	if hasMore && maxSeq <= since {
		resp["nextAfterRowid"] = maxRowid
	}

	writeJSON(w, http.StatusOK, resp)
}

// handleSyncDeleted — GET /api/v1/sync/deleted?since=N
// Returns IDs of items deleted since the given change_seq.
// We track deletions via a deleted_items table populated during scan cleanup.
func (s *Server) handleSyncDeleted(w http.ResponseWriter, r *http.Request) {
	since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
	itemSeq, _ := s.getSyncSeqs()

	rows, err := s.db.Query(
		`SELECT item_id FROM deleted_items WHERE change_seq > ? ORDER BY change_seq ASC`, since)
	if err != nil {
		// Table may not exist yet — return empty list gracefully
		writeJSON(w, http.StatusOK, map[string]any{"deletedIds": []string{}, "asOf": itemSeq})
		return
	}
	defer rows.Close()

	ids := make([]string, 0)
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"deletedIds": ids, "asOf": itemSeq})
}

// handleTokenRefresh — POST /api/v1/auth/refresh
// Accepts a valid JWT and returns a new one with a fresh expiry.
func (s *Server) handleTokenRefresh(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())
	// Generate new JTI
	jtiBytes := make([]byte, 16)
	if _, err := rand.Read(jtiBytes); err != nil {
		writeErr(w, http.StatusInternalServerError, "token_generation_failed")
		return
	}
	claims := jwt.MapClaims{
		"sub": u.ID,
		"usr": u.Username,
		"jti": hex.EncodeToString(jtiBytes),
		"iat": time.Now().Unix(),
		// 90-day expiry for refreshed tokens: tvOS devices pair infrequently and a
		// shorter TTL (e.g. 30 days) would force re-pairing on devices that are powered
		// off or unused for weeks, creating a frustrating loop. 90 days balances
		// security with usability for living-room appliances.
		"exp": time.Now().Add(90 * 24 * time.Hour).Unix(),
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	signed, err := token.SignedString([]byte(s.cfg.JWTSecret))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "token_signing_failed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"token": signed,
		"user":  map[string]any{"id": u.ID, "username": u.Username, "displayName": u.Username},
	})
}

// handleProgressAll — GET /api/v1/progress/all
// Returns all progress rows for the authenticated user in a single query.
func (s *Server) handleProgressAll(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())
	rows, err := s.db.Query(
		"SELECT item_id, position_seconds, duration_seconds, updated_at FROM progress WHERE user_id = ?",
		u.ID,
	)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	defer rows.Close()
	result := make(map[string]any)
	for rows.Next() {
		var itemID, updatedAt string
		var pos, dur int
		if err := rows.Scan(&itemID, &pos, &dur, &updatedAt); err != nil {
			continue
		}
		result[itemID] = map[string]any{
			"positionSeconds": pos,
			"durationSeconds": dur,
			"updatedAt":       updatedAt,
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"progress": result})
}

// handleProgressBatch — GET /api/v1/progress?ids=id1,id2,...
// Returns progress for multiple items in a single query.
func (s *Server) handleProgressBatch(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())
	raw := r.URL.Query().Get("ids")
	if raw == "" {
		writeJSON(w, http.StatusOK, map[string]any{"progress": map[string]any{}})
		return
	}
	parts := strings.Split(raw, ",")
	ids := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			ids = append(ids, p)
		}
	}
	if len(ids) == 0 {
		writeJSON(w, http.StatusOK, map[string]any{"progress": map[string]any{}})
		return
	}
	if len(ids) > 500 {
		writeErr(w, http.StatusBadRequest, "too_many_ids")
		return
	}
	placeholders := strings.Repeat("?,", len(ids))
	placeholders = placeholders[:len(placeholders)-1]
	args := make([]any, 0, len(ids)+1)
	args = append(args, u.ID)
	for _, id := range ids {
		args = append(args, id)
	}
	rows, err := s.db.Query(
		"SELECT item_id, position_seconds, duration_seconds, updated_at FROM progress WHERE user_id = ? AND item_id IN ("+placeholders+")",
		args...,
	)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	defer rows.Close()
	result := make(map[string]any, len(ids))
	for rows.Next() {
		var itemID, updatedAt string
		var pos, dur int
		if err := rows.Scan(&itemID, &pos, &dur, &updatedAt); err != nil {
			continue
		}
		result[itemID] = map[string]any{
			"positionSeconds": pos,
			"durationSeconds": dur,
			"updatedAt":       updatedAt,
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"progress": result})
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func (s *Server) getProgress(userID, itemID string) (map[string]any, error) {
	row := s.db.QueryRow("SELECT position_seconds, duration_seconds, updated_at FROM progress WHERE user_id = ? AND item_id = ?", userID, itemID)
	var pos, dur int
	var updatedAt string
	if err := row.Scan(&pos, &dur, &updatedAt); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return map[string]any{"positionSeconds": pos, "durationSeconds": dur, "updatedAt": updatedAt}, nil
}

// getProgressBatch returns progress for a slice of itemIDs in a single query.
// Returns a map of itemID → progress map; missing items are absent from the map.
func (s *Server) getProgressBatch(userID string, itemIDs []string) map[string]map[string]any {
	result := make(map[string]map[string]any, len(itemIDs))
	if len(itemIDs) == 0 {
		return result
	}
	placeholders := strings.Repeat("?,", len(itemIDs))
	placeholders = placeholders[:len(placeholders)-1]
	args := make([]any, 0, len(itemIDs)+1)
	args = append(args, userID)
	for _, id := range itemIDs {
		args = append(args, id)
	}
	rows, err := s.db.Query(
		"SELECT item_id, position_seconds, duration_seconds, updated_at FROM progress WHERE user_id = ? AND item_id IN ("+placeholders+")",
		args...,
	)
	if err != nil {
		return result
	}
	defer rows.Close()
	for rows.Next() {
		var itemID, updatedAt string
		var pos, dur int
		if err := rows.Scan(&itemID, &pos, &dur, &updatedAt); err != nil {
			continue
		}
		result[itemID] = map[string]any{"positionSeconds": pos, "durationSeconds": dur, "updatedAt": updatedAt}
	}
	return result
}

// -------------------------
// Settings
// -------------------------

func (s *Server) handleGetSettings(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())

	// Get global settings (user_id = '') and user-specific settings
	rows, err := s.db.Query(
		"SELECT key, user_id, value FROM settings WHERE user_id = '' OR user_id = ?",
		u.ID,
	)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	defer rows.Close()

	settings := map[string]any{}
	for rows.Next() {
		var key, userID, value string
		if err := rows.Scan(&key, &userID, &value); err != nil {
			continue
		}
		// User-specific settings override global
		settings[key] = value
	}

	// Never expose server-side secrets to clients.
	// Use an explicit denylist of known secret keys rather than a suffix heuristic.
	secretKeys := map[string]bool{
		"tmdb_api_key": true,
	}
	for k := range settings {
		if secretKeys[k] || strings.HasSuffix(k, "_key") || strings.HasSuffix(k, "_secret") || strings.HasSuffix(k, "_token") || strings.HasSuffix(k, "_password") {
			delete(settings, k)
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{"settings": settings})
}

type putSettingsRequest struct {
	Settings map[string]string `json:"settings"`
}

func (s *Server) handlePutSettings(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())

	var req putSettingsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_json")
		return
	}

	now := time.Now().UTC().Format(time.RFC3339)

	// TASK-791: writing a server-global setting (currently tmdb_api_key — reinitializes
	// the shared TMDb client and kicks a full library rescan) is admin-only. Per-user
	// settings remain writable by their owner. Gate before touching the DB so a low-priv
	// user can neither swap the global key nor trigger the rescan-DoS.
	globalSettingKeys := map[string]bool{"tmdb_api_key": true}
	for key := range req.Settings {
		if globalSettingKeys[key] && !s.isAdmin(u) {
			writeErr(w, http.StatusForbidden, "admin_required")
			return
		}
	}

	for key, value := range req.Settings {
		// tmdb_api_key is a global setting
		userID := u.ID
		if globalSettingKeys[key] {
			userID = ""
		}

		_, err := s.db.Exec(
			`INSERT INTO settings(key, user_id, value, updated_at) VALUES(?,?,?,?)
			 ON CONFLICT(key, user_id) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at`,
			key, userID, value, now,
		)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "db_error")
			return
		}

		// If TMDb key was updated, reinitialize the client and rescan
		if key == "tmdb_api_key" {
			if value != "" {
				s.tmdbMu.Lock()
				s.tmdbClient = metadata.NewTMDbClient(value)
				s.tmdbMu.Unlock()
				log.Println("TMDb client reinitialized with new API key, triggering rescan")
				go func() {
					if err := s.scanAll(context.Background()); err != nil {
						log.Printf("rescan after TMDb key update failed: %v", err)
					}
				}()
			} else {
				s.tmdbMu.Lock()
				s.tmdbClient = nil
				s.tmdbMu.Unlock()
				log.Println("TMDb client disabled (key removed)")
			}
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// -------------------------
// Playlists
// -------------------------

func (s *Server) handleListPlaylists(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())

	// Single query with LEFT JOIN COUNT to avoid N+1 per-playlist count query (TASK-528).
	rows, err := s.db.Query(`
		SELECT p.id, p.title, p.created_at, p.updated_at, COUNT(pi.playlist_id) AS item_count
		FROM playlists p
		LEFT JOIN playlist_items pi ON pi.playlist_id = p.id
		WHERE p.user_id = ?
		GROUP BY p.id, p.title, p.created_at, p.updated_at
		ORDER BY p.updated_at DESC`,
		u.ID,
	)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	defer rows.Close()

	playlists := make([]map[string]any, 0)
	for rows.Next() {
		var id, title, createdAt, updatedAt string
		var count int
		if err := rows.Scan(&id, &title, &createdAt, &updatedAt, &count); err != nil {
			continue
		}

		playlists = append(playlists, map[string]any{
			"id":        id,
			"title":     title,
			"itemCount": count,
			"createdAt": createdAt,
			"updatedAt": updatedAt,
		})
	}

	writeJSON(w, http.StatusOK, map[string]any{"playlists": playlists})
}

type createPlaylistRequest struct {
	Title string `json:"title"`
}

func (s *Server) handleCreatePlaylist(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())

	var req createPlaylistRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_json")
		return
	}
	if strings.TrimSpace(req.Title) == "" {
		writeErr(w, http.StatusBadRequest, "missing_title")
		return
	}

	id := randID("pl_")
	now := time.Now().UTC().Format(time.RFC3339)

	_, err := s.db.Exec(
		"INSERT INTO playlists(id, user_id, title, created_at, updated_at) VALUES(?,?,?,?,?)",
		id, u.ID, req.Title, now, now,
	)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}

	writeJSON(w, http.StatusCreated, map[string]any{
		"id":        id,
		"title":     req.Title,
		"createdAt": now,
		"updatedAt": now,
	})
}

func (s *Server) handleGetPlaylist(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())
	playlistID := chi.URLParam(r, "id")

	var title, createdAt, updatedAt string
	err := s.db.QueryRow(
		"SELECT title, created_at, updated_at FROM playlists WHERE id = ? AND user_id = ?",
		playlistID, u.ID,
	).Scan(&title, &createdAt, &updatedAt)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeErr(w, http.StatusNotFound, "not_found")
			return
		}
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}

	// Get items in playlist
	rows, err := s.db.Query(
		`SELECT i.id, i.type, i.title, i.year, i.duration_seconds, i.added_at, i.rating, i.poster_path, i.backdrop_path
		 FROM playlist_items pi
		 INNER JOIN items i ON i.id = pi.item_id
		 WHERE pi.playlist_id = ?
		 ORDER BY pi.position ASC, pi.added_at ASC`,
		playlistID,
	)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	defer rows.Close()

	items := make([]map[string]any, 0)
	for rows.Next() {
		var id, typ, itemTitle, addedAt string
		var year, duration sql.NullInt64
		var rating sql.NullFloat64
		var posterPath, backdropPath sql.NullString

		if err := rows.Scan(&id, &typ, &itemTitle, &year, &duration, &addedAt, &rating, &posterPath, &backdropPath); err != nil {
			continue
		}

		item := map[string]any{
			"id":              id,
			"type":            typ,
			"title":           itemTitle,
			"year":            nullIntToAny(year),
			"durationSeconds": nullIntToAny(duration),
			"posterImageId":   nil,
			"backdropImageId": nil,
		}
		if posterPath.Valid && posterPath.String != "" {
			item["posterImageId"] = id
		}
		if backdropPath.Valid && backdropPath.String != "" {
			item["backdropImageId"] = id
		}
		items = append(items, item)
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"id":        playlistID,
		"title":     title,
		"items":     items,
		"createdAt": createdAt,
		"updatedAt": updatedAt,
	})
}

func (s *Server) handleDeletePlaylist(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())
	playlistID := chi.URLParam(r, "id")

	res, err := s.db.Exec("DELETE FROM playlists WHERE id = ? AND user_id = ?", playlistID, u.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		writeErr(w, http.StatusNotFound, "not_found")
		return
	}
	// Cascade should handle playlist_items, but be explicit
	if _, err := s.db.Exec("DELETE FROM playlist_items WHERE playlist_id = ?", playlistID); err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

type addPlaylistItemRequest struct {
	ItemID string `json:"itemId"`
}

func (s *Server) handleAddPlaylistItem(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())
	playlistID := chi.URLParam(r, "id")

	// Verify ownership
	var count int
	s.db.QueryRow("SELECT COUNT(*) FROM playlists WHERE id = ? AND user_id = ?", playlistID, u.ID).Scan(&count)
	if count == 0 {
		writeErr(w, http.StatusNotFound, "not_found")
		return
	}

	var req addPlaylistItemRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid_json")
		return
	}
	if req.ItemID == "" {
		writeErr(w, http.StatusBadRequest, "missing_itemId")
		return
	}

	// Get next position
	var maxPos int
	s.db.QueryRow("SELECT COALESCE(MAX(position), 0) FROM playlist_items WHERE playlist_id = ?", playlistID).Scan(&maxPos)

	now := time.Now().UTC().Format(time.RFC3339)
	_, err := s.db.Exec(
		"INSERT OR IGNORE INTO playlist_items(playlist_id, item_id, position, added_at) VALUES(?,?,?,?)",
		playlistID, req.ItemID, maxPos+1, now,
	)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}

	// Update playlist updated_at
	s.db.Exec("UPDATE playlists SET updated_at = ? WHERE id = ?", now, playlistID)

	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleRemovePlaylistItem(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())
	playlistID := chi.URLParam(r, "id")
	itemID := chi.URLParam(r, "itemId")

	// Verify ownership
	var count int
	s.db.QueryRow("SELECT COUNT(*) FROM playlists WHERE id = ? AND user_id = ?", playlistID, u.ID).Scan(&count)
	if count == 0 {
		writeErr(w, http.StatusNotFound, "not_found")
		return
	}

	if _, err := s.db.Exec("DELETE FROM playlist_items WHERE playlist_id = ? AND item_id = ?", playlistID, itemID); err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}

	now := time.Now().UTC().Format(time.RFC3339)
	if _, err := s.db.Exec("UPDATE playlists SET updated_at = ? WHERE id = ?", now, playlistID); err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// -------------------------
// Downloads (Bookmarks)
// -------------------------

func (s *Server) handleListDownloads(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())

	rows, err := s.db.Query(
		`SELECT i.id, i.type, i.title, i.year, i.duration_seconds, i.added_at, i.rating, i.poster_path, i.backdrop_path
		 FROM downloads d
		 INNER JOIN items i ON i.id = d.item_id
		 WHERE d.user_id = ?
		 ORDER BY d.marked_at DESC`,
		u.ID,
	)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	defer rows.Close()

	items := make([]map[string]any, 0)
	for rows.Next() {
		var id, typ, title, addedAt string
		var year, duration sql.NullInt64
		var rating sql.NullFloat64
		var posterPath, backdropPath sql.NullString

		if err := rows.Scan(&id, &typ, &title, &year, &duration, &addedAt, &rating, &posterPath, &backdropPath); err != nil {
			continue
		}

		item := map[string]any{
			"id":              id,
			"type":            typ,
			"title":           title,
			"year":            nullIntToAny(year),
			"durationSeconds": nullIntToAny(duration),
			"addedAt":         addedAt,
			"rating":          nullFloatToAny(rating),
			"posterImageId":   nil,
			"backdropImageId": nil,
		}
		if posterPath.Valid && posterPath.String != "" {
			item["posterImageId"] = id
		}
		if backdropPath.Valid && backdropPath.String != "" {
			item["backdropImageId"] = id
		}
		items = append(items, item)
	}

	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (s *Server) handleAddDownload(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())
	itemID := chi.URLParam(r, "itemId")

	// TASK-797: only mark real items for download.
	if !s.itemExists(itemID) {
		writeErr(w, http.StatusNotFound, "not_found")
		return
	}

	now := time.Now().UTC().Format(time.RFC3339)
	_, err := s.db.Exec(
		"INSERT OR IGNORE INTO downloads(item_id, user_id, marked_at) VALUES(?,?,?)",
		itemID, u.ID, now,
	)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleRemoveDownload(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())
	itemID := chi.URLParam(r, "itemId")

	if _, err := s.db.Exec("DELETE FROM downloads WHERE item_id = ? AND user_id = ?", itemID, u.ID); err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// -------------------------
// Watchlist
// -------------------------

func (s *Server) handleWatchlistGet(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())

	rows, err := s.db.Query(
		`SELECT i.id, i.type, i.title, i.year, i.duration_seconds, i.added_at, i.rating,
		        i.poster_path, i.backdrop_path, i.library_id,
		        p.position_seconds, p.duration_seconds, p.updated_at
		 FROM watchlist w
		 JOIN items i ON i.id = w.item_id
		 LEFT JOIN progress p ON p.item_id = i.id AND p.user_id = ?
		 WHERE w.user_id = ?
		 ORDER BY w.added_at DESC`,
		u.ID, u.ID,
	)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	defer rows.Close()

	items := make([]map[string]any, 0)
	for rows.Next() {
		var id, typ, title, addedAt, libraryID string
		var year, duration sql.NullInt64
		var rating sql.NullFloat64
		var posterPath, backdropPath sql.NullString
		var progPos, progDur sql.NullInt64
		var progUpdatedAt sql.NullString

		if err := rows.Scan(&id, &typ, &title, &year, &duration, &addedAt, &rating,
			&posterPath, &backdropPath, &libraryID,
			&progPos, &progDur, &progUpdatedAt); err != nil {
			writeErr(w, http.StatusInternalServerError, "db_error")
			return
		}

		item := map[string]any{
			"id":              id,
			"type":            typ,
			"title":           title,
			"year":            nullIntToAny(year),
			"durationSeconds": nullIntToAny(duration),
			"addedAt":         addedAt,
			"rating":          nullFloatToAny(rating),
			"posterImageId":   nil,
			"backdropImageId": nil,
			"libraryId":       libraryID,
		}
		if posterPath.Valid && posterPath.String != "" {
			item["posterImageId"] = id
		}
		if backdropPath.Valid && backdropPath.String != "" {
			item["backdropImageId"] = id
		}
		if progPos.Valid {
			item["progress"] = map[string]any{
				"positionSeconds": progPos.Int64,
				"durationSeconds": progDur.Int64,
				"updatedAt":       progUpdatedAt.String,
			}
		}
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (s *Server) handleWatchlistCheck(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())
	itemID := chi.URLParam(r, "itemId")

	var count int
	if err := s.db.QueryRow("SELECT COUNT(*) FROM watchlist WHERE item_id = ? AND user_id = ?", itemID, u.ID).Scan(&count); err != nil {
		log.Printf("[handleWatchlistCheck] db error for item %q user %q: %v", itemID, u.ID, err)
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"inWatchlist": count > 0})
}

func (s *Server) handleWatchlistAdd(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())
	itemID := chi.URLParam(r, "itemId")

	// TASK-797: only watchlist real items.
	if !s.itemExists(itemID) {
		writeErr(w, http.StatusNotFound, "not_found")
		return
	}

	_, err := s.db.Exec(
		`INSERT OR IGNORE INTO watchlist(item_id, user_id) VALUES (?, ?)`,
		itemID, u.ID,
	)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleWatchlistRemove(w http.ResponseWriter, r *http.Request) {
	u := userFromCtx(r.Context())
	itemID := chi.URLParam(r, "itemId")

	res, err := s.db.Exec("DELETE FROM watchlist WHERE item_id = ? AND user_id = ?", itemID, u.ID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		writeErr(w, http.StatusNotFound, "not_found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// -------------------------
// Admin / Scanning
// -------------------------

func (s *Server) handleAdminStatus(w http.ResponseWriter, r *http.Request) {
	s.mu.RLock()
	last := s.lastScanAt
	activeSessions := len(s.playSessions)
	s.mu.RUnlock()

	// Get transcode status
	var activeTranscodes int
	var transcodeDiskUsage int64
	if s.hlsGenerator != nil {
		activeTranscodes = s.hlsGenerator.ActiveSessions()
	}
	if s.cleanupManager != nil {
		transcodeDiskUsage = s.cleanupManager.TotalDiskUsage()
	}

	// Check FFmpeg availability
	ffmpegAvailable := false
	if _, err := findFFmpeg(); err == nil {
		ffmpegAvailable = true
	}

	// TASK-811: dbPath, baseUrl, transcode tempDir and absolute library paths are
	// filesystem-layout disclosure that aids other attacks. Only an admin sees them; a
	// non-admin gets the operational status with paths redacted.
	admin := s.isAdmin(userFromCtx(r.Context()))

	transcode := map[string]any{
		"enabled":         s.hlsGenerator != nil,
		"ffmpegAvailable": ffmpegAvailable,
		"activeSessions":  activeTranscodes,
		"diskUsageKB":     transcodeDiskUsage / 1024,
	}
	resp := map[string]any{
		"ok":               true,
		"version":          "0.2.0-dev",
		"libraries":        configuredLibrariesRedacted(s.cfg, admin),
		"lastScanAt":       last.UTC().Format(time.RFC3339),
		"playbackSessions": activeSessions,
		"isAdmin":          admin,
	}
	if admin {
		resp["baseUrl"] = s.cfg.BaseURL
		resp["dbPath"] = s.cfg.DBPath
		transcode["tempDir"] = s.cfg.TranscodeDir
	}
	resp["transcode"] = transcode
	writeJSON(w, http.StatusOK, resp)
}

// handleAdminNormalizeStatus reports the auto-normalize worker's state: whether it is
// enabled, how deep the queue is, what it is doing now, and which items it has retired.
//
// This exists because diagnosing "is conversion working?" previously meant SSH-ing into
// the NAS and grepping a log file — the retired-items list in particular was invisible,
// so a file looping on every scan looked identical to one making progress. Admin-only:
// the retired map is keyed by item ID, which decodes to an absolute filesystem path.
func (s *Server) handleAdminNormalizeStatus(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdmin(w, r) {
		return
	}

	if s.normalizeWorker == nil {
		writeJSON(w, http.StatusOK, map[string]any{
			"enabled": false,
			"reason":  "auto-normalize is off (DSVIDEO_AUTO_NORMALIZE) or ffmpeg/ffprobe were not found at startup",
		})
		return
	}

	st := s.normalizeWorker.Stats()

	// Decode item IDs (hex of the path) back to paths so the response is readable
	// without a second lookup — the whole point is answering the question in one call.
	retired := make([]map[string]string, 0, len(st.Retired))
	for id, reason := range st.Retired {
		entry := map[string]string{"itemId": id, "reason": reason}
		if p, err := hex.DecodeString(strings.TrimPrefix(id, "it_")); err == nil {
			entry["path"] = string(p)
		}
		retired = append(retired, entry)
	}
	sort.Slice(retired, func(i, j int) bool { return retired[i]["path"] < retired[j]["path"] })

	writeJSON(w, http.StatusOK, map[string]any{
		"enabled":       true,
		"queued":        st.Queued,
		"queueCapacity": st.Capacity,
		"converting":    st.Converting,
		"maxHeight":     st.MaxHeight,
		"retentionDays": s.cfg.NormalizeRetentionDays,
		"originalsDir":  s.cfg.OriginalsDir,
		"retiredCount":  len(retired),
		"retired":       retired,
		"idle":          s.normalizeWorker.IsIdleNow(),
	})
}

func (s *Server) handleAdminScan(w http.ResponseWriter, r *http.Request) {
	// TASK-811/791: a full rescan is CPU/IO heavy on the NAS — admin-only so a low-priv
	// user cannot trigger a rescan-DoS.
	if !s.requireAdmin(w, r) {
		return
	}
	// Get TMDb client from request header (allows per-user API keys)
	tmdbClient := s.getTMDbClient(r)
	go func() {
		if err := s.scanAllWithClient(context.Background(), tmdbClient); err != nil {
			log.Printf("scan failed: %v", err)
		}
	}()
	writeJSON(w, http.StatusAccepted, map[string]any{"ok": true})
}

func configuredLibraries(cfg Config) []map[string]any {
	var libs []map[string]any
	if cfg.MoviesPath != "" {
		libs = append(libs, map[string]any{"id": "lib_movies", "title": "Movies", "kind": "movies", "path": cfg.MoviesPath})
	}
	if cfg.TVPath != "" {
		libs = append(libs, map[string]any{"id": "lib_tv", "title": "TV Shows", "kind": "tv", "path": cfg.TVPath})
	}
	if cfg.HomePath != "" {
		libs = append(libs, map[string]any{"id": "lib_home", "title": "Home Videos", "kind": "home", "path": cfg.HomePath})
	}
	return libs
}

// configuredLibrariesRedacted returns the library list with absolute filesystem paths
// included only for admins. TASK-811: non-admins must not learn the NAS directory layout.
func configuredLibrariesRedacted(cfg Config, admin bool) []map[string]any {
	libs := configuredLibraries(cfg)
	if admin {
		return libs
	}
	for _, lib := range libs {
		delete(lib, "path")
	}
	return libs
}

func (s *Server) scanAll(ctx context.Context) error {
	// Use server's default TMDb client
	s.tmdbMu.RLock()
	client := s.tmdbClient
	s.tmdbMu.RUnlock()
	return s.scanAllWithClient(ctx, client)
}

func (s *Server) scanAllWithClient(ctx context.Context, tmdbClient *metadata.TMDbClient) error {
	libs := configuredLibraries(s.cfg)
	if len(libs) == 0 {
		// No-op scan; still mark timestamp.
		s.mu.Lock()
		s.lastScanAt = time.Now()
		s.mu.Unlock()
		return nil
	}

	for _, lib := range libs {
		path, _ := lib["path"].(string)
		libID, _ := lib["id"].(string)
		kind, _ := lib["kind"].(string)
		if path == "" || libID == "" {
			continue
		}
		if err := s.scanLibraryWithClient(ctx, libID, kind, path, tmdbClient); err != nil {
			return err
		}
	}

	s.mu.Lock()
	s.lastScanAt = time.Now()
	s.mu.Unlock()

	// Force WAL checkpoint after scan — scanner batch-writes many rows which can bloat
	// the WAL and cause read timeouts. PASSIVE mode checkpoints without blocking readers.
	if _, err := s.db.ExecContext(ctx, "PRAGMA wal_checkpoint(PASSIVE)"); err != nil {
		log.Printf("post-scan checkpoint: %v", err)
	}

	return nil
}

func (s *Server) scanLibrary(ctx context.Context, libraryID, kind, root string) error {
	s.tmdbMu.RLock()
	client := s.tmdbClient
	s.tmdbMu.RUnlock()
	return s.scanLibraryWithClient(ctx, libraryID, kind, root, client)
}

// metaPendingItem holds state for items that need metadata after the scan transaction commits.
type metaPendingItem struct {
	id     string
	parsed metadata.ParsedFilename
	typ    string
}

func (s *Server) scanLibraryWithClient(ctx context.Context, libraryID, kind, root string, tmdbClient *metadata.TMDbClient) error {
	root = filepath.Clean(root)
	videoExt := map[string]bool{
		".mp4": true, ".m4v": true, ".mov": true, ".mkv": true, ".avi": true, ".ts": true,
		".webm": true,
	}

	// Pre-query all existing items for this library so we can skip per-file DB reads.
	// metadata_fetched_at being non-NULL means we've already attempted TMDb for this item.
	type existingState struct {
		metadataFetched bool
	}
	existing := make(map[string]existingState)
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, metadata_fetched_at IS NOT NULL FROM items WHERE library_id = ?`, libraryID)
	if err == nil {
		for rows.Next() {
			var id string
			var fetched bool
			if rows.Scan(&id, &fetched) == nil {
				existing[id] = existingState{metadataFetched: fetched}
			}
		}
		rows.Close()
	}

	now := time.Now().UTC().Format(time.RFC3339)
	var metaPending []metaPendingItem
	// Track every path seen during the walk so we can remove stale DB entries afterward.
	seenPaths := make(map[string]struct{})

	// Batch upserts into transactions of batchSize files. This keeps write lock
	// duration short so concurrent HTTP readers are not blocked during a full scan.
	const batchSize = 50
	type pendingRow struct {
		id, libraryID, typ, title, addedAt     string
		year, duration                         sql.NullInt64
		videoCodec, audioCodec, container      sql.NullString
		needsTranscode                         sql.NullBool
		path                                   string
		parsed                                 metadata.ParsedFilename
		showFolderID                           sql.NullString
		videoWidth, videoHeight, audioChannels sql.NullInt64
	}
	var batch []pendingRow

	flushBatch := func() error {
		if len(batch) == 0 {
			return nil
		}
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return fmt.Errorf("scan: begin tx: %w", err)
		}
		for _, row := range batch {
			var seq int64
			_ = tx.QueryRowContext(ctx,
				`UPDATE sync_state SET value = value + 1 WHERE key = 'item_seq' RETURNING value`,
			).Scan(&seq)
			if seq > 0 {
				s.cachedItemSeq.Store(seq)
			}
			if _, err := tx.Exec(
				`INSERT INTO items(id, library_id, type, title, year, path, duration_seconds, added_at, updated_at, video_codec, audio_codec, container, needs_transcode, change_seq, show_folder_id, video_width, video_height, audio_channels)
				 VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
				 ON CONFLICT(id) DO UPDATE SET
				   library_id=excluded.library_id,
				   type=excluded.type,
				   path=excluded.path,
				   added_at=excluded.added_at,
				   updated_at=excluded.updated_at,
				   video_codec=COALESCE(excluded.video_codec, items.video_codec),
				   audio_codec=COALESCE(excluded.audio_codec, items.audio_codec),
				   container=COALESCE(excluded.container, items.container),
				   needs_transcode=COALESCE(excluded.needs_transcode, items.needs_transcode),
				   duration_seconds=COALESCE(excluded.duration_seconds, items.duration_seconds),
				   title=CASE WHEN items.tmdb_id IS NULL THEN excluded.title ELSE items.title END,
				   year=CASE WHEN items.tmdb_id IS NULL THEN excluded.year ELSE items.year END,
				   show_folder_id=COALESCE(excluded.show_folder_id, items.show_folder_id),
				   video_width=COALESCE(excluded.video_width, items.video_width),
				   video_height=COALESCE(excluded.video_height, items.video_height),
				   audio_channels=COALESCE(excluded.audio_channels, items.audio_channels),
				   change_seq=excluded.change_seq`,
				row.id, row.libraryID, row.typ, row.title, row.year, row.path, row.duration, row.addedAt, now,
				row.videoCodec, row.audioCodec, row.container, row.needsTranscode, seq, row.showFolderID,
				row.videoWidth, row.videoHeight, row.audioChannels,
			); err != nil {
				log.Printf("scan: upsert failed for %s: %v", row.path, err)
			}
			st := existing[row.id]
			if tmdbClient != nil && !st.metadataFetched && row.typ != "homeVideo" {
				metaPending = append(metaPending, metaPendingItem{id: row.id, parsed: row.parsed, typ: row.typ})
			}
		}
		if err := tx.Commit(); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("scan: commit: %w", err)
		}
		batch = batch[:0]
		return nil
	}

	walkErr := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		if d.IsDir() {
			// TASK-755: never descend into the auto-normalize backup tree. Originals
			// moved there after conversion must NOT be re-indexed (they'd resurrect the
			// non-DirectPlay rows we just replaced). Match both the configured originals
			// dir and the conventional basename so a custom DSVIDEO_ORIGINALS_DIR is also
			// skipped.
			if s.cfg.OriginalsDir != "" && filepath.Clean(path) == filepath.Clean(s.cfg.OriginalsDir) {
				return filepath.SkipDir
			}
			if d.Name() == "_dsvideo_originals" {
				return filepath.SkipDir
			}
			return nil
		}
		// TASK-755: skip in-progress conversion temps (".<stem>.converting.mp4"). Indexing
		// a half-written temp created the ghost-row bug; the dotfile name is the marker.
		if strings.HasPrefix(d.Name(), ".") && strings.HasSuffix(d.Name(), ".converting.mp4") {
			return nil
		}
		ext := strings.ToLower(filepath.Ext(d.Name()))
		if !videoExt[ext] {
			return nil
		}

		info, err := d.Info()
		if err != nil {
			return nil
		}

		id := itemIDFromPath(path)
		addedAt := info.ModTime().UTC().Format(time.RFC3339)

		typ := "video"
		switch kind {
		case "movies":
			typ = "movie"
		case "tv":
			typ = "episode"
		case "home":
			typ = "homeVideo"
		}

		parsed := metadata.ParseFilename(d.Name())
		title := parsed.Title
		if title == "" {
			title = titleFromFilename(d.Name())
		}

		var videoCodec, audioCodec, container sql.NullString
		var duration sql.NullInt64
		var needsTranscode sql.NullBool
		var videoWidth, videoHeight, audioChannels sql.NullInt64

		if s.prober != nil {
			probeCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
			probe, probeErr := s.prober.Probe(probeCtx, path)
			cancel()
			if probeErr == nil && probe != nil {
				videoCodec = sql.NullString{String: probe.VideoCodec, Valid: true}
				audioCodec = sql.NullString{String: probe.AudioCodec, Valid: true}
				container = sql.NullString{String: probe.Container, Valid: true}
				needsTranscode = sql.NullBool{Bool: probe.NeedsTranscode, Valid: true}
				if probe.DurationSecs > 0 {
					duration = sql.NullInt64{Int64: int64(probe.DurationSecs), Valid: true}
				}
				// TASK-728: media specs for quality badges. Only the full probe has these;
				// the quick-probe fallback below leaves them null (badges simply absent).
				if probe.Width > 0 {
					videoWidth = sql.NullInt64{Int64: int64(probe.Width), Valid: true}
				}
				if probe.Height > 0 {
					videoHeight = sql.NullInt64{Int64: int64(probe.Height), Valid: true}
				}
				if probe.AudioChannels > 0 {
					audioChannels = sql.NullInt64{Int64: int64(probe.AudioChannels), Valid: true}
				}
			}
		}
		if !videoCodec.Valid {
			quickProbe := transcode.ProbeQuick(path)
			videoCodec = sql.NullString{String: quickProbe.VideoCodec, Valid: true}
			audioCodec = sql.NullString{String: quickProbe.AudioCodec, Valid: true}
			container = sql.NullString{String: quickProbe.Container, Valid: true}
			needsTranscode = sql.NullBool{Bool: quickProbe.NeedsTranscode, Valid: true}
		}

		// TASK-755: hand non-DirectPlay files to the auto-normalize worker. Enqueue is
		// deduplicated and non-blocking, so calling it on every scan is cheap — already
		// queued/in-progress items are ignored, and the worker re-decides against the
		// live file before doing any work (so a file converted by a prior run or by
		// convert-library.sh is skipped). `root` is the media root for this library,
		// used by the worker to preserve the relative path under the backup tree.
		if s.normalizeWorker != nil && needsTranscode.Valid && needsTranscode.Bool {
			s.normalizeWorker.Enqueue(id, path, root)
		}

		var year sql.NullInt64
		if parsed.Year > 0 {
			year = sql.NullInt64{Int64: int64(parsed.Year), Valid: true}
		}

		// TASK-571: compute showFolderID once at scan time and store it in the DB
		// so it remains stable even if TVPath config changes later.
		var showFolderID sql.NullString
		if libraryID == "lib_tv" && s.cfg.TVPath != "" {
			tvRoot := filepath.Clean(s.cfg.TVPath) + "/"
			rel := strings.TrimPrefix(path, tvRoot)
			parts := strings.SplitN(rel, "/", 2)
			if len(parts) > 1 && parts[0] != "" {
				showFolderID = sql.NullString{String: parts[0], Valid: true}
			}
		}

		seenPaths[path] = struct{}{}
		batch = append(batch, pendingRow{
			id: id, libraryID: libraryID, typ: typ, title: title, addedAt: addedAt,
			year: year, duration: duration, path: path, parsed: parsed,
			videoCodec: videoCodec, audioCodec: audioCodec, container: container,
			needsTranscode: needsTranscode, showFolderID: showFolderID,
			videoWidth: videoWidth, videoHeight: videoHeight, audioChannels: audioChannels,
		})

		if len(batch) >= batchSize {
			return flushBatch()
		}
		return nil
	})

	if walkErr != nil {
		return walkErr
	}
	if err := flushBatch(); err != nil {
		return err
	}

	// Remove stale DB entries whose files no longer exist on disk.
	// This handles files that were renamed or deleted (e.g. .mp4 → .mkv).
	staleRows, err := s.db.QueryContext(ctx, `SELECT id, path FROM items WHERE library_id = ?`, libraryID)
	if err == nil {
		var staleIDs []string
		for staleRows.Next() {
			var sid, spath string
			if staleRows.Scan(&sid, &spath) == nil {
				if _, seen := seenPaths[spath]; !seen {
					staleIDs = append(staleIDs, sid)
				}
			}
		}
		staleRows.Close()
		if len(staleIDs) > 0 {
			log.Printf("scan: removing %d stale items from library %s", len(staleIDs), libraryID)
			staleTx, err := s.db.BeginTx(ctx, nil)
			if err == nil {
				for _, sid := range staleIDs {
					// Assign a real change_seq so clients can detect the deletion via delta sync.
					var seq int64
					_ = staleTx.QueryRowContext(ctx,
						`UPDATE sync_state SET value = value + 1 WHERE key = 'item_seq' RETURNING value`,
					).Scan(&seq)
					if seq > 0 {
						s.cachedItemSeq.Store(seq)
					}
					_, _ = staleTx.ExecContext(ctx, `DELETE FROM items WHERE id = ?`, sid)
					_, _ = staleTx.ExecContext(ctx,
						`INSERT INTO deleted_items(item_id, change_seq, deleted_at) VALUES(?,?,?)`,
						sid, seq, now)
				}
				_ = staleTx.Commit()
			}
		}
	}

	// Transaction committed — write lock fully released before metadata fetches start.
	// Use a bounded worker pool (10 workers) to avoid spawning one goroutine per item.
	if len(metaPending) > 0 {
		const numWorkers = 10
		work := make(chan metaPendingItem, len(metaPending))
		for _, item := range metaPending {
			work <- item
		}
		close(work)
		for i := 0; i < numWorkers; i++ {
			go func() {
				for item := range work {
					s.fetchAndStoreMetadataWithClient(context.Background(), item.id, item.parsed, item.typ, tmdbClient)
				}
			}()
		}
	}

	return nil
}

// fetchAndStoreMetadata fetches metadata from TMDb and stores it in the database.
func (s *Server) fetchAndStoreMetadata(ctx context.Context, itemID string, parsed metadata.ParsedFilename, itemType string) {
	s.tmdbMu.RLock()
	client := s.tmdbClient
	s.tmdbMu.RUnlock()
	s.fetchAndStoreMetadataWithClient(ctx, itemID, parsed, itemType, client)
}

// Leading on-disk ordering prefix on a folder name: "01. ", "03 - ", "2) ".
var folderOrderPrefix = regexp.MustCompile(`^\s*\d{1,3}\s*[.)\-]\s*`)

func (s *Server) fetchAndStoreMetadataWithClient(ctx context.Context, itemID string, parsed metadata.ParsedFilename, itemType string, tmdbClient *metadata.TMDbClient) {
	if tmdbClient == nil {
		return
	}

	// Deduplicate: if another goroutine is already fetching this title, skip.
	key := fmt.Sprintf("%s|%d|%d|%d", strings.ToLower(parsed.Title), parsed.Year, parsed.Season, parsed.Episode)
	s.metaMu.Lock()
	if s.metaInFlight[key] {
		s.metaMu.Unlock()
		return
	}
	s.metaInFlight[key] = true
	s.metaMu.Unlock()
	defer func() {
		s.metaMu.Lock()
		delete(s.metaInFlight, key)
		s.metaMu.Unlock()
	}()

	// Rate-limit: acquire slot before calling TMDb.
	s.metaSemaphore <- struct{}{}
	defer func() { <-s.metaSemaphore }()

	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	var meta *metadata.VideoMetadata
	var err error

	if itemType == "episode" || parsed.IsTV {
		// Pass the containing folder name as a fallback query. The scanner parses only the
		// file's basename, so for a nested layout like
		//   .../Cartoon Shows/01. X-Men - PRYDE of The X-Men (Original 1989 Pilot)/file.mp4
		// the folder carries the real show name while the basename carries release noise.
		// Looked up from the row we are about to update rather than threaded through three
		// call sites; it is one indexed read on a path we already have.
		var itemPath string
		_ = s.db.QueryRow(`SELECT path FROM items WHERE id = ?`, itemID).Scan(&itemPath)
		folderName := ""
		if itemPath != "" {
			folderName = filepath.Base(filepath.Dir(itemPath))
			// Drop a leading ordering prefix ("01. ", "03 - ") that sorts folders on disk
			// but is not part of the show's name.
			folderName = folderOrderPrefix.ReplaceAllString(folderName, "")
		}
		meta, err = tmdbClient.FetchTVMetadataWithFallback(ctx, parsed.Title, folderName, parsed.Season, parsed.Episode)
	} else {
		meta, err = tmdbClient.FetchMovieMetadata(ctx, parsed.Title, parsed.Year)
	}

	if err != nil {
		log.Printf("Failed to fetch metadata for %s: %v", parsed.Title, err)
		// Mark as attempted so we don't spam the same failed title on every scan.
		now := time.Now().UTC().Format(time.RFC3339)
		_, _ = s.db.Exec(`UPDATE items SET metadata_fetched_at = ? WHERE id = ? AND metadata_fetched_at IS NULL`, now, itemID)
		return
	}

	if meta == nil {
		return
	}

	// Store metadata in database
	genres := strings.Join(meta.Genres, ",")
	cast := strings.Join(meta.Cast, ",")
	now := time.Now().UTC().Format(time.RFC3339)

	_, err = s.db.Exec(`
		UPDATE items SET
			tmdb_id = ?,
			imdb_id = ?,
			title = ?,
			original_title = ?,
			overview = ?,
			year = ?,
			poster_path = ?,
			backdrop_path = ?,
			rating = ?,
			genres = ?,
			director = ?,
			cast_names = ?,
			duration_seconds = COALESCE(?, duration_seconds),
			show_name = ?,
			season_number = ?,
			episode_number = ?,
			episode_title = ?,
			metadata_fetched_at = ?
		WHERE id = ?`,
		meta.TMDbID, meta.IMDbID, meta.Title, meta.OriginalTitle, meta.Overview,
		meta.Year, meta.PosterPath, meta.BackdropPath, meta.Rating, genres,
		meta.Director, cast, nullableInt(meta.Runtime*60), // runtime in seconds
		meta.ShowName, nullableInt(meta.SeasonNumber), nullableInt(meta.EpisodeNumber),
		meta.EpisodeTitle, now, itemID,
	)

	if err != nil {
		log.Printf("Failed to store metadata for %s: %v", itemID, err)
	} else {
		log.Printf("Fetched metadata for: %s", meta.Title)
	}
}

func nullableInt(v int) sql.NullInt64 {
	if v == 0 {
		return sql.NullInt64{}
	}
	return sql.NullInt64{Int64: int64(v), Valid: true}
}

// -------------------------
// TMDb Manual Fix Endpoints
// -------------------------

// handleItemTMDbSearch returns top-5 TMDb candidates for a library item.
// GET /api/v1/items/{id}/tmdb-search?q=...&year=...&type=movie|tv
func (s *Server) handleItemTMDbSearch(w http.ResponseWriter, r *http.Request) {
	s.tmdbMu.RLock()
	client := s.tmdbClient
	s.tmdbMu.RUnlock()
	if client == nil {
		writeErr(w, http.StatusBadRequest, "tmdb_not_configured")
		return
	}

	id := chi.URLParam(r, "id")

	// Look up item from DB to get title and type defaults.
	var title, typ string
	row := s.db.QueryRow(`SELECT title, type FROM items WHERE id = ?`, id)
	if err := row.Scan(&title, &typ); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			writeErr(w, http.StatusNotFound, "not_found")
		} else {
			writeErr(w, http.StatusInternalServerError, "db_error")
		}
		return
	}

	q := r.URL.Query().Get("q")
	if q == "" {
		q = title
	}
	yearStr := r.URL.Query().Get("year")
	year := 0
	if yearStr != "" {
		year, _ = strconv.Atoi(yearStr)
	}
	mediaType := r.URL.Query().Get("type")
	if mediaType == "" {
		if typ == "episode" {
			mediaType = "tv"
		} else {
			mediaType = "movie"
		}
	}

	type candidate struct {
		TMDbID     int    `json:"tmdbId"`
		Title      string `json:"title"`
		Year       *int   `json:"year"`
		Overview   string `json:"overview"`
		PosterPath string `json:"posterPath"`
		PosterURL  string `json:"posterURL,omitempty"`
		Type       string `json:"type"`
	}

	tmdbProxyURL := func(path string) string {
		if path == "" {
			return ""
		}
		return "/api/v1/tmdb/image?path=" + url.QueryEscape(path)
	}

	var results []candidate

	ctx := r.Context()
	if mediaType == "tv" {
		tvResults, err := client.SearchTV(ctx, q, year)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "tmdb_error")
			return
		}
		for i, res := range tvResults {
			if i >= 5 {
				break
			}
			var yr *int
			if len(res.FirstAirDate) >= 4 {
				y, err2 := strconv.Atoi(res.FirstAirDate[:4])
				if err2 == nil {
					yr = &y
				}
			}
			results = append(results, candidate{
				TMDbID:     res.ID,
				Title:      res.Name,
				Year:       yr,
				Overview:   res.Overview,
				PosterPath: res.PosterPath,
				PosterURL:  tmdbProxyURL(res.PosterPath),
				Type:       "tv",
			})
		}
	} else {
		movieResults, err := client.SearchMovies(ctx, q, year)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "tmdb_error")
			return
		}
		for i, res := range movieResults {
			if i >= 5 {
				break
			}
			var yr *int
			if len(res.ReleaseDate) >= 4 {
				y, err2 := strconv.Atoi(res.ReleaseDate[:4])
				if err2 == nil {
					yr = &y
				}
			}
			results = append(results, candidate{
				TMDbID:     res.ID,
				Title:      res.Title,
				Year:       yr,
				Overview:   res.Overview,
				PosterPath: res.PosterPath,
				PosterURL:  tmdbProxyURL(res.PosterPath),
				Type:       "movie",
			})
		}
	}

	if results == nil {
		results = []candidate{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"results": results})
}

// handleItemTMDbFix applies a specific TMDb ID to a library item.
// POST /api/v1/items/{id}/tmdb-fix  body: {"tmdbId":12345,"type":"movie"}
func (s *Server) handleItemTMDbFix(w http.ResponseWriter, r *http.Request) {
	s.tmdbMu.RLock()
	client := s.tmdbClient
	s.tmdbMu.RUnlock()
	if client == nil {
		writeErr(w, http.StatusBadRequest, "tmdb_not_configured")
		return
	}

	id := chi.URLParam(r, "id")

	var body struct {
		TMDbID int    `json:"tmdbId"`
		Type   string `json:"type"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.TMDbID == 0 {
		writeErr(w, http.StatusBadRequest, "invalid_body")
		return
	}

	// Default type from DB if not supplied.
	if body.Type == "" {
		var typ string
		if err := s.db.QueryRow(`SELECT type FROM items WHERE id = ?`, id).Scan(&typ); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				writeErr(w, http.StatusNotFound, "not_found")
			} else {
				writeErr(w, http.StatusInternalServerError, "db_error")
			}
			return
		}
		if typ == "episode" {
			body.Type = "tv"
		} else {
			body.Type = "movie"
		}
	}

	ctx := r.Context()
	now := time.Now().UTC().Format(time.RFC3339)

	if body.Type == "tv" {
		details, err := client.GetTVDetails(ctx, body.TMDbID)
		if err != nil {
			writeErr(w, http.StatusBadGateway, "tmdb_error")
			return
		}
		var yr int
		if len(details.FirstAirDate) >= 4 {
			yr, _ = strconv.Atoi(details.FirstAirDate[:4])
		}
		genreNames := make([]string, len(details.Genres))
		for i, g := range details.Genres {
			genreNames[i] = g.Name
		}
		genres := strings.Join(genreNames, ",")
		var castNames []string
		if details.Credits != nil {
			for i, c := range details.Credits.Cast {
				if i >= 5 {
					break
				}
				castNames = append(castNames, c.Name)
			}
		}
		cast := strings.Join(castNames, ",")

		_, err = s.db.Exec(`
			UPDATE items SET
				tmdb_id = ?,
				title = ?,
				original_title = ?,
				overview = ?,
				year = ?,
				poster_path = ?,
				backdrop_path = ?,
				rating = ?,
				genres = ?,
				cast_names = ?,
				metadata_fetched_at = ?
			WHERE id = ?`,
			details.ID, details.Name, details.OriginalName, details.Overview,
			yr, details.PosterPath, details.BackdropPath, details.VoteAverage,
			genres, cast, now, id,
		)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "db_error")
			return
		}
	} else {
		details, err := client.GetMovieDetails(ctx, body.TMDbID)
		if err != nil {
			writeErr(w, http.StatusBadGateway, "tmdb_error")
			return
		}
		var yr int
		if len(details.ReleaseDate) >= 4 {
			yr, _ = strconv.Atoi(details.ReleaseDate[:4])
		}
		genreNames := make([]string, len(details.Genres))
		for i, g := range details.Genres {
			genreNames[i] = g.Name
		}
		genres := strings.Join(genreNames, ",")
		var castNames []string
		var director string
		if details.Credits != nil {
			for i, c := range details.Credits.Cast {
				if i >= 5 {
					break
				}
				castNames = append(castNames, c.Name)
			}
			for _, c := range details.Credits.Crew {
				if c.Job == "Director" {
					director = c.Name
					break
				}
			}
		}
		cast := strings.Join(castNames, ",")

		_, err = s.db.Exec(`
			UPDATE items SET
				tmdb_id = ?,
				imdb_id = ?,
				title = ?,
				original_title = ?,
				overview = ?,
				year = ?,
				poster_path = ?,
				backdrop_path = ?,
				rating = ?,
				genres = ?,
				director = ?,
				cast_names = ?,
				duration_seconds = COALESCE(?, duration_seconds),
				metadata_fetched_at = ?
			WHERE id = ?`,
			details.ID, details.IMDbID, details.Title, details.OriginalTitle, details.Overview,
			yr, details.PosterPath, details.BackdropPath, details.VoteAverage,
			genres, director, cast, nullableInt(details.Runtime*60), now, id,
		)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "db_error")
			return
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{"success": true})
}

// handleTVShowTMDbSearch returns top-5 TMDb TV candidates for a show folder.
// GET /api/v1/tv/shows/{showId}/tmdb-search
func (s *Server) handleTVShowTMDbSearch(w http.ResponseWriter, r *http.Request) {
	s.tmdbMu.RLock()
	client := s.tmdbClient
	s.tmdbMu.RUnlock()
	if client == nil {
		writeErr(w, http.StatusBadRequest, "tmdb_not_configured")
		return
	}

	showID := chi.URLParam(r, "showId")
	// Decode percent-encoding (show IDs may be URL-encoded folder names).
	if decoded, err := url.PathUnescape(showID); err == nil {
		showID = decoded
	}

	q := r.URL.Query().Get("q")
	if q == "" {
		q = showID
	}

	type candidate struct {
		TMDbID     int    `json:"tmdbId"`
		Title      string `json:"title"`
		Year       *int   `json:"year"`
		Overview   string `json:"overview"`
		PosterPath string `json:"posterPath"`
		PosterURL  string `json:"posterURL,omitempty"`
		Type       string `json:"type"`
	}

	tvResults, err := client.SearchTV(r.Context(), q, 0)

	if err != nil {
		writeErr(w, http.StatusInternalServerError, "tmdb_error")
		return
	}

	var results []candidate
	for i, res := range tvResults {
		if i >= 10 {
			break
		}
		var yr *int
		if len(res.FirstAirDate) >= 4 {
			y, err2 := strconv.Atoi(res.FirstAirDate[:4])
			if err2 == nil {
				yr = &y
			}
		}
		posterURL := ""
		if res.PosterPath != "" {
			posterURL = "/api/v1/tmdb/image?path=" + url.QueryEscape(res.PosterPath)
		}
		results = append(results, candidate{
			TMDbID:     res.ID,
			Title:      res.Name,
			Year:       yr,
			Overview:   res.Overview,
			PosterPath: res.PosterPath,
			PosterURL:  posterURL,
			Type:       "tv",
		})
	}
	if results == nil {
		results = []candidate{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"results": results})
}

// handleTVShowTMDbFix applies a specific TMDb TV show ID to all episodes for a show folder.
// POST /api/v1/tv/shows/{showId}/tmdb-fix  body: {"tmdbId":12345}
func (s *Server) handleTVShowTMDbFix(w http.ResponseWriter, r *http.Request) {
	s.tmdbMu.RLock()
	client := s.tmdbClient
	s.tmdbMu.RUnlock()
	if client == nil {
		writeErr(w, http.StatusBadRequest, "tmdb_not_configured")
		return
	}

	showID := chi.URLParam(r, "showId")
	if decoded, err := url.PathUnescape(showID); err == nil {
		showID = decoded
	}
	// Reject path traversal: showID must not contain path separators.
	if strings.Contains(showID, "/") || strings.Contains(showID, "..") {
		writeErr(w, http.StatusBadRequest, "invalid_show_id")
		return
	}
	// Escape SQL LIKE wildcards so a showID containing '%' or '_' doesn't match unintended rows.
	escapedShowID := strings.ReplaceAll(showID, `\`, `\\`)
	escapedShowID = strings.ReplaceAll(escapedShowID, "%", `\%`)
	escapedShowID = strings.ReplaceAll(escapedShowID, "_", `\_`)

	var body struct {
		TMDbID int `json:"tmdbId"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.TMDbID == 0 {
		writeErr(w, http.StatusBadRequest, "invalid_body")
		return
	}

	ctx := r.Context()
	details, err := client.GetTVDetails(ctx, body.TMDbID)
	if err != nil {
		writeErr(w, http.StatusBadGateway, "tmdb_error")
		return
	}

	var yr int
	if len(details.FirstAirDate) >= 4 {
		yr, _ = strconv.Atoi(details.FirstAirDate[:4])
	}
	genreNames := make([]string, len(details.Genres))
	for i, g := range details.Genres {
		genreNames[i] = g.Name
	}
	genres := strings.Join(genreNames, ",")
	var castNames []string
	if details.Credits != nil {
		for i, c := range details.Credits.Cast {
			if i >= 5 {
				break
			}
			castNames = append(castNames, c.Name)
		}
	}
	cast := strings.Join(castNames, ",")
	now := time.Now().UTC().Format(time.RFC3339)

	tvRoot := filepath.Clean(s.cfg.TVPath) + "/"
	folderPrefix := tvRoot + escapedShowID + "/"

	// Update all episodes in a transaction, bumping change_seq on each row so
	// the delta sync delivers the new metadata (and new image cache-buster) to clients.
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	defer tx.Rollback()

	// Collect affected item IDs first.
	idRows, err := tx.QueryContext(ctx, `SELECT id FROM items WHERE path LIKE ? ESCAPE '\' AND library_id = 'lib_tv'`, folderPrefix+"%")
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	var affectedIDs []string
	for idRows.Next() {
		var id string
		if idRows.Scan(&id) == nil {
			affectedIDs = append(affectedIDs, id)
		}
	}
	idRows.Close()
	if len(affectedIDs) == 0 {
		writeErr(w, http.StatusNotFound, "show_not_found")
		return
	}

	for _, id := range affectedIDs {
		var seq int64
		_ = tx.QueryRowContext(ctx,
			`UPDATE sync_state SET value = value + 1 WHERE key = 'item_seq' RETURNING value`,
		).Scan(&seq)
		if seq > 0 {
			s.cachedItemSeq.Store(seq)
		}
		if _, err := tx.ExecContext(ctx, `
			UPDATE items SET
				tmdb_id = ?,
				show_name = ?,
				overview = ?,
				year = ?,
				poster_path = ?,
				backdrop_path = ?,
				rating = ?,
				genres = ?,
				cast_names = ?,
				metadata_fetched_at = ?,
				change_seq = ?
			WHERE id = ?`,
			details.ID, details.Name, details.Overview,
			yr, details.PosterPath, details.BackdropPath, details.VoteAverage,
			genres, cast, now, seq, id,
		); err != nil {
			writeErr(w, http.StatusInternalServerError, "db_error")
			return
		}
	}

	if err := tx.Commit(); err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}

	// Background: re-fetch per-episode TMDb metadata (titles, episode numbers, thumbnails)
	// using the newly assigned tmdbID. This runs asynchronously so the HTTP response is fast.
	tmdbID := details.ID
	go func() {
		bgCtx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		defer cancel()
		type epRow struct {
			id            string
			path          string
			seasonNumber  sql.NullInt64
			episodeNumber sql.NullInt64
		}
		epRows, err := s.db.QueryContext(bgCtx,
			`SELECT id, path, season_number, episode_number FROM items WHERE path LIKE ? ESCAPE '\' AND library_id = 'lib_tv'`,
			folderPrefix+"%")
		if err != nil {
			return
		}
		var episodes []epRow
		for epRows.Next() {
			var ep epRow
			if epRows.Scan(&ep.id, &ep.path, &ep.seasonNumber, &ep.episodeNumber) == nil {
				episodes = append(episodes, ep)
			}
		}
		epRows.Close()

		for _, ep := range episodes {
			sn := int(ep.seasonNumber.Int64)
			en := int(ep.episodeNumber.Int64)
			// Fall back to filename parsing when DB season/episode are NULL (e.g. space-separated S01 E01 format).
			if sn <= 0 || en <= 0 {
				parsed := metadata.ParseFilename(filepath.Base(ep.path))
				sn = parsed.Season
				en = parsed.Episode
			}
			if sn <= 0 || en <= 0 {
				continue
			}
			epDetails, err := client.GetTVEpisode(bgCtx, tmdbID, sn, en)
			if err != nil {
				continue
			}
			var seq int64
			_ = s.db.QueryRowContext(bgCtx,
				`UPDATE sync_state SET value = value + 1 WHERE key = 'item_seq' RETURNING value`,
			).Scan(&seq)
			if seq > 0 {
				s.cachedItemSeq.Store(seq)
			}
			_, _ = s.db.ExecContext(bgCtx, `
				UPDATE items SET
					episode_title = ?,
					episode_number = ?,
					season_number = ?,
					poster_path = COALESCE(NULLIF(?, ''), poster_path),
					change_seq = ?
				WHERE id = ?`,
				epDetails.Name, epDetails.EpisodeNumber, epDetails.SeasonNumber,
				epDetails.StillPath, seq, ep.id,
			)
		}
		log.Printf("tmdb-fix: re-fetched episode metadata for %d episodes (show tmdb_id=%d)", len(episodes), tmdbID)
	}()

	writeJSON(w, http.StatusOK, map[string]any{"success": true, "updatedCount": len(affectedIDs)})
}

// -------------------------
// Helpers
// -------------------------

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, code string) {
	writeJSON(w, status, map[string]any{"error": code})
}

func parseInt(s string, def int) int {
	if s == "" {
		return def
	}
	var v int
	_, err := fmt.Sscanf(s, "%d", &v)
	if err != nil {
		return def
	}
	return v
}

func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func nullIntToAny(v sql.NullInt64) any {
	if !v.Valid {
		return nil
	}
	return v.Int64
}

func nullFloatToAny(v sql.NullFloat64) any {
	if !v.Valid {
		return nil
	}
	return v.Float64
}

func nullStringToAny(v sql.NullString) any {
	if !v.Valid {
		return nil
	}
	return v.String
}

// validateOriginalsDir checks that the auto-normalize backup dir is safe for the
// retention reaper to recursively delete from. Worf P2-5 (TASK-755): the reaper deletes
// everything older than N days under this dir, so it must never be empty, a filesystem
// root, equal to any media root, or a PARENT of any media root (which would put the
// library under the reaper's blast radius). Returns "" when safe, else a human-readable
// reason the caller logs while disabling the reaper.
func validateOriginalsDir(originalsDir string, mediaRoots ...string) string {
	od := strings.TrimSpace(originalsDir)
	if od == "" {
		return "originals dir is empty"
	}
	cleanOD := filepath.Clean(od)
	// A filesystem root (e.g. "/" or a Windows volume root) cleans to a path whose parent
	// is itself. Refuse — reaping from root is catastrophic.
	if parent := filepath.Dir(cleanOD); parent == cleanOD {
		return "originals dir is a filesystem root"
	}
	for _, mr := range mediaRoots {
		mr = strings.TrimSpace(mr)
		if mr == "" {
			continue
		}
		cleanMR := filepath.Clean(mr)
		if cleanOD == cleanMR {
			return fmt.Sprintf("originals dir equals media root %q", cleanMR)
		}
		// originals dir is a parent of (or identical to) a media root → the media root
		// lives under the reaper. filepath.Rel gives a non-".." relative path when cleanMR
		// is at or below cleanOD.
		if rel, err := filepath.Rel(cleanOD, cleanMR); err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return fmt.Sprintf("originals dir is a parent of media root %q", cleanMR)
		}
	}
	return ""
}

func itemIDFromPath(path string) string {
	// Deterministic but stable: hex of cleaned path.
	clean := filepath.Clean(path)
	return "it_" + hex.EncodeToString([]byte(clean))
}

func titleFromFilename(name string) string {
	base := strings.TrimSuffix(name, filepath.Ext(name))
	base = strings.ReplaceAll(base, ".", " ")
	base = strings.ReplaceAll(base, "_", " ")
	base = strings.TrimSpace(base)
	if base == "" {
		return "Untitled"
	}
	return base
}

func sanitizeID(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	s = strings.Map(func(r rune) rune {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			return r
		}
		return '_'
	}, s)
	return strings.Trim(s, "_")
}

func randID(prefix string) string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return prefix + hex.EncodeToString(b[:])
}

// requestBaseURL derives a base URL for building stream URLs returned to the client.
// If cfgBaseURL is set (non-empty, non-localhost), it is used directly — this is the
// correct value for relay/QuickConnect deployments where nginx sets X-Forwarded-Proto:https
// but the relay only speaks HTTP, causing scheme confusion when derived from headers.
// Falls back to deriving from the request Host header for direct-IP deployments.
func requestBaseURL(r *http.Request, cfgBaseURL string) string {
	// Operator-configured base URL takes priority (relay/QuickConnect deployments).
	// Skip loopback values — the start script defaults to http://127.0.0.1:PORT which
	// is not a useful external URL; treat those the same as unset.
	isLoopback := strings.HasPrefix(cfgBaseURL, "http://localhost") ||
		strings.HasPrefix(cfgBaseURL, "https://localhost") ||
		strings.HasPrefix(cfgBaseURL, "http://127.") ||
		strings.HasPrefix(cfgBaseURL, "https://127.")
	if cfgBaseURL != "" && !isLoopback {
		return strings.TrimRight(cfgBaseURL, "/")
	}
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	// Prefer X-Forwarded-Host (explicitly set by our nginx config) over r.Host.
	// DSM nginx may proxy with HTTP/1.0 which doesn't reliably forward the Host
	// header — X-Forwarded-Host is always set to $http_host so it's trustworthy.
	host := r.Header.Get("X-Forwarded-Host")
	if host == "" {
		host = r.Host
	}
	if host == "" {
		host = r.URL.Host
	}
	// Respect X-Forwarded-Proto from reverse proxies (e.g., DSM nginx).
	// Exception: QuickConnect relay always speaks HTTP regardless of nginx's proto.
	if proto := r.Header.Get("X-Forwarded-Proto"); proto != "" {
		if strings.Contains(host, "quickconnect.to") {
			scheme = "http"
		} else {
			scheme = proto
		}
	}
	if host == "" {
		return "http://localhost:8080" // fallback
	}
	return scheme + "://" + host
}

// -------------------------
// /api/v1/tv/shows — iOS app TV show endpoints
// -------------------------

// handleTVShowsList returns shows in the TVShowsResponse format expected by the iOS app:
// { "shows": [{ "id", "title", "year", "seasonCount", "episodeCount", "posterImageId", "lastWatchedAt" }] }
func (s *Server) handleTVShowsList(w http.ResponseWriter, r *http.Request) {
	if s.cfg.TVPath == "" {
		writeJSON(w, http.StatusOK, map[string]any{"shows": []any{}})
		return
	}
	u := userFromCtx(r.Context())
	tvRoot := filepath.Clean(s.cfg.TVPath) + "/"

	rows, err := s.db.Query(`
		SELECT id, path, show_name, year, poster_path, season_number, added_at, change_seq
		FROM items WHERE library_id = 'lib_tv'
		ORDER BY season_number ASC, path ASC`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	defer rows.Close()

	type showInfo struct {
		folderName   string
		displayName  string
		year         sql.NullInt64
		poster       string
		firstID      string
		count        int
		seasons      map[int]bool
		newestAdded  string // ISO8601 — MAX(added_at) across episodes
		maxChangeSeq int64  // max change_seq across episodes — used as image cache-buster
	}

	showMap := map[string]*showInfo{}
	showOrder := []string{}

	for rows.Next() {
		var id, path string
		var showName sql.NullString
		var year sql.NullInt64
		var posterPath sql.NullString
		var seasonNum sql.NullInt64
		var addedAt sql.NullString
		var changeSeq sql.NullInt64

		if err := rows.Scan(&id, &path, &showName, &year, &posterPath, &seasonNum, &addedAt, &changeSeq); err != nil {
			continue
		}

		var folderName string
		rel := strings.TrimPrefix(path, tvRoot)
		parts := strings.SplitN(rel, "/", 2)
		if len(parts) > 1 {
			folderName = parts[0]
		} else {
			base := filepath.Base(path)
			folderName = strings.TrimSuffix(base, filepath.Ext(base))
		}
		if folderName == "" {
			continue
		}

		// Use TMDb show_name (lowercased) as the dedup key when available so that
		// episodes split across differently-named folders for the same show merge correctly.
		mapKey := folderName
		if showName.Valid && showName.String != "" {
			mapKey = strings.ToLower(showName.String)
		}

		info, exists := showMap[mapKey]
		if !exists {
			info = &showInfo{folderName: folderName, displayName: folderName, seasons: map[int]bool{}}
			showMap[mapKey] = info
			showOrder = append(showOrder, mapKey)
		}
		if showName.Valid && showName.String != "" && info.displayName == info.folderName {
			info.displayName = showName.String
		}
		info.count++
		if year.Valid && (!info.year.Valid || year.Int64 < info.year.Int64) {
			info.year = year
		}
		if posterPath.Valid && posterPath.String != "" && info.firstID == "" {
			info.firstID = id
		}
		if addedAt.Valid && addedAt.String > info.newestAdded {
			info.newestAdded = addedAt.String
		}
		if changeSeq.Valid && changeSeq.Int64 > info.maxChangeSeq {
			info.maxChangeSeq = changeSeq.Int64
		}
		sn := 1
		if seasonNum.Valid && seasonNum.Int64 > 0 {
			sn = int(seasonNum.Int64)
		}
		info.seasons[sn] = true
	}

	// Build per-show lastWatchedAt from progress table when a user is authenticated.
	// Single query: find MAX(updated_at) for each item path under the TV root for this user.
	showLastWatched := map[string]string{} // folderName → ISO8601 timestamp
	if u.ID != "" {
		progressRows, pErr := s.db.Query(`
			SELECT i.path, MAX(p.updated_at)
			FROM progress p
			JOIN items i ON i.id = p.item_id
			WHERE i.library_id = 'lib_tv' AND p.user_id = ?
			GROUP BY i.path`, u.ID)
		if pErr == nil {
			defer progressRows.Close()
			for progressRows.Next() {
				var itemPath string
				var maxUpdated sql.NullString
				if err2 := progressRows.Scan(&itemPath, &maxUpdated); err2 != nil || !maxUpdated.Valid {
					continue
				}
				rel := strings.TrimPrefix(itemPath, tvRoot)
				parts := strings.SplitN(rel, "/", 2)
				if len(parts) < 2 {
					continue
				}
				folder := parts[0]
				if existing, ok := showLastWatched[folder]; !ok || maxUpdated.String > existing {
					showLastWatched[folder] = maxUpdated.String
				}
			}
		}
	}

	// Sort alphabetically by display name.
	sortedKeys := make([]string, len(showOrder))
	copy(sortedKeys, showOrder)
	sort.Slice(sortedKeys, func(i, j int) bool {
		return strings.ToLower(showMap[sortedKeys[i]].displayName) < strings.ToLower(showMap[sortedKeys[j]].displayName)
	})

	shows := make([]map[string]any, 0, len(sortedKeys))
	for _, key := range sortedKeys {
		info := showMap[key]
		show := map[string]any{
			"id":              info.folderName,
			"title":           info.displayName,
			"year":            nullIntToAny(info.year),
			"seasonCount":     len(info.seasons),
			"episodeCount":    info.count,
			"posterImageId":   nil,
			"lastWatchedAt":   nil,
			"addedAt":         nil,
			"metadataVersion": info.maxChangeSeq,
		}
		if info.firstID != "" {
			show["posterImageId"] = info.firstID
		}
		if ts, ok := showLastWatched[info.folderName]; ok && ts != "" {
			show["lastWatchedAt"] = ts
		}
		if info.newestAdded != "" {
			show["addedAt"] = info.newestAdded
		}
		shows = append(shows, show)
	}

	writeJSON(w, http.StatusOK, map[string]any{"shows": shows})
}

// handleTVShowSeasons returns season summary for a show:
// { "seasons": [{ "seasonNumber", "episodeCount" }] }
func (s *Server) handleTVShowSeasons(w http.ResponseWriter, r *http.Request) {
	if s.cfg.TVPath == "" {
		writeJSON(w, http.StatusOK, map[string]any{"seasons": []any{}})
		return
	}
	showID := chi.URLParam(r, "showId")
	if showID == "" {
		writeErr(w, http.StatusBadRequest, "missing_show_id")
		return
	}
	decoded, err := url.PathUnescape(showID)
	if err == nil {
		showID = decoded
	}
	if strings.Contains(showID, "/") || strings.Contains(showID, "..") {
		writeErr(w, http.StatusBadRequest, "invalid_show_id")
		return
	}
	escapedID := strings.ReplaceAll(showID, `\`, `\\`)
	escapedID = strings.ReplaceAll(escapedID, "%", `\%`)
	escapedID = strings.ReplaceAll(escapedID, "_", `\_`)

	tvRoot := filepath.Clean(s.cfg.TVPath) + "/"
	folderPrefix := tvRoot + escapedID + "/"

	querySeasons := func(where string, arg any) ([]map[string]any, error) {
		r, e := s.db.Query(`
			SELECT COALESCE(season_number, 1), COUNT(*)
			FROM items
			WHERE `+where+` AND library_id = 'lib_tv'
			GROUP BY COALESCE(season_number, 1)
			ORDER BY COALESCE(season_number, 1)`, arg)
		if e != nil {
			return nil, e
		}
		defer r.Close()
		var out []map[string]any
		for r.Next() {
			var sn, count int
			if e2 := r.Scan(&sn, &count); e2 == nil {
				out = append(out, map[string]any{"seasonNumber": sn, "episodeCount": count})
			}
		}
		return out, nil
	}

	seasons, err := querySeasons(`path LIKE ? ESCAPE '\'`, folderPrefix+"%")
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}
	// Fallback: if showID came from showName (TMDb title) rather than folder name,
	// path LIKE won't match — retry by show_name column.
	if len(seasons) == 0 {
		seasons, _ = querySeasons("show_name = ?", showID)
	}
	if seasons == nil {
		seasons = []map[string]any{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"seasons": seasons})
}

// handleTVShowEpisodes returns episodes for a show (optionally filtered by season):
// { "total", "items": [ItemSummary] }
func (s *Server) handleTVShowEpisodes(w http.ResponseWriter, r *http.Request) {
	if s.cfg.TVPath == "" {
		writeJSON(w, http.StatusOK, map[string]any{"total": 0, "items": []any{}})
		return
	}
	showID := chi.URLParam(r, "showId")
	if showID == "" {
		writeErr(w, http.StatusBadRequest, "missing_show_id")
		return
	}
	decoded, err := url.PathUnescape(showID)
	if err == nil {
		showID = decoded
	}
	if strings.Contains(showID, "/") || strings.Contains(showID, "..") {
		writeErr(w, http.StatusBadRequest, "invalid_show_id")
		return
	}
	escapedID := strings.ReplaceAll(showID, `\`, `\\`)
	escapedID = strings.ReplaceAll(escapedID, "%", `\%`)
	escapedID = strings.ReplaceAll(escapedID, "_", `\_`)

	seasonStr := r.URL.Query().Get("season")
	u := userFromCtx(r.Context())

	tvRoot := filepath.Clean(s.cfg.TVPath) + "/"
	folderPrefix := tvRoot + escapedID + "/"

	baseWhere := `path LIKE ? ESCAPE '\' AND library_id = 'lib_tv'`
	baseArgs := []any{folderPrefix + "%"}

	// Check if the path-based match returns any rows; if not, fall back to show_name
	// (handles the case where showID is the TMDb display name rather than the folder name).
	var matchCount int
	s.db.QueryRow("SELECT COUNT(*) FROM items WHERE "+baseWhere, baseArgs...).Scan(&matchCount)
	if matchCount == 0 {
		baseWhere = "show_name = ? AND library_id = 'lib_tv'"
		baseArgs = []any{showID}
	}

	where := baseWhere
	args := baseArgs

	if seasonStr != "" {
		if sn, err := strconv.Atoi(seasonStr); err == nil {
			where += " AND COALESCE(season_number, 1) = ?"
			args = append(args, sn)
		}
	}

	var total int
	s.db.QueryRow("SELECT COUNT(*) FROM items WHERE "+where, args...).Scan(&total)

	rows, err := s.db.Query(`
		SELECT id, type, title, episode_title, year, duration_seconds, added_at, rating,
		       poster_path, backdrop_path, season_number, episode_number
		FROM items WHERE `+where+`
		ORDER BY COALESCE(season_number, 1), COALESCE(episode_number, 0)`,
		args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "db_error")
		return
	}

	// Collect rows into memory first so we release the DB connection before
	// making additional queries (getProgress). Holding a rows cursor open while
	// issuing nested QueryRow calls exhausts the connection pool under concurrent
	// season requests, causing all requests to deadlock.
	type episodeRow struct {
		id, typ, title, addedAt                string
		year, duration, seasonNum, episodeNum  sql.NullInt64
		rating                                 sql.NullFloat64
		posterPath, backdropPath, episodeTitle sql.NullString
	}
	var rawRows []episodeRow
	for rows.Next() {
		var r episodeRow
		if err := rows.Scan(&r.id, &r.typ, &r.title, &r.episodeTitle, &r.year, &r.duration, &r.addedAt, &r.rating,
			&r.posterPath, &r.backdropPath, &r.seasonNum, &r.episodeNum); err != nil {
			continue
		}
		rawRows = append(rawRows, r)
	}
	rows.Close() // release connection before any further DB calls

	// Batch-fetch progress for all episodes in one query.
	progressMap := map[string]map[string]any{}
	if u.ID != "" && len(rawRows) > 0 {
		ids := make([]string, len(rawRows))
		for i, r := range rawRows {
			ids[i] = r.id
		}
		placeholders := strings.Repeat("?,", len(ids))
		placeholders = placeholders[:len(placeholders)-1]
		pArgs := make([]any, len(ids)+1)
		pArgs[0] = u.ID
		for i, id := range ids {
			pArgs[i+1] = id
		}
		pRows, pErr := s.db.Query(
			"SELECT item_id, position_seconds, duration_seconds, updated_at FROM progress WHERE user_id = ? AND item_id IN ("+placeholders+")",
			pArgs...)
		if pErr == nil {
			defer pRows.Close()
			for pRows.Next() {
				var itemID, updatedAt string
				var pos, dur int
				if pRows.Scan(&itemID, &pos, &dur, &updatedAt) == nil {
					progressMap[itemID] = map[string]any{
						"positionSeconds": pos,
						"durationSeconds": dur,
						"updatedAt":       updatedAt,
					}
				}
			}
		}
	}

	// Deduplicate by (season, episode) — multiple files for the same episode
	// (e.g. different formats) produce duplicate rows; keep the first seen.
	seenEpisode := map[[2]int64]bool{}
	items := make([]map[string]any, 0, len(rawRows))
	for _, r := range rawRows {
		if r.seasonNum.Valid && r.episodeNum.Valid {
			key := [2]int64{r.seasonNum.Int64, r.episodeNum.Int64}
			if seenEpisode[key] {
				continue
			}
			seenEpisode[key] = true
		}

		// Use episode_title (from TMDb) when available; fall back to filename-parsed title
		displayTitle := r.title
		if r.episodeTitle.Valid && r.episodeTitle.String != "" {
			displayTitle = r.episodeTitle.String
		}

		item := map[string]any{
			"id":              r.id,
			"type":            r.typ,
			"title":           displayTitle,
			"year":            nullIntToAny(r.year),
			"durationSeconds": nullIntToAny(r.duration),
			"addedAt":         r.addedAt,
			"rating":          nullFloatToAny(r.rating),
			"posterImageId":   nil,
			"backdropImageId": nil,
			"seasonNumber":    nullIntToAny(r.seasonNum),
			"episodeNumber":   nullIntToAny(r.episodeNum),
		}
		if r.posterPath.Valid && r.posterPath.String != "" {
			item["posterImageId"] = r.id
		}
		if r.backdropPath.Valid && r.backdropPath.String != "" {
			item["backdropImageId"] = r.id
		}
		if p, ok := progressMap[r.id]; ok {
			item["progress"] = p
		}
		items = append(items, item)
	}
	writeJSON(w, http.StatusOK, map[string]any{"total": total, "items": items})
}
