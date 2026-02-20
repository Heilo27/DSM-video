package transcode

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// CleanupConfig contains configuration for the cleanup manager.
type CleanupConfig struct {
	InactivityTimeout time.Duration // How long before cleaning up inactive sessions (default: 2 hours)
	CheckInterval     time.Duration // How often to check for stale sessions (default: 5 minutes)
	TempDir           string        // Base directory for transcode output
}

// DefaultCleanupConfig returns sensible defaults.
func DefaultCleanupConfig() CleanupConfig {
	return CleanupConfig{
		InactivityTimeout: 2 * time.Hour,
		CheckInterval:     5 * time.Minute,
	}
}

// CleanupManager handles cleanup of stale transcode sessions.
type CleanupManager struct {
	config    CleanupConfig
	generator *HLSGenerator

	mu       sync.Mutex
	running  bool
	stopChan chan struct{}
	doneChan chan struct{}
}

// NewCleanupManager creates a new cleanup manager.
func NewCleanupManager(config CleanupConfig, generator *HLSGenerator) *CleanupManager {
	if config.InactivityTimeout == 0 {
		config.InactivityTimeout = 2 * time.Hour
	}
	if config.CheckInterval == 0 {
		config.CheckInterval = 5 * time.Minute
	}
	if config.TempDir == "" {
		config.TempDir = filepath.Join(os.TempDir(), "dsvideo_transcode")
	}

	return &CleanupManager{
		config:    config,
		generator: generator,
	}
}

// Start begins the cleanup goroutine.
func (m *CleanupManager) Start(ctx context.Context) {
	m.mu.Lock()
	if m.running {
		m.mu.Unlock()
		return
	}
	m.running = true
	m.stopChan = make(chan struct{})
	m.doneChan = make(chan struct{})
	m.mu.Unlock()

	go m.run(ctx)
}

// Stop stops the cleanup goroutine and waits for it to finish.
func (m *CleanupManager) Stop() {
	m.mu.Lock()
	if !m.running {
		m.mu.Unlock()
		return
	}
	m.running = false
	close(m.stopChan)
	m.mu.Unlock()

	<-m.doneChan
}

// run is the main cleanup loop.
func (m *CleanupManager) run(ctx context.Context) {
	defer close(m.doneChan)

	// Initial cleanup on startup
	m.cleanupOrphanedDirs()

	ticker := time.NewTicker(m.config.CheckInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			m.cleanupAll()
			return
		case <-m.stopChan:
			m.cleanupAll()
			return
		case <-ticker.C:
			m.cleanupInactive()
			m.cleanupOrphanedDirs()
		}
	}
}

// cleanupInactive removes sessions that have been inactive for too long.
func (m *CleanupManager) cleanupInactive() {
	if m.generator == nil {
		return
	}

	now := time.Now()
	threshold := now.Add(-m.config.InactivityTimeout)

	for _, sessionID := range m.generator.AllSessions() {
		session, ok := m.generator.GetSession(sessionID)
		if !ok {
			continue
		}

		// Check if session is stale
		if session.LastAccess.Before(threshold) {
			log.Printf("[transcode] Cleaning up inactive session %s (last access: %v)", sessionID, session.LastAccess)
			if err := m.generator.StopSession(sessionID); err != nil {
				log.Printf("[transcode] Failed to cleanup session %s: %v", sessionID, err)
			}
		}
	}
}

// cleanupOrphanedDirs removes transcode directories that don't have active sessions.
func (m *CleanupManager) cleanupOrphanedDirs() {
	entries, err := os.ReadDir(m.config.TempDir)
	if err != nil {
		// Directory might not exist yet, which is fine
		return
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

		sessionID := entry.Name()

		// Skip if there's an active session
		if m.generator != nil {
			if _, ok := m.generator.GetSession(sessionID); ok {
				continue
			}
		}

		// Check directory age
		dirPath := filepath.Join(m.config.TempDir, sessionID)
		info, err := entry.Info()
		if err != nil {
			continue
		}

		// If directory is old (older than inactivity timeout), clean it up
		if time.Since(info.ModTime()) > m.config.InactivityTimeout {
			log.Printf("[transcode] Cleaning up orphaned directory: %s", sessionID)
			if err := os.RemoveAll(dirPath); err != nil {
				log.Printf("[transcode] Failed to remove orphaned directory %s: %v", sessionID, err)
			}
		}
	}
}

// cleanupAll removes all transcode sessions and directories.
func (m *CleanupManager) cleanupAll() {
	log.Printf("[transcode] Cleaning up all sessions on shutdown")

	// Stop all active sessions
	if m.generator != nil {
		for _, sessionID := range m.generator.AllSessions() {
			if err := m.generator.StopSession(sessionID); err != nil {
				log.Printf("[transcode] Failed to stop session %s: %v", sessionID, err)
			}
		}
	}

	// Remove the entire temp directory
	if err := os.RemoveAll(m.config.TempDir); err != nil {
		log.Printf("[transcode] Failed to remove temp directory: %v", err)
	}
}

// CleanupSession explicitly cleans up a specific session.
func (m *CleanupManager) CleanupSession(sessionID string) error {
	if m.generator == nil {
		return nil
	}
	return m.generator.StopSession(sessionID)
}

// SessionInfo contains information about a session for cleanup purposes.
type SessionInfo struct {
	SessionID     string
	OutputDir     string
	LastAccess    time.Time
	CompletedAt   *time.Time
	IsActive      bool
	SizeBytes     int64
	SegmentCount  int
}

// ListSessions returns information about all sessions.
func (m *CleanupManager) ListSessions() []SessionInfo {
	var sessions []SessionInfo

	entries, err := os.ReadDir(m.config.TempDir)
	if err != nil {
		return sessions
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

		sessionID := entry.Name()
		dirPath := filepath.Join(m.config.TempDir, sessionID)

		info := SessionInfo{
			SessionID: sessionID,
			OutputDir: dirPath,
		}

		// Check if there's an active generator session
		if m.generator != nil {
			if session, ok := m.generator.GetSession(sessionID); ok {
				info.LastAccess = session.LastAccess
				info.CompletedAt = session.CompletedAt
				info.IsActive = session.CompletedAt == nil
			}
		}

		// Calculate size and segment count
		info.SizeBytes, info.SegmentCount = m.calculateDirStats(dirPath)

		sessions = append(sessions, info)
	}

	return sessions
}

// calculateDirStats returns the total size and segment count for a directory.
func (m *CleanupManager) calculateDirStats(dirPath string) (int64, int) {
	var totalSize int64
	var segmentCount int

	filepath.Walk(dirPath, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		totalSize += info.Size()
		if strings.HasSuffix(info.Name(), ".m4s") || strings.HasSuffix(info.Name(), ".ts") {
			segmentCount++
		}
		return nil
	})

	return totalSize, segmentCount
}

// TotalDiskUsage returns the total disk usage of all transcode sessions.
func (m *CleanupManager) TotalDiskUsage() int64 {
	var total int64
	for _, session := range m.ListSessions() {
		total += session.SizeBytes
	}
	return total
}
