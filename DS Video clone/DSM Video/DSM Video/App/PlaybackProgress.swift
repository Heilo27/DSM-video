import Foundation

/// Shared playback-progress thresholds. Previously the "fully watched" cutoff was
/// hardcoded as the literal 0.95 in a dozen places across the views; unifying it
/// here (A32) keeps the watched badge, resume logic, and progress rings in agreement.
enum PlaybackProgress {
    /// Fraction of duration at/above which an item is treated as fully watched.
    static let watchedThreshold: Double = 0.95

    /// Seconds remaining at/below which an item is treated as finished regardless of
    /// percentage. Percentage alone strands long films: 95% of a 3h feature is still
    /// 9 minutes out, so stopping during a long credit roll would resume at the credits
    /// and force a manual skip to the end. This absolute cap catches those endings.
    /// Jellyfin hit the same wall and switched audiobooks to a minutes-remaining rule
    /// (MaxAudiobookResume) for exactly this reason.
    static let finishedRemainingSeconds: Int = 90

    /// Whether a saved position should be treated as "finished" — i.e. playback should
    /// start from the beginning rather than resuming.
    ///
    /// Finished when EITHER condition holds:
    ///   - watched past `watchedThreshold`, or
    ///   - fewer than `finishedRemainingSeconds` remain.
    ///
    /// The two rules complement each other across runtimes: the percentage covers short
    /// content, the time cap covers long content where 95% is still many minutes from
    /// the end.
    static func isFinished(positionSeconds: Int, durationSeconds: Int) -> Bool {
        // Unknown/zero duration: no ratio is meaningful, so never suppress the resume.
        // Better to resume at a stale position than to silently restart a partly-watched item.
        guard durationSeconds > 0, positionSeconds > 0 else { return false }
        if Double(positionSeconds) / Double(durationSeconds) > watchedThreshold { return true }
        return (durationSeconds - positionSeconds) < finishedRemainingSeconds
    }

    /// The position playback should actually start from: the saved position, or 0 once the
    /// item counts as finished. Use at every resume site so server-supplied, downloaded, and
    /// locally-stored positions all obey the same rule.
    static func resumable(positionSeconds: Int, durationSeconds: Int) -> Int {
        isFinished(positionSeconds: positionSeconds, durationSeconds: durationSeconds) ? 0 : positionSeconds
    }
}
