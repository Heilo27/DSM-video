import Foundation

/// Shared playback-progress thresholds. Previously the "fully watched" cutoff was
/// hardcoded as the literal 0.95 in a dozen places across the views; unifying it
/// here (A32) keeps the watched badge, resume logic, and progress rings in agreement.
enum PlaybackProgress {
    /// Fraction of duration at/above which an item is treated as fully watched.
    static let watchedThreshold: Double = 0.95
}
