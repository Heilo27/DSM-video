import TVServices
import os.log

// MARK: - Shared model (local copy for the extension process)
// Keep in sync with TopShelfItem.swift in the main app target.

private struct TopShelfItem: Codable {
    let id: String
    let title: String
    let year: Int?
    let imageURL: String?
    let deepLinkURL: String
    /// 0...1, or nil when unwatched. Optional so a snapshot written by an older build
    /// still decodes — a schema mismatch here blanks the entire shelf.
    var playbackProgress: Double?
}

/// The snapshot file, including which rail the app chose to write.
///
/// The heading has to come from the app, not be guessed here. The app writes Continue
/// Watching, or falls back to Just Added when nothing is in progress — so a constant label
/// in this file would be wrong half the time, and inferring it from "do the items have
/// progress?" would be a second rule to keep in sync with the first.
private struct TopShelfSnapshot: Codable {
    let sectionTitle: String
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

    /// Reads the snapshot, accepting BOTH the current object form and the legacy bare array.
    ///
    /// The file gained a wrapper when the shelf switched from Just Added to Continue
    /// Watching, because the heading now comes from the app. An installed build's existing
    /// topshelf.json is still the old array, and the app only rewrites it after a home load
    /// — so decoding strictly would blank the shelf for everyone until they opened the app,
    /// which is precisely the symptom this change is meant to fix.
    private func loadSnapshot() -> TopShelfSnapshot {
        let empty = TopShelfSnapshot(sectionTitle: "", items: [])
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

        let decoder = JSONDecoder()
        if let snapshot = try? decoder.decode(TopShelfSnapshot.self, from: data) {
            log.notice("decoded \(snapshot.items.count) item(s), section \(snapshot.sectionTitle, privacy: .public)")
            return snapshot
        }
        if let legacy = try? decoder.decode([TopShelfItem].self, from: data) {
            log.notice("decoded \(legacy.count) item(s) in the LEGACY array format")
            return TopShelfSnapshot(sectionTitle: "Just Added", items: legacy)
        }
        log.error("topshelf.json is \(data.count) bytes but decodes as neither format — schema drift between the app and this extension")
        return empty
    }
}
