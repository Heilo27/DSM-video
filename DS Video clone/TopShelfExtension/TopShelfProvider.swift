import TVServices
import os.log

// MARK: - Shared model (local copy for the extension process)
// Mirror of DSM Video/Models/TopShelfItem.swift. This file is the ONLY source in the
// "DSM Video Top Shelf" target, so the app's types cannot be imported here: the JSON shape is
// the contract. Change one copy, change the other.

private struct TopShelfItem: Codable {
    let id: String
    let title: String
    let year: Int?
    let imageURL: String?
    let deepLinkURL: String
    /// 0...1, or nil when unwatched.
    var playbackProgress: Double?
    /// The server's age level (FR-241); nil = unknown, which counts as `ceiling.unratedLevel`.
    var ageLevel: Int?
}

private enum TopShelfRail: String, Codable {
    case continueWatching
    case justAdded
}

/// The ceiling the app filtered the snapshot at. Restricted = the account has a restricted
/// profile, so the shelf is the shared TV's home screen with no chosen viewer (FR-264).
private struct TopShelfCeiling: Codable {
    let maxAgeLevel: Int
    let unrestrictedLevel: Int
    /// What a title with no level counts as. A separate server value from unrestrictedLevel.
    let unratedLevel: Int
    var isRestricted: Bool { maxAgeLevel < unrestrictedLevel }

    /// Mirrors ProfileScope.allows(ageLevel:) (FR-242). Copied, not shared, because this
    /// target compiles only this file and cannot compile ProfileModels.swift. Change both.
    func allows(ageLevel: Int?) -> Bool { (ageLevel ?? unratedLevel) <= maxAgeLevel }
}

/// The snapshot file, including which rail the app chose to write and the ceiling it applied.
///
/// The heading comes from the app, not guessed here. `rail` and `ceiling` are REQUIRED: a
/// file from an older build (the legacy bare array, or the object without them) does not
/// decode and the shelf shows nothing until the app writes a stamped one. Those files carry no
/// age levels, so nothing here could check them before putting them on a shared TV.
private struct TopShelfSnapshot: Codable {
    let sectionTitle: String
    let rail: TopShelfRail
    let ceiling: TopShelfCeiling
    let items: [TopShelfItem]
}

/// The App Group shared with the parent app. File scope, not a property: os.log string
/// interpolation is a closure, so referencing an instance property inside a log line would
/// require explicit `self` under Swift 6 strict concurrency.
private let appGroupID = "group.HeiloProjects.DSReel"

// MARK: - Provider

@objc(TopShelfProvider)
class TopShelfProvider: TVTopShelfContentProvider {

    /// The extension had NO logging, and every failure path returned empty silently — a
    /// missing container, an unreadable file and undecodable JSON all looked identical to
    /// "no content". That is why the bare-icon bug survived four wrong theories across two
    /// sessions: there was no way to ask the device what it actually saw.
    ///
    /// Read it with: xcrun simctl spawn <udid> log stream --predicate \
    ///   'subsystem == "com.dsm.dsvideo.topshelf"'
    /// or on a paired Apple TV, Console.app filtered to the same subsystem.
    private let log = Logger(subsystem: "com.dsm.dsvideo.topshelf", category: "provider")

    // The COMPLETION-HANDLER overload, not the async one.
    //
    // TVTopShelfContent is not Sendable, and every isolation an async override can carry
    // — inferred @concurrent, @MainActor, or explicit nonisolated — puts an isolation
    // boundary between the value and its caller, which Swift 6 rejects. The completion
    // handler crosses no boundary: the system hands us a callback and we invoke it
    // synchronously with a value we just built. Same work, no concurrency involved.
    override func loadTopShelfContent(completionHandler: @escaping (((any TVTopShelfContent)?) -> Void)) {
        let snapshot = loadSnapshot()
        guard !snapshot.items.isEmpty else {
            // nil is "no content", which tvOS draws as the bare app icon — the SAME thing a
            // broken shelf looks like. The log line is the only way to tell them apart.
            log.notice("no items to show — returning nil (tvOS will render the app icon alone)")
            completionHandler(nil)
            return
        }

        let shelfItems: [TVTopShelfSectionedItem] = snapshot.items.compactMap { entry in
            guard let deepLink = URL(string: entry.deepLinkURL) else { return nil }
            let item = TVTopShelfSectionedItem(identifier: entry.id)
            item.title = entry.title
            // The app persists a 16:9 BACKDROP (falling back to the poster). imageShape
            // defaults to .square, so leaving it unset made tvOS lay out a square slot for
            // a widescreen image.
            item.imageShape = .hdtv
            item.playAction = TVTopShelfAction(url: deepLink)
            item.displayAction = TVTopShelfAction(url: deepLink)
            // The resume bar. tvOS draws it from this value; without it a Continue Watching
            // shelf looks identical to a list of things you have never opened.
            if let progress = entry.playbackProgress {
                item.playbackProgress = min(1, max(0, progress))
            }
            if let imageString = entry.imageURL, let imageURL = URL(string: imageString) {
                item.setImageURL(imageURL, for: .screenScale1x)
                item.setImageURL(imageURL, for: .screenScale2x)
            }
            return item
        }

        let withoutImages = snapshot.items.filter { ($0.imageURL ?? "").isEmpty }.count
        if withoutImages > 0 {
            // An item with no image renders as nothing, so a shelf of them looks empty.
            log.error("\(withoutImages) of \(snapshot.items.count) item(s) have NO imageURL — those cards will render blank")
        }
        log.notice("presenting \(shelfItems.count) item(s)")

        let section = TVTopShelfItemCollection(items: shelfItems)
        section.title = snapshot.sectionTitle
        completionHandler(TVTopShelfSectionedContent(sections: [section]))
    }

    // MARK: - Private

    /// Reads the snapshot and re-checks it against the ceiling it is stamped with.
    ///
    /// The app already filtered it (TopShelfPolicy); this is the second check, so a file that
    /// is stale, hand-edited or written by a buggy build still cannot put a title above the
    /// ceiling, or any watch history, on a shared TV's home screen. Anything unreadable or
    /// unstamped is shown as nothing: an empty shelf is safe, a wrong one is not.
    private func loadSnapshot() -> (sectionTitle: String, items: [TopShelfItem]) {
        let empty = (sectionTitle: "", items: [TopShelfItem]())
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            log.error("no container for app group \(appGroupID, privacy: .public) — check the App Groups entitlement on BOTH the app and this extension")
            return empty
        }

        let fileURL = container.appendingPathComponent("topshelf.json")
        guard let data = try? Data(contentsOf: fileURL) else {
            log.notice("no topshelf.json at \(fileURL.path, privacy: .public) — the app has not written one yet (it writes on home load)")
            return empty
        }

        guard let snapshot = try? JSONDecoder().decode(TopShelfSnapshot.self, from: data) else {
            // Includes every file written before the ceiling stamp existed (legacy bare array,
            // unstamped object). Ignored on purpose: it cannot be checked.
            log.error("topshelf.json is \(data.count) bytes but is not a stamped snapshot (older build, or schema drift) — showing nothing until the app rewrites it")
            return empty
        }
        log.notice("decoded \(snapshot.items.count) item(s), section \(snapshot.sectionTitle, privacy: .public), ceiling \(snapshot.ceiling.maxAgeLevel)/\(snapshot.ceiling.unrestrictedLevel), unrated \(snapshot.ceiling.unratedLevel)")

        guard snapshot.ceiling.isRestricted else {
            return (snapshot.sectionTitle, snapshot.items)
        }
        // Restricted account: Just Added only, no resume bars, every title the ceiling allows
        // (TopShelfCeiling.allows, the mirror of ProfileScope.allows).
        guard snapshot.rail == .justAdded else {
            log.error("restricted snapshot carries \(snapshot.rail.rawValue, privacy: .public) — watch history is never shown on a restricted account; showing nothing")
            return empty
        }
        let allowed: [TopShelfItem] = snapshot.items.compactMap { entry in
            guard snapshot.ceiling.allows(ageLevel: entry.ageLevel) else { return nil }
            var shown = entry
            shown.playbackProgress = nil
            return shown
        }
        if allowed.count != snapshot.items.count {
            log.error("dropped \(snapshot.items.count - allowed.count) item(s) above the ceiling")
        }
        return (snapshot.sectionTitle, allowed)
    }
}
