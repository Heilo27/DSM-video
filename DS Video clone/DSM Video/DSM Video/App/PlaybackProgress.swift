import Foundation

/// Shared playback-progress thresholds. Previously the "fully watched" cutoff was
/// hardcoded as the literal 0.95 in a dozen places across the views; unifying it
/// here (A32) keeps the watched badge, resume logic, and progress rings in agreement.
/// `nonisolated` in its entirety: these are immutable `let` constants and pure functions over
/// their arguments — no shared mutable state, so they are safe to read from any actor.
///
/// Without this the enum inherited the project's default @MainActor isolation, and every
/// read from a non-MainActor context was an isolation violation. That included
/// LocalStore (an actor) interpolating these constants into the rail SQL, and
/// AppState.computeHomeRails calling isFinished. Those surfaced only as WARNINGS in local
/// Debug builds but as ERRORS in the Release archive, so Xcode Cloud build 7 failed on
/// Archive - tvOS while every local build passed.
nonisolated enum PlaybackProgress {
    /// Fraction of duration at/above which an item is treated as fully watched.
    static let watchedThreshold: Double = 0.95

    /// Fraction of duration above which an item counts as genuinely "started" and so belongs
    /// in Continue Watching rather than Just Added.
    ///
    /// TASK-849: this was 0.05 in the rail SQL and AppState.computeHomeRails but still 0.02 in
    /// TVShowDetailView's resume scan, so for a 45-minute episode watched between 54s and 135s
    /// the show page offered to resume an episode the home rail said had never been started.
    /// 5% is the canonical value — it filters out the accidental tap / trailer-length sample
    /// that 2% lets through. Every threshold check should reference this, not a literal.
    ///
    /// The poster-card bar no longer has a cutoff of its own (TASK-978): see `cardIndicator`.
    static let startedThreshold: Double = 0.05

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

    /// How an episode counts when scanning a show for its resume point.
    enum WatchState {
        /// No progress recorded, or below the "genuinely started" threshold.
        case unwatched
        /// Started and not yet finished — this episode resumes ITSELF.
        case inProgress
        /// Past the watched threshold; the viewer has moved on.
        case watched
    }

    /// Classifies one episode's progress.
    ///
    /// The fraction math and both threshold comparisons were written out by hand in the iOS
    /// and tvOS resume scans — the same three lines, twice. That duplication is precisely
    /// how the 0.05-vs-0.02 mismatch documented on startedThreshold above happened: one copy
    /// was updated and the other was not, so the show page offered to resume an episode the
    /// home rail said had never been started. Single definition, so it cannot drift again.
    ///
    /// TASK-962: "watched" is `isFinished` and nothing else. This used to test the fraction
    /// alone (`>= 0.95`), so a 22-minute episode stopped at 1240s (93.9%, 80s left) was
    /// `.inProgress` here while `isFinished`, the rail SQL and playback all called it finished:
    /// the show page offered Resume on an episode that restarted from 0 and that the rail had
    /// already dropped, instead of advancing to the next one. It also disagreed at exactly
    /// 95.000%, which `isFinished` (strictly greater) does not treat as finished.
    static func watchState(positionSeconds: Int, durationSeconds: Int) -> WatchState {
        guard durationSeconds > 0 else { return .unwatched }
        if isFinished(positionSeconds: positionSeconds, durationSeconds: durationSeconds) {
            return .watched
        }
        let frac = Double(positionSeconds) / Double(durationSeconds)
        // INCLUSIVE at startedThreshold, matching the rail SQL in LocalStore
        // (`ratio >= startedThreshold`). The show-page scans used a strict `>` while the
        // rail used `>=`, so an item sitting at exactly 5.000% appeared in one place and
        // not the other — a one-item disagreement nobody would ever reproduce on purpose,
        // and precisely the kind of thing two copies of a rule drift into. The rail is the
        // authority for "is this in Continue Watching", so its boundary wins.
        if frac >= startedThreshold { return .inProgress }
        return .unwatched
    }

    /// Where the Play / Resume button on a show page should land, over every scanned episode
    /// in watch order (seasons concatenated). Pure, so the iOS and tvOS show pages share one
    /// walk instead of keeping two copies, and so it can be tested without a view.
    ///
    /// - The latest `.inProgress` episode wins and resumes itself (`isResume == true`).
    /// - Otherwise the first episode with no progress record AFTER the last watched or
    ///   in-progress one (`isResume == false`): a finished episode advances the show to the
    ///   next one.
    /// - `nil` when neither exists (everything watched, or nothing to scan); the caller
    ///   falls back to the first episode.
    ///
    /// An episode with progress below `startedThreshold` was never genuinely started (FRD-001
    /// FR-016 "started from 5%"), so it is `.unwatched` like an episode with no record: it can be
    /// the first-unwatched pick, and it does not advance past an earlier unwatched one. Before
    /// TASK-1017 such an episode was skipped by the walk entirely, so a show whose next episode
    /// had been sampled for a few seconds offered the episode AFTER it, or nothing.
    struct ShowResumePick: Equatable {
        let index: Int
        let isResume: Bool
    }

    static func showResumePick(progress: [ItemProgress?]) -> ShowResumePick? {
        var inProgress: Int?
        var firstUnwatched: Int?
        for (i, prog) in progress.enumerated() {
            if let prog, prog.durationSeconds > 0 {
                switch watchState(positionSeconds: prog.positionSeconds,
                                  durationSeconds: prog.durationSeconds) {
                case .inProgress:
                    inProgress = i
                    firstUnwatched = nil
                case .watched:
                    firstUnwatched = nil
                case .unwatched:
                    if firstUnwatched == nil { firstUnwatched = i }
                }
            } else if firstUnwatched == nil {
                firstUnwatched = i
            }
        }
        if let inProgress { return ShowResumePick(index: inProgress, isResume: true) }
        if let firstUnwatched { return ShowResumePick(index: firstUnwatched, isResume: false) }
        return nil
    }

    /// What a poster card draws for an item's progress (FRD-001 FR-020, TASK-978).
    enum CardIndicator: Equatable {
        /// Nothing: no progress, or a position of zero.
        case none
        /// A progress bar whose width is `fraction` of the card, strictly between 0 and 1.
        case bar(fraction: Double)
        /// The watched badge, and no bar.
        case watchedBadge
    }

    /// The one decision behind every poster card's bar and badge (iOS grid and rails, tvOS portrait
    /// and landscape cards).
    ///
    /// TASK-978: each card made its own call. tvOS drew the bar for any `frac < 1.0`, so a record at
    /// position 0 drew an empty track, and a title at 96% (finished) drew a bar beside the badge,
    /// because the bar test stopped at 1.0 and the badge test started at 0.95. iOS had a third pair of
    /// literals (0.02 and 0.98). Now there is one answer, and it is `isFinished`, the same rule the
    /// rails and playback use: a finished title shows the badge and no bar; an unfinished one with a
    /// position above zero shows a bar of exactly its fraction; zero shows nothing.
    static func cardIndicator(positionSeconds: Int, durationSeconds: Int) -> CardIndicator {
        guard durationSeconds > 0, positionSeconds > 0 else { return .none }
        if isFinished(positionSeconds: positionSeconds, durationSeconds: durationSeconds) {
            return .watchedBadge
        }
        return .bar(fraction: Double(positionSeconds) / Double(durationSeconds))
    }

    /// Convenience over an item's optional progress record.
    static func cardIndicator(for progress: ItemProgress?) -> CardIndicator {
        guard let progress else { return .none }
        return cardIndicator(positionSeconds: progress.positionSeconds, durationSeconds: progress.durationSeconds)
    }

    /// The position playback should actually start from: the saved position, or 0 once the
    /// item counts as finished. Use at every resume site so server-supplied, downloaded, and
    /// locally-stored positions all obey the same rule.
    static func resumable(positionSeconds: Int, durationSeconds: Int) -> Int {
        isFinished(positionSeconds: positionSeconds, durationSeconds: durationSeconds) ? 0 : positionSeconds
    }
}
