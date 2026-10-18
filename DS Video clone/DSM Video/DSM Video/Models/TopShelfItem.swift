import Foundation

/// Lightweight snapshot written by the main app and read by the Top Shelf extension.
/// Stored as JSON in the shared App Group container (topshelf.json).
///
/// The extension compiles its OWN copy of these structs (TopShelfExtension/TopShelfProvider.swift
/// is the only source file in the "DSM Video Top Shelf" target), so the JSON shape is the whole
/// contract between the two processes. Change one copy, change the other.
struct TopShelfItem: Codable, Sendable {
    let id: String
    let title: String
    let year: Int?
    let imageURL: String?   // tokenless image URL (TASK-774: never persist the session token here)
    let deepLinkURL: String // dsvideo://item/{id}

    /// How far through the item the viewer is, 0...1, or nil when unwatched.
    ///
    /// The whole point of a Continue Watching shelf is showing where you left off, and
    /// tvOS draws that bar itself from TVTopShelfSectionedItem.playbackProgress — but only
    /// if it is given a value. Optional rather than defaulting to 0 so an unwatched item
    /// renders with no bar instead of an empty one suggesting "just started".
    ///
    /// Always nil on a restricted account: a resume bar is a profile's watch history (FR-264).
    var playbackProgress: Double?

    /// The server's age level for the title (FR-241), nil when unknown. Carried so the
    /// extension can re-check every item against the snapshot's ceiling; nil counts as the
    /// ceiling's `unratedLevel`.
    var ageLevel: Int?
}

/// Which rail the app wrote. The extension refuses a Continue Watching snapshot stamped with
/// a restricted ceiling, so it has to be told which one it is reading.
enum TopShelfRail: String, Codable, Sendable {
    case continueWatching
    case justAdded

    var sectionTitle: String {
        switch self {
        case .continueWatching: "Continue Watching"
        case .justAdded: "Just Added"
        }
    }
}

/// The ceiling the snapshot was filtered at, with everything the extension needs to re-check
/// it. `maxAgeLevel < unrestrictedLevel` = the account has a restricted profile and the shelf
/// is the shared-TV shelf (TopShelfPolicy). `unratedLevel` is what a title with no level counts
/// as under that ceiling (ProfileScope.allows). Two separate server values, never derived from
/// each other. All three keys are required.
struct TopShelfCeiling: Codable, Equatable, Sendable {
    let maxAgeLevel: Int
    let unrestrictedLevel: Int
    let unratedLevel: Int

    var isRestricted: Bool { maxAgeLevel < unrestrictedLevel }
}

/// The file the app writes and the Top Shelf extension reads.
///
/// Carries the heading because the APP decides which rail it wrote — Continue Watching, or
/// Just Added when nothing is in progress (or the account has a restricted profile).
///
/// `rail` and `ceiling` are REQUIRED keys: a snapshot written by an older build (the bare
/// array, or the object without them) does not decode, and the extension shows nothing until
/// the app writes a stamped one. Those files carry no age levels, so they cannot be checked
/// and could advertise an adult's titles to a kid at the shared TV's home screen.
struct TopShelfSnapshot: Codable, Sendable {
    let sectionTitle: String
    let rail: TopShelfRail
    let ceiling: TopShelfCeiling
    let items: [TopShelfItem]
}

// MARK: - Policy (FR-264, TASK-923)

/// What the tvOS Top Shelf may show. The ONE home of the rule; AppState.writeTopShelfSnapshot
/// calls it and writes exactly what it returns.
///
/// The Top Shelf is the shared TV's home screen and has no chosen viewer. On an account with
/// any restricted profile it shows only Just Added titles the MOST restricted profile may see,
/// with no resume bars, and never Continue Watching: nothing from any profile's watch history.
/// It does not depend on the active profile, so it holds while the picker is pending and after
/// an adult session. An account with no restricted profile keeps the original behavior:
/// Continue Watching, falling back to Just Added.
enum TopShelfPolicy {
    static let maxItems = 10

    struct Content: Sendable {
        let rail: TopShelfRail
        let ceiling: TopShelfCeiling
        let items: [ItemSummary]
    }

    /// - Parameters:
    ///   - profiles: the account's profile list (ActiveProfileStore.cachedProfiles); empty on a
    ///     server that predates profiles, which has no restricted viewer.
    ///   - unrestrictedLevel: the ladder's top (ActiveProfileStore.unrestrictedLevel). Decides
    ///     only whether the account has a restricted profile.
    ///   - unratedLevel: the level of a title with no level (ActiveProfileStore.unratedLevel).
    ///     Used only to filter titles.
    /// - Returns: nil when there is nothing the shelf may show (the writer then deletes the file).
    static func content(continueWatching: [ItemSummary], justAdded: [ItemSummary],
                        profiles: [Profile], unrestrictedLevel: Int,
                        unratedLevel: Int) -> Content? {
        let ceilingLevel = min(profiles.map(\.maxAgeLevel).min() ?? unrestrictedLevel,
                               unrestrictedLevel)
        let ceiling = TopShelfCeiling(maxAgeLevel: ceilingLevel,
                                      unrestrictedLevel: unrestrictedLevel,
                                      unratedLevel: unratedLevel)

        // Restricted account = some profile is below the ladder's top (FRD-002 §1). Not "the
        // lowest profile cannot see an unrated title": that is the unrated level's question.
        if ceiling.isRestricted {
            // The visibility rule is ProfileScope.allows (FR-242), never a comparison written
            // here. The id is not a server profile: this scope exists only to carry the ceiling.
            let scope = ProfileScope(id: "top-shelf-ceiling", maxAgeLevel: ceilingLevel,
                                     unratedLevel: unratedLevel)
            let allowed = justAdded.filter { scope.allows(ageLevel: $0.ageLevel) }
            guard !allowed.isEmpty else { return nil }
            return Content(rail: .justAdded, ceiling: ceiling,
                           items: Array(allowed.prefix(maxItems)))
        }

        let rail: TopShelfRail = continueWatching.isEmpty ? .justAdded : .continueWatching
        let source = rail == .continueWatching ? continueWatching : justAdded
        guard !source.isEmpty else { return nil }
        return Content(rail: rail, ceiling: ceiling, items: Array(source.prefix(maxItems)))
    }

    /// The resume bar for an item, 0...1, or nil. Always nil under a restricted ceiling.
    /// The division, its clamp and the zero-duration guard (NaN, which tvOS cannot draw) live in
    /// `PlaybackProgress.fraction`; this adds only the ceiling rule.
    static func playbackProgress(for item: ItemSummary, ceiling: TopShelfCeiling) -> Double? {
        guard !ceiling.isRestricted, let p = item.progress else { return nil }
        return PlaybackProgress.fraction(positionSeconds: p.positionSeconds, durationSeconds: p.durationSeconds)
    }
}
