import Foundation
import Observation
import os.log
#if canImport(UIKit)
import UIKit
#endif

extension Notification.Name {
  /// A downloaded file is about to be removed from disk.
  ///
  /// Posted SYNCHRONOUSLY and BEFORE the file is unlinked, so a player currently reading
  /// that asset can tear down first. AVPlayer holds the file open; deleting it underneath
  /// presents as a stall or an unhelpful decode error rather than as "this was removed"
  /// (TASK-903).
  ///
  /// userInfo: `itemId` (String). A nil itemId means EVERY download is going (clearAll on
  /// sign-out) — a listener with any downloaded asset loaded should treat that as its own.
  ///
  /// This direction is deliberate: DownloadManager does not know which view is playing
  /// what, and should not. The player knows its own itemID and decides for itself.
  static let downloadWillBeDeleted = Notification.Name("dsm.downloadWillBeDeleted")
}

/// One title on this device. Downloads belong to the ACCOUNT (FRD-002): every profile shares
/// the same files and nothing is deleted when a profile is switched or removed. What a profile
/// may SEE of them (FR-262) and where each profile is in them (FR-233) are per profile.
struct DownloadedItem: Identifiable, Codable {
  let id: String
  let title: String
  let year: Int?
  /// `var` so the read path can resolve it in place; a rebuilt copy would have to list every
  /// field, and one it forgot (an age level, a profile's position) would silently drop.
  var videoPath: String
  var posterPath: String?
  let fileSize: Int64
  let downloadedAt: Date
  /// The single per-device position recorded before profiles existed: the legacy scope's
  /// bucket (`ProfileScope.legacy`, id ""), and the OWNER's position until the owner records
  /// one of their own (FR-233). Never erased, so the migration cannot lose it. Profiles read
  /// and write through `resumePosition(forProfileID:ownerID:)` / `setResumePosition`.
  var resumePositionSeconds: Int
  var durationSeconds: Int
  /// The title's server-sent age level (FR-241), captured at download time and kept current
  /// from the local catalog (`DownloadManager.refreshAgeLevels`). nil is UNKNOWN: a download
  /// made before FR-262, or one the catalog had no level for. `ProfileScope.allows` reads nil
  /// as unrated, so an unknown title is hidden on every restricted profile (fail closed).
  var ageLevel: Int?
  /// Offline resume position per profile id (FR-233). The legacy bucket is not in here; it is
  /// `resumePositionSeconds`, which keeps the manifest readable by older builds.
  var resumePositionsByProfile: [String: Int]

  // Explicit memberwise init — callers can omit resumePositionSeconds and durationSeconds (both default to 0).
  init(
    id: String,
    title: String,
    year: Int?,
    videoPath: String,
    posterPath: String?,
    fileSize: Int64,
    downloadedAt: Date,
    resumePositionSeconds: Int = 0,
    durationSeconds: Int = 0,
    ageLevel: Int? = nil,
    resumePositionsByProfile: [String: Int] = [:]
  ) {
    self.id = id
    self.title = title
    self.year = year
    self.videoPath = videoPath
    self.posterPath = posterPath
    self.fileSize = fileSize
    self.downloadedAt = downloadedAt
    self.resumePositionSeconds = resumePositionSeconds
    self.durationSeconds = durationSeconds
    self.ageLevel = ageLevel
    self.resumePositionsByProfile = resumePositionsByProfile
  }

  // Custom Decodable init for migration: existing persisted JSON may lack newer fields;
  // fall back to 0 if any key is absent rather than throwing keyNotFound. A missing
  // ageLevel decodes as nil (unknown, fail closed), never as a default level.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    title = try c.decode(String.self, forKey: .title)
    year = try c.decodeIfPresent(Int.self, forKey: .year)
    videoPath = try c.decode(String.self, forKey: .videoPath)
    posterPath = try c.decodeIfPresent(String.self, forKey: .posterPath)
    fileSize = try c.decode(Int64.self, forKey: .fileSize)
    downloadedAt = try c.decode(Date.self, forKey: .downloadedAt)
    resumePositionSeconds = (try c.decodeIfPresent(Int.self, forKey: .resumePositionSeconds)) ?? 0
    durationSeconds = (try c.decodeIfPresent(Int.self, forKey: .durationSeconds)) ?? 0
    ageLevel = try c.decodeIfPresent(Int.self, forKey: .ageLevel)
    resumePositionsByProfile = (try c.decodeIfPresent([String: Int].self, forKey: .resumePositionsByProfile)) ?? [:]
  }

  /// Where `profileID` is in this title offline (FR-233). The legacy scope ("") reads the
  /// pre-profiles value; the owner reads it too until they have a position of their own,
  /// which is how that value migrates to the owner without being lost. Any other profile
  /// starts at 0: it never inherits someone else's place.
  func resumePosition(forProfileID profileID: String, ownerID: String?) -> Int {
    if profileID.isEmpty { return resumePositionSeconds }
    if let own = resumePositionsByProfile[profileID] { return own }
    return profileID == ownerID ? resumePositionSeconds : 0
  }

  /// Records `profileID`'s position, touching no other profile's.
  mutating func setResumePosition(_ seconds: Int, forProfileID profileID: String) {
    if profileID.isEmpty {
      resumePositionSeconds = seconds
    } else {
      resumePositionsByProfile[profileID] = seconds
    }
  }
}

struct ActiveDownload: Identifiable {
  let id: String
  let title: String
  let progress: Double
  let task: URLSessionDownloadTask
}

/// Bytes received so far and the total the server announced (<= 0 when unknown).
struct TransferBytes: Equatable, Sendable {
  var written: Int64
  var expected: Int64
}

/// FR-030: an in-flight row is Queued (accepted, nothing transferring yet), Downloading
/// (percent and size) or Paused. A pure mapping so the three can never render alike.
enum DownloadRowState: Equatable, Sendable {
  case queued
  case downloading(percent: Int, bytes: TransferBytes)
  case paused(percent: Int)

  static func make(isActive: Bool, isPaused: Bool, progress: Double, bytes: TransferBytes?) -> DownloadRowState {
    let percent = Int((min(1, max(0, progress)) * 100).rounded(.down))
    if isPaused && !isActive { return .paused(percent: percent) }
    guard let bytes, bytes.written > 0 else { return .queued }
    return .downloading(percent: percent, bytes: bytes)
  }

  /// The row's status line: percent plus bytes (or total size), "Queued", or the paused percent.
  var detail: String {
    switch self {
    case .queued:
      return "Queued"
    case .paused(let percent):
      return "\(percent)%"
    case .downloading(let percent, let bytes):
      let size = ByteCountFormatter()
      size.countStyle = .file
      if bytes.expected > 0 {
        return "\(percent)% \u{00B7} \(size.string(fromByteCount: bytes.written)) of \(size.string(fromByteCount: bytes.expected))"
      }
      return size.string(fromByteCount: bytes.written)
    }
  }

  var isQueued: Bool { self == .queued }
  var isPaused: Bool { if case .paused = self { return true } else { return false } }
}

/// The three states the downloads manifest can be in, kept distinct on purpose.
///
/// `absent` and `unreadable` used to collapse into the same `[]`, which is how a corrupt file
/// became a destroyed library: the empty result was written back over the real data.
enum ManifestState {
  /// No manifest file yet — a fresh install, or nothing has ever been downloaded. `[]` is correct.
  case absent
  /// The manifest decoded. This is the only state whose contents can be trusted.
  case items([DownloadedItem])
  /// The file EXISTS and could not be read. Never treat this as "no downloads".
  case unreadable(reason: String)
}

/// TASK-782: surfaces a genuine (non-pause) download failure to the UI so the row
/// shows "Download failed" + a retry/dismiss affordance instead of silently vanishing.
///
/// Persisted (TASK-994, FR-032): a failed row survives a relaunch until the user retries or
/// dismisses it. Every failure is retryable (a retry re-resolves a fresh session), so there is
/// no "permanent" kind. The token is a credential and is NOT written; a retry takes a live one.
struct FailedDownload: Identifiable, Codable {
  let id: String
  let title: String
  /// Enough context to re-issue the download without the caller re-resolving the URL.
  let videoURL: URL?
  let posterURL: URL?
  var token: String?
  let year: Int?
  let durationSeconds: Int
  /// FR-262: the level captured when the download started, carried so a retry keeps it.
  var ageLevel: Int? = nil
  let message: String

  private enum CodingKeys: String, CodingKey {
    case id, title, videoURL, posterURL, year, durationSeconds, ageLevel, message
  }
}

/// Work a background relaunch could not finish because the app's providers (token, session
/// release) are wired only when the scene appears (TASK-994). Written to disk so it survives
/// the process that deferred it, and run by `flushDeferredWork()` once the providers exist.
private struct DeferredWork: Codable {
  /// Playback sessions of downloads that finished while nothing could release them.
  var sessionReleases: [String] = []
  /// itemId → poster URL of downloads that finished while no token could fetch the poster.
  var posters: [String: URL] = [:]
  var isEmpty: Bool { sessionReleases.isEmpty && posters.isEmpty }
}

@MainActor
@Observable
final class DownloadManager: NSObject {
  static let shared = DownloadManager()

  private let log = Logger(subsystem: "com.dsm.dsvideo", category: "DownloadManager")

  private(set) var activeDownloads: [String: ActiveDownload] = [:]
  private(set) var downloadProgress: [String: Double] = [:]
  /// itemId → bytes received / expected, for the Downloads row's size text (FR-030). Set and
  /// cleared together with `downloadProgress`; zero received means queued, not transferring.
  private(set) var downloadBytes: [String: TransferBytes] = [:]
  /// In-memory map of itemId → resume data blob for paused downloads.
  private(set) var pausedDownloads: [String: Data] = [:]
  /// TASK-782: itemId → failure record for genuinely-failed downloads. Populated in the
  /// non-pause error branch and the moveItem-catch so the Downloads UI can show a
  /// "Download failed — retry" row rather than the row silently disappearing.
  private(set) var failedDownloads: [String: FailedDownload] = [:]

  /// Set when the manifest was found corrupt and had to be quarantined and rebuilt. Non-nil
  /// means the user has lost titles and watch positions even though their videos still play —
  /// which they must be told, rather than left to notice their library looks wrong.
  /// Cleared by `acknowledgeManifestRecovery()` once shown.
  private(set) var manifestUnavailableReason: String?

  /// Dismiss the manifest-recovery notice after the UI has surfaced it.
  func acknowledgeManifestRecovery() {
    manifestUnavailableReason = nil
  }

  /// What finishing (or restarting) a download needs to know about its title. One shape for
  /// the in-flight map, a failure's retry and a restart, so a field added to one cannot be
  /// forgotten by another.
  private typealias DownloadInfo = (title: String, year: Int?, posterURL: URL?, durationSeconds: Int, token: String?, videoURL: URL?, ageLevel: Int?)

  private var backgroundSession: URLSession
  /// This process's task → item map. Not the only record: every task also carries its item in
  /// `taskDescription`, which the system keeps across app terminations (see `owner(of:)`).
  private var downloadTasks: [URLSessionDownloadTask: String] = [:]
  private var pendingDownloadInfo: [String: DownloadInfo] = [:]
  private var lastProgressUpdate: [String: Date] = [:]

  /// Items whose current task was started from resume data (TASK-947). Resume data replays the
  /// stream URL of the session it was cut from; a 404 there means the server has since reaped
  /// that session, and the answer is a fresh session from byte 0, not a failure row.
  private var resumedFromData: Set<String> = []

  /// False from launch until the background session has reported the tasks a previous process
  /// left running (TASK-947). A Download tap in that window is held and re-run afterwards, so it
  /// cannot start a second transfer for an item whose first one is still going.
  private var survivingTasksAdopted = true
  private var startsAwaitingAdoption: [() -> Void] = []

  /// Items `pauseDownload` is stopping. Their delegate stop callback is ignored: the pause holds
  /// the resume data from `cancel(byProducingResumeData:)` and records the stop itself, and the
  /// callback can land first without that data, which would turn a good pause into a Failed row.
  private var pausing: Set<String> = []

  /// Tasks a pause stopped with nothing to resume, by `taskIdentifier` -> item (TASK-994). The
  /// stop raised a Failed row and released the item's state, but a transfer that had in fact
  /// finished still delivers its file afterwards; this is how that late delivery finds its item
  /// and is kept instead of discarded. Cleared when the task's last callback arrives.
  private var stoppedByPauseWithoutData: [Int: String] = [:]

  /// Session releases and poster fetches a relaunch could not run yet; see `DeferredWork`.
  private var deferredWork = DeferredWork()

  private let storageKey = "dsReel.downloadedItems"
  private let resumeDataKey = "dsReel.resumeData"
  /// Persists minimal metadata for paused downloads across app launches.
  private let pausedMetaKey = "dsReel.pausedMeta"
  private var cachedDownloadedItems: [DownloadedItem]?

  // FIX-7: Called by AppDelegate.handleEventsForBackgroundURLSession. Must be invoked
  // in urlSessionDidFinishEvents(forBackgroundURLSession:) after all events are processed.
  var backgroundCompletionHandler: (() -> Void)?

  /// Supplies the CURRENT session token at resume time.
  ///
  /// Resume used to reuse the token captured when the download first started, but that
  /// token is deliberately NOT persisted (it is a credential, and the paused-meta file is
  /// plain JSON). After a relaunch the restored value was `nil` AND the `_sid` had been
  /// stripped from the saved URL — so both auth paths were dead and every resume 401'd,
  /// reported to the user as "check your connection". Set by the app at launch.
  var tokenProvider: (() -> String?)?

  /// Whether the current server connection is a QuickConnect relay needing the
  /// `Cookie: type=tunnel` header.
  ///
  /// Downloads were the ONLY auth path that omitted this — APIClient and all three
  /// AuthenticatedImage paths send it — so over a relay both the video download and its
  /// poster fetch were the only requests missing a header the server expects.
  var usesTunnelCookieProvider: (() -> Bool)?

  /// Releases a server playback session once a download has finished with it.
  ///
  /// A download's URL is `/api/v1/playback/{sessionID}/stream` — the session IS the URL, so
  /// the session must outlive the transfer. The caller used to release it immediately after
  /// reading the URL (on the false premise that "the download itself doesn't use it"), which
  /// made every subsequent GET 404. Ownership of the release now sits here, where the end of
  /// the transfer is actually known. Set by the app at launch.
  var releaseSessionProvider: ((String) -> Void)?

  /// Playback session backing each in-flight download, so it can be released on completion,
  /// failure, or cancellation — exactly once, whichever path ends the transfer.
  private var downloadSessionIDs: [String: String] = [:]

  /// Opens a NEW playback session for an item and returns its stream URL plus session id.
  ///
  /// Required because a download URL is session-scoped (`/playback/{id}/stream`): a stored
  /// URL is dead the moment its session ends, which it always has by the time a paused or
  /// failed download is restarted — after a relaunch, or after the transfer that released it.
  /// Restarting from the stored URL therefore 404s, so resume and retry re-resolve instead.
  /// Set by the app at launch.
  var urlResolver: ((String) async -> (url: URL, sessionID: String?)?)?

  /// Overrides the container that `downloadsDirectory()` and `downloadsMetadataFileURL`
  /// resolve against. `nil` means the real app container, which is what `shared` uses.
  ///
  /// TEST SEAM (R4 gap closure). `DownloadManager` is a `@MainActor` singleton whose
  /// bookkeeping lives at one fixed path (`<AppSupport>/downloads.json`) with its media in
  /// `<Documents>/Downloads`. Every test that deletes a download, writes a resume position,
  /// or purges on sign-out would otherwise contend for those two paths — order dependent,
  /// and destructive against a real device's library. Injecting a root directory gives each
  /// test its own container. Production is untouched: `shared` passes nothing and both path
  /// accessors fall back to exactly the URLs they computed before.
  private let containerOverride: URL?

  /// Which profile is watching, and its ceiling (FR-262, FR-233). `shared` reads the app's
  /// one store (`ActiveProfileStore.shared`); a test manager gets its own, so tests that set
  /// an active profile cannot race tests written against the pre-profiles legacy scope.
  private let profileStore: ActiveProfileStore

  /// Resolves a title's age level from the on-device catalog (nil = unknown). Used to keep
  /// stored levels current and to backfill downloads made before FR-262. Injected so tests
  /// do not read the app's shared database.
  private let ageLevelLookup: (String) async -> Int?

  override private init() {
    self.containerOverride = nil
    self.profileStore = .shared
    self.ageLevelLookup = { await LocalStore.shared.ageLevel(forItemID: $0) }
    // TASK-738: default downloads to Wi-Fi only unless the user opts into cellular.
    UserDefaults.standard.register(defaults: ["dsReel.downloadsWifiOnly": true])
    let config = URLSessionConfiguration.background(withIdentifier: "com.heiloprojects.dsreel.downloads")
    config.isDiscretionary = false
    config.sessionSendsLaunchEvents = true
    // Placeholder so the stored property is initialised before super.init(); it is
    // replaced below and never used to start a task. Deliberately NOT a second
    // background session with the same identifier — creating two live sessions that
    // share an identifier is undefined, and the OS could deliver relaunch events to the
    // delegate-less one, so downloads finishing while suspended never reported.
    backgroundSession = URLSession(configuration: .ephemeral)
    super.init()
    // The real background session, with self as delegate now that super.init() has run.
    // Serial queue: URLSession orders a task's callbacks only on a serial delegate queue, and
    // a default OperationQueue is concurrent.
    let delegateQueue = OperationQueue()
    delegateQueue.maxConcurrentOperationCount = 1
    backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    migrateLegacyResumeStore()
    restorePersistedDownloads()
    // Re-attach whatever a previous process left in the session (TASK-947). Until this
    // answers, a Download tap is held so it cannot duplicate a transfer still running.
    survivingTasksAdopted = false
    backgroundSession.getAllTasks { [weak self] tasks in
      Task { @MainActor in self?.adoptSurvivingTasks(tasks) }
    }
  }

  /// TEST SEAM (R4). A manager whose bookkeeping and media live under `container` instead of
  /// the app's own directories, so each test owns its state.
  ///
  /// Uses an EPHEMERAL session, not a second background session: two live background
  /// sessions sharing `com.heiloprojects.dsreel.downloads` is undefined behaviour (see the
  /// comment in `init()`), and this instance never starts a transfer — the tests exercise the
  /// bookkeeping and the response gate, both of which are independent of the session.
  ///
  /// `profileStore` defaults to a fresh, empty store (legacy scope, unrestricted), which is the
  /// world every pre-profiles download test was written against. `ageLevelLookup` defaults to
  /// "the catalog knows nothing".
  ///
  /// A relaunch is modelled as a second manager on the same container: it restores the
  /// unfinished downloads persisted there, exactly as `shared` does at launch. Pass
  /// `awaitingSurvivingTasks: true` to stand where `shared` stands before the session reports
  /// its carried-over tasks; the test then delivers them with `adoptSurvivingTasks(_:)`. The
  /// legacy UserDefaults migration is NOT run here: it would move the host app's real keys.
  init(
    containerForTesting container: URL,
    profileStore: ActiveProfileStore? = nil,
    ageLevelLookup: @escaping (String) async -> Int? = { _ in nil },
    awaitingSurvivingTasks: Bool = false
  ) {
    self.containerOverride = container
    // A UUID suite name is always valid, so the `.standard` fallback is unreachable in
    // practice; it exists only to avoid a force-unwrap.
    self.profileStore = profileStore
      ?? ActiveProfileStore(defaults: UserDefaults(suiteName: "DownloadManagerTests.\(UUID().uuidString)") ?? .standard)
    self.ageLevelLookup = ageLevelLookup
    backgroundSession = URLSession(configuration: .ephemeral)
    super.init()
    restorePersistedDownloads()
    survivingTasksAdopted = !awaitingSurvivingTasks
  }

  // MARK: - Public API

  /// The level a NEW download is stamped with (FR-262): the server's level from the item's
  /// detail response when it sent one, else the on-device catalog's, else nil (unknown, which
  /// every restricted profile treats as hidden). The server's answer wins because the catalog
  /// may not have synced the title yet, or may predate a re-rating. This is the ONE place the
  /// choice is made; callers pass the result to `startDownload(ageLevel:)`.
  func resolveAgeLevel(itemId: String, serverLevel: Int?) async -> Int? {
    if let serverLevel { return serverLevel }
    return await ageLevelLookup(itemId)
  }

  func startDownload(
    itemId: String,
    title: String,
    year: Int?,
    videoURL: URL,
    posterURL: URL?,
    token: String?,
    durationSeconds: Int = 0,
    ageLevel: Int? = nil,
    playbackSessionID: String? = nil
  ) {
    // Launch window (TASK-947): the session has not yet said which transfers survived the last
    // process. Starting now could duplicate one of them, so hold the tap and re-run it once
    // the answer is in; the guards below then see any re-attached task.
    guard survivingTasksAdopted else {
      startsAwaitingAdoption.append { [weak self] in
        self?.startDownload(
          itemId: itemId, title: title, year: year, videoURL: videoURL, posterURL: posterURL,
          token: token, durationSeconds: durationSeconds, ageLevel: ageLevel,
          playbackSessionID: playbackSessionID)
      }
      return
    }
    guard activeDownloads[itemId] == nil else {
      // Already downloading — the caller's freshly-opened session is redundant, so release
      // it now rather than leaving an ffmpeg transcode pinned until the idle reaper runs.
      // The tap attaches to the running task: its row and progress are the item's.
      if let playbackSessionID { releaseSessionProvider?(playbackSessionID) }
      return
    }
    guard !isDownloaded(itemId: itemId) else {
      if let playbackSessionID { releaseSessionProvider?(playbackSessionID) }
      return
    }
    // A partial is already on this device: continue it instead of starting over beside it
    // (TASK-947). The title page shows Download for a paused item, so this is a real path.
    // The resume replays its own session; the caller's fresh one is not needed.
    if pausedDownloads[itemId] != nil, pendingDownloadInfo[itemId] != nil {
      if let playbackSessionID { releaseSessionProvider?(playbackSessionID) }
      resumeDownload(itemId: itemId)
      return
    }
    // Resume data with no metadata to resume it under cannot be used; a fresh start replaces it.
    pausedDownloads.removeValue(forKey: itemId)
    removeResumeBlob(for: itemId)

    // Clear any prior failure record — this itemId is being (re)started.
    clearFailure(itemId)

    var request = URLRequest(url: videoURL)
    // Video Station embeds the SID as a `_sid=` query parameter in the URL itself.
    // In that case no Authorization header is needed — the credential is already in the URL.
    // For the REST API backend, attach the Bearer token as a header.
    if !videoURL.absoluteString.contains("_sid="), let token {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      // FR-220: a download is opened for the active profile, like every other request.
      ActiveProfileStore.shared.applyHeader(to: &request)
    }
    if usesTunnelCookieProvider?() == true {
      request.setValue("type=tunnel", forHTTPHeaderField: "Cookie")
    }
    // TASK-738: honour the "Download over Wi-Fi only" preference (default on) at the
    // request level — works without recreating the background session. Defaults to
    // true when the key has never been set (registerDefaults below).
    request.allowsCellularAccess = !UserDefaults.standard.bool(forKey: "dsReel.downloadsWifiOnly")

    let task = backgroundSession.downloadTask(with: request)
    // The item travels WITH the task (TASK-947). The system keeps taskDescription when it
    // terminates the app, so a transfer that finishes after this process is gone still says
    // which title it is. `downloadTasks` is only this process's copy of the same fact.
    task.taskDescription = itemId
    downloadTasks[task] = itemId
    if let playbackSessionID { downloadSessionIDs[itemId] = playbackSessionID }
    pendingDownloadInfo[itemId] = (title: title, year: year, posterURL: posterURL, durationSeconds: durationSeconds, token: token, videoURL: videoURL, ageLevel: ageLevel)
    // Persisted BEFORE the transfer starts: if the app is terminated mid-download, this is
    // what the next process finishes it with (title, age level, session).
    persistDownloadMeta(for: itemId)

    let download = ActiveDownload(id: itemId, title: title, progress: 0, task: task)
    activeDownloads[itemId] = download
    downloadProgress[itemId] = 0

    task.resume()
  }

  func cancelDownload(itemId: String) {
    // Cancel an active download if present
    if let download = activeDownloads[itemId] {
      retire(download.task)
      downloadTasks.removeValue(forKey: download.task)
      activeDownloads.removeValue(forKey: itemId)
      forgetProgress(itemId)
    }
    // Cancel is a terminal path, so it releases the session like the others. It used to be
    // the one that did not: the map entry was gone before the delegate's cancel callback ran,
    // so a cancelled transfer's session sat on the server until the idle reaper took it.
    releasePlaybackSession(for: itemId)
    resumedFromData.remove(itemId)
    // Clean up all state regardless of whether download was active or paused
    pendingDownloadInfo.removeValue(forKey: itemId)
    pausedDownloads.removeValue(forKey: itemId)
    clearFailure(itemId)
    forgetDownload(for: itemId)
  }

  func deleteDownload(itemId: String) {
    var items = getDownloadedItems()
    guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }

    let item = items[index]

    // Tell any active player BEFORE the file goes. Synchronous post: the listener tears
    // the player down inside this call, so by the time removeItem runs nothing holds the
    // asset open (TASK-903). The deletion itself still proceeds unconditionally — the
    // purge is correct policy (TASK-807) and must not be skippable by something playing.
    NotificationCenter.default.post(
      name: .downloadWillBeDeleted, object: nil, userInfo: ["itemId": itemId]
    )

    // Delete files
    let fm = FileManager.default
    try? fm.removeItem(atPath: item.videoPath)
    if let posterPath = item.posterPath {
      try? fm.removeItem(atPath: posterPath)
    }

    items.remove(at: index)
    saveDownloadedItems(items)
    cachedDownloadedItems = nil
    // Clear any resume data that might be lingering
    pausedDownloads.removeValue(forKey: itemId)
    forgetDownload(for: itemId)
  }

  /// TASK-807: bulk-purge every downloaded file and all download state. Called on
  /// logout() so a shared device leaves no cross-user video residue on disk.
  func clearAll() {
    // Cancel any in-flight tasks first so no completion handler re-creates state
    // or writes a file after we've wiped the directory.
    for (_, download) in activeDownloads {
      retire(download.task)
      downloadTasks.removeValue(forKey: download.task)
    }
    // Also stop anything in the session this process is not tracking (a task an older build
    // left unlabelled, or one not yet re-attached), so the next user does not inherit it.
    // Checked on the main actor against the map, so a download started after sign-out is
    // never the one cancelled.
    backgroundSession.getAllTasks { [weak self] tasks in
      Task { @MainActor in
        guard let self else { return }
        for case let task as URLSessionDownloadTask in tasks where self.downloadTasks[task] == nil {
          self.retire(task)
        }
      }
    }
    activeDownloads.removeAll()
    downloadProgress.removeAll()
    downloadBytes.removeAll()
    pausedDownloads.removeAll()
    failedDownloads.removeAll()
    deferredWork = DeferredWork()
    pendingDownloadInfo.removeAll()
    downloadSessionIDs.removeAll()
    lastProgressUpdate.removeAll()
    resumedFromData.removeAll()

    // Every download is going. nil itemId means "whatever you have loaded, it is about to
    // be removed" — posted before any unlink for the same reason deleteDownload does it
    // (TASK-903). Sign-out still purges regardless of what is playing.
    NotificationCenter.default.post(
      name: .downloadWillBeDeleted, object: nil, userInfo: [:]
    )

    let fm = FileManager.default

    // Remove individual poster files recorded in metadata (posters may live outside
    // the Downloads directory), then remove the whole Downloads directory.
    for item in getDownloadedItems() {
      try? fm.removeItem(atPath: item.videoPath)
      if let posterPath = item.posterPath {
        try? fm.removeItem(atPath: posterPath)
      }
    }
    try? fm.removeItem(at: downloadsDirectory())

    // Wipe persisted metadata and any lingering resume-data blobs. The unfinished-download
    // metadata goes too: it names titles and stream URLs, and left behind it would come back
    // as the next user's paused or failed rows.
    try? fm.removeItem(at: downloadsMetadataFileURL)
    try? fm.removeItem(at: pausedMetaFileURL)
    // Failed rows name titles; deferred work names sessions and poster URLs. None may outlive
    // the account.
    try? fm.removeItem(at: failedDownloadsFileURL)
    try? fm.removeItem(at: deferredWorkFileURL)
    stoppedByPauseWithoutData.removeAll()
    cachedDownloadedItems = nil
  }

  func isDownloaded(itemId: String) -> Bool {
    getDownloadedItems().contains { $0.id == itemId }
  }

  /// The one place a transfer's progress is dropped, so the percent and the bytes cannot disagree.
  private func forgetProgress(_ itemId: String) {
    downloadProgress.removeValue(forKey: itemId)
    downloadBytes.removeValue(forKey: itemId)
  }

  /// What the Downloads surface shows for an in-flight row (FR-030).
  func rowState(for itemId: String) -> DownloadRowState {
    DownloadRowState.make(isActive: isDownloading(itemId: itemId),
                          isPaused: isPaused(itemId: itemId),
                          progress: downloadProgress[itemId] ?? 0,
                          bytes: downloadBytes[itemId])
  }

  func isDownloading(itemId: String) -> Bool {
    activeDownloads[itemId] != nil
  }

  func isPaused(itemId: String) -> Bool {
    pausedDownloads[itemId] != nil
  }

  /// What tapping a title's download control does (FR-040, TASK-964). ONE home for the
  /// choice, so the title page cannot open a second transfer beside a paused one: a paused
  /// download offers Resume, which continues the partial under its own session, instead of
  /// Download, which would open a fresh playback session first and then have it released.
  enum DownloadAffordance: Equatable, Sendable {
    case download, cancel, resume, remove
  }

  func affordance(for itemId: String) -> DownloadAffordance {
    if isDownloading(itemId: itemId) { return .cancel }
    if playableDownloadedItem(itemId: itemId) != nil { return .remove }
    // Resume needs the metadata to resume under (resumeDownload guards on it); a partial
    // without it cannot be continued, and a fresh start replaces it.
    if isPaused(itemId: itemId), pendingDownloadInfo[itemId] != nil { return .resume }
    return .download
  }

  /// Returns the display title for a paused download (sourced from pendingDownloadInfo).
  func pausedDownloadTitle(itemId: String) -> String? {
    pendingDownloadInfo[itemId]?.title
  }

  // MARK: - TASK-782: failed-download surface

  func isFailed(itemId: String) -> Bool {
    failedDownloads[itemId] != nil
  }

  /// Re-issue a previously-failed download from its captured metadata. Every failure can be
  /// retried: a retry re-resolves a fresh session, and a storage failure needs only free space.
  func retryFailedDownload(itemId: String) {
    // No videoURL requirement: a retry re-resolves by item id and never uses the stored URL,
    // and a download adopted after a relaunch without its metadata has none (TASK-947).
    guard let failure = failedDownloads[itemId] else { return }
    clearFailure(itemId)
    // Re-resolve rather than reusing failure.videoURL: that URL is session-scoped and its
    // session is already released (the failure path releases it), so a retry against the
    // stored URL would 404 every time.
    restartWithFreshURL(
      itemId: itemId,
      info: (title: failure.title, year: failure.year, posterURL: failure.posterURL,
             durationSeconds: failure.durationSeconds, token: failure.token,
             videoURL: failure.videoURL, ageLevel: failure.ageLevel)
    )
  }

  /// Dismiss a failure row without retrying.
  func dismissFailedDownload(itemId: String) {
    clearFailure(itemId)
  }

  /// The ONE way a Failed row appears. It is written to disk with it (FR-032): a failure stays
  /// on the Downloads screen across a relaunch until the user retries or dismisses it.
  private func raiseFailure(_ failure: FailedDownload) {
    failedDownloads[failure.id] = failure
    persistFailures()
  }

  private func clearFailure(_ itemId: String) {
    guard failedDownloads.removeValue(forKey: itemId) != nil else { return }
    persistFailures()
  }

  /// Pause an active download, capturing resume data so it can be continued later.
  /// Async: awaits the resume-data callback before returning so callers know the pause is complete.
  func pauseDownload(itemId: String) async {
    guard let download = activeDownloads[itemId] else { return }
    let task = download.task
    // Unlabel first: this process records the stop itself, so the delegate's cancel callback
    // must not later mistake the task for a previous process's and adopt it (`owner(of:)`).
    task.taskDescription = nil

    pausing.insert(itemId)
    let resumeData: Data? = await withCheckedContinuation { continuation in
      task.cancel(byProducingResumeData: { data in
        continuation.resume(returning: data)
      })
    }
    pausing.remove(itemId)

    // Back on @MainActor. The delegate's stop callback was ignored while `pausing` held the
    // item. If the map entry is gone, the transfer finished just before the cancel and
    // didFinishDownloadingTo completed it: there is nothing to pause.
    guard downloadTasks[task] != nil else { return }
    // Nothing to resume can still mean the bytes were already complete: the transfer finished in
    // the instant before the cancel, and its file is delivered after this. Remember whose task
    // it was so that late delivery is kept, not discarded (TASK-994).
    if resumeData == nil { stoppedByPauseWithoutData[task.taskIdentifier] = itemId }
    // Same rule as any other stop: resume data makes it a paused row; none means it cannot be
    // continued, which is said in a Failed row instead of the row silently vanishing.
    recordStop(itemId: itemId, task: task, errorCode: NSURLErrorCancelled,
               resumeData: resumeData, cancelReason: nil)
  }

  /// Resume a previously paused download.
  /// If resume data is available (happy path), resumes from where it left off.
  /// If resume data was lost after relaunch but the video URL was persisted, starts a fresh download.
  /// If neither is available, sets an error state on the item.
  func resumeDownload(itemId: String) {
    guard let info = pendingDownloadInfo[itemId] else { return }
    guard activeDownloads[itemId] == nil else { return } // already active

    if let resumeData = pausedDownloads[itemId] {
      // Resume with saved data
      let task = backgroundSession.downloadTask(withResumeData: resumeData)
      task.taskDescription = itemId   // survives termination, like a fresh start's (TASK-947)
      downloadTasks[task] = itemId
      resumedFromData.insert(itemId)
      // Recorded with the metadata so a termination mid-transfer keeps the 404 fallback.
      persistDownloadMeta(for: itemId)
      let download = ActiveDownload(
        id: itemId,
        title: info.title,
        progress: downloadProgress[itemId] ?? 0,
        task: task
      )
      activeDownloads[itemId] = download
      // Clear the paused state. The download's metadata stays persisted: it is still
      // unfinished, and a termination from here on is adopted like any other transfer.
      pausedDownloads.removeValue(forKey: itemId)
      removeResumeBlob(for: itemId)
      task.resume()
    } else if info.videoURL != nil {
      // Resume data was lost (e.g. app was force-quit). Restart from the beginning — but
      // re-resolve the URL first: the stored one is session-scoped and its session is long
      // gone, so reusing it would 404 and write an error body as the movie.
      pendingDownloadInfo.removeValue(forKey: itemId)
      forgetDownload(for: itemId)
      restartWithFreshURL(itemId: itemId, info: info)
    } else {
      // Neither resume data nor video URL available — cannot resume.
      // Surface it: clearing state silently made the row vanish on tap with no
      // explanation of why.
      pendingDownloadInfo.removeValue(forKey: itemId)
      pausedDownloads.removeValue(forKey: itemId)
      forgetDownload(for: itemId)
      raiseFailure(FailedDownload(
        id: itemId, title: info.title, videoURL: info.videoURL,
        posterURL: info.posterURL, token: nil, year: info.year,
        durationSeconds: info.durationSeconds, ageLevel: info.ageLevel,
        message: "This download can't be resumed. Tap to start it again."
      ))
    }
  }

  /// Reads and decodes the manifest, distinguishing the three states that matter.
  ///
  /// The whole point is that "the file is not there" and "the file is there and unreadable"
  /// are DIFFERENT, and were previously the same: a decode failure fell through to `[]`, and
  /// the next write persisted that empty state. One truncated write — a jetsam kill, a full
  /// disk — and twenty downloads became one, with the .mp4 files orphaned on disk, invisible
  /// and unreclaimable through the app.
  ///
  /// A failure to READ is never evidence that there is nothing to read.
  private func loadManifest() -> ManifestState {
    let fileURL = downloadsMetadataFileURL
    guard let data = try? Data(contentsOf: fileURL) else {
      return .absent
    }
    // An empty file is a torn write, not an empty library. `JSONDecoder` rejects it anyway,
    // but say so explicitly so the intent survives a refactor.
    guard !data.isEmpty else {
      return .unreadable(reason: "manifest file is zero bytes")
    }
    do {
      return .items(try JSONDecoder().decode([DownloadedItem].self, from: data))
    } catch {
      return .unreadable(reason: error.localizedDescription)
    }
  }

  /// Moves a corrupt manifest aside instead of letting it be overwritten, and rebuilds what
  /// can be rebuilt from the media still on disk.
  ///
  /// Quarantine rather than delete: the file is the only record of what the user had, it may
  /// be partially salvageable by hand, and deleting is exactly the instinct that caused the
  /// data loss in the first place.
  ///
  /// Returns the reconstructed manifest, which is written back so the app has a coherent
  /// state to work from.
  @discardableResult
  private func quarantineAndRebuildManifest(reason: String) -> [DownloadedItem] {
    let fm = FileManager.default
    let fileURL = downloadsMetadataFileURL

    if fm.fileExists(atPath: fileURL.path) {
      let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
      let quarantined = fileURL.deletingLastPathComponent()
        .appendingPathComponent("downloads.corrupt-\(stamp).json")
      do {
        try fm.moveItem(at: fileURL, to: quarantined)
        log.error("downloads manifest unreadable (\(reason)) — quarantined to \(quarantined.lastPathComponent)")
      } catch {
        // Could not move it aside. Do NOT proceed to overwrite: leaving the corrupt file in
        // place preserves whatever it still holds, and the caller gets an empty list for this
        // launch rather than a destroyed manifest.
        log.error("downloads manifest unreadable (\(reason)) and could not be quarantined — \(error.localizedDescription). Leaving it untouched.")
        manifestUnavailableReason = "Your downloads list couldn't be read. Your downloaded videos are still on this device."
        return []
      }
    }

    // Rebuild from the media that actually exists. Every file in the Downloads directory is
    // named `<itemId>.mp4`, so the id — the one thing that matters for playback and for
    // de-duplicating a re-download — is recoverable. Title and duration are not, so they are
    // filled with honest placeholders rather than invented values.
    let dir = downloadsDirectory()
    let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    let rebuilt: [DownloadedItem] = files.compactMap { url in
      guard url.pathExtension.lowercased() == "mp4" else { return nil }
      let id = url.deletingPathExtension().lastPathComponent
      guard !id.isEmpty else { return nil }
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
      let added = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
      return DownloadedItem(
        id: id,
        title: id,          // The real title is gone with the manifest; the id is at least true.
        year: nil,
        videoPath: url.lastPathComponent,
        posterPath: nil,
        fileSize: size,
        downloadedAt: added,
        resumePositionSeconds: 0,
        durationSeconds: 0
      )
    }

    if rebuilt.isEmpty {
      manifestUnavailableReason = "Your downloads list couldn't be read and no downloaded videos were found."
    } else {
      manifestUnavailableReason = "Your downloads list was rebuilt from the videos on this device. "
        + "Titles and watch positions for \(rebuilt.count) item(s) were lost, but the videos still play."
      log.info("rebuilt downloads manifest from disk — \(rebuilt.count) item(s) recovered")
    }
    saveDownloadedItems(rebuilt)
    return rebuilt
  }

  func getDownloadedItems() -> [DownloadedItem] {
    if let cached = cachedDownloadedItems { return cached }

    // Read from Application Support JSON file (canonical storage).
    // Migrate from UserDefaults on first launch after upgrade: copy data to file, then remove key.
    let fileURL = downloadsMetadataFileURL
    var rawData: Data?
    switch loadManifest() {
    case .items:
      rawData = try? Data(contentsOf: fileURL)
    case .unreadable(let reason):
      // Corrupt, not empty. Quarantine, rebuild from disk, and return that — never fall
      // through to `[]` and let a later write make the loss permanent.
      let rebuilt = quarantineAndRebuildManifest(reason: reason)
      cachedDownloadedItems = rebuilt
      return rebuilt
    case .absent:
      rawData = nil
    }
    if rawData == nil, let udData = UserDefaults.standard.data(forKey: storageKey) {
      // Migration path: write to Application Support, then remove from UserDefaults.
      // Only remove from UserDefaults after confirming the write succeeded — preserves
      // data if the write fails (e.g. disk full) so the next launch can retry (TASK-549).
      rawData = udData
      let dir = fileURL.deletingLastPathComponent()
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      do {
        try udData.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
          ofItemAtPath: fileURL.path
        )
        UserDefaults.standard.removeObject(forKey: storageKey) // only remove after successful write
      } catch {
        // Write failed — keep UserDefaults intact for next launch (TASK-767: log so it's diagnosable)
        log.error("persistDownloadedItems: file write failed, retaining UserDefaults fallback — \(error.localizedDescription)")
      }
    }

    guard let data = rawData,
          let items = try? JSONDecoder().decode([DownloadedItem].self, from: data) else {
      return []
    }
    let dir = downloadsDirectory()
    // Resolve stored videoPath: new items store a filename only; legacy items store an absolute path.
    // For legacy absolute paths that no longer exist (stale after app update), attempt recovery by
    // filename inside the current Downloads directory.
    let resolved = items.compactMap { item -> DownloadedItem? in
      let resolvedPath: String
      if item.videoPath.hasPrefix("/") {
        // Legacy absolute path — use as-is if it still exists, otherwise try filename recovery
        if FileManager.default.fileExists(atPath: item.videoPath) {
          resolvedPath = item.videoPath
        } else {
          let recovered = dir.appendingPathComponent(URL(fileURLWithPath: item.videoPath).lastPathComponent).path
          guard FileManager.default.fileExists(atPath: recovered) else { return nil }
          resolvedPath = recovered
        }
      } else {
        // New format: filename only — reconstruct full path
        resolvedPath = dir.appendingPathComponent(item.videoPath).path
        guard FileManager.default.fileExists(atPath: resolvedPath) else { return nil }
      }
      // Resolve posterPath: same filename-only / absolute-path logic as videoPath.
      let resolvedPosterPath: String?
      if let pp = item.posterPath {
        if pp.hasPrefix("/") {
          resolvedPosterPath = FileManager.default.fileExists(atPath: pp) ? pp : nil
        } else {
          let full = dir.appendingPathComponent(pp).path
          resolvedPosterPath = FileManager.default.fileExists(atPath: full) ? full : nil
        }
      } else {
        resolvedPosterPath = nil
      }

      // Return item with the resolved full paths for callers that use them directly.
      // Copy-and-set, not a rebuilt value: every other field (age level, each profile's
      // position) must survive the read.
      var resolvedItem = item
      resolvedItem.videoPath = resolvedPath
      resolvedItem.posterPath = resolvedPosterPath
      return resolvedItem
    }
    cachedDownloadedItems = resolved
    return resolved
  }

  /// The account's download for `itemId`, whoever is watching. Bookkeeping only (delete,
  /// "is it on disk"); anything that SHOWS or PLAYS a download goes through
  /// `visibleDownloadedItems()` / `playableDownloadedItem(itemId:)`.
  func getDownloadedItem(itemId: String) -> DownloadedItem? {
    getDownloadedItems().first { $0.id == itemId }
  }

  // MARK: - Profiles (FR-262, FR-233)

  /// The downloads the ACTIVE profile may see (FR-262, AC-002-43). Downloads are the
  /// account's, but a restricted profile is never shown a title above its ceiling: the local
  /// file plays with no server in the loop, so this is the only gate there is offline. Uses
  /// the app's one visibility rule, `ProfileScope.allows`; an unknown level is unrated and
  /// hidden on every restricted profile.
  func visibleDownloadedItems() -> [DownloadedItem] {
    let scope = profileStore.activeScope
    return getDownloadedItems().filter { scope.allows(ageLevel: $0.ageLevel) }
  }

  /// The download for `itemId` if the active profile may play it, else nil (FR-262). Every
  /// path that opens a local file asks this at the moment of playing, online or offline, so a
  /// profile switch after a list was built cannot carry an over-ceiling title through.
  func playableDownloadedItem(itemId: String) -> DownloadedItem? {
    guard let item = getDownloadedItem(itemId: itemId),
          profileStore.activeScope.allows(ageLevel: item.ageLevel) else { return nil }
    return item
  }

  /// Whether an in-flight (downloading, paused or failed) row may be shown to the active
  /// profile (FR-262): its title is a local read too. Uses the level captured at start;
  /// unknown fails closed like everything else.
  func isInFlightVisible(itemId: String) -> Bool {
    let level = failedDownloads[itemId]?.ageLevel ?? pendingDownloadInfo[itemId]?.ageLevel
    return profileStore.activeScope.allows(ageLevel: level)
  }

  /// The profile offline progress is recorded for: the active one, or "" (legacy) when none
  /// is chosen. A player captures this when it OPENS and passes it to every
  /// `updateResumePosition` call, so a profile change mid-playback cannot reassign the save.
  var activeResumeProfileID: String { profileStore.activeScope.id }

  /// Where `profileID` (default: the active profile) is in `item` offline (FR-233).
  func resumePosition(of item: DownloadedItem, profileID: String? = nil) -> Int {
    let ownerID = profileStore.cachedProfiles.first(where: \.isOwner)?.id
    return item.resumePosition(forProfileID: profileID ?? activeResumeProfileID, ownerID: ownerID)
  }

  /// Persists the current playback position for an offline item, for ONE profile.
  /// Called periodically during playback (same debounce cadence as the online API sync)
  /// and once more on player dismiss. `profileID` nil means the active profile; players pass
  /// the id they captured on open (`activeResumeProfileID`).
  func updateResumePosition(itemId: String, positionSeconds: Int, profileID: String? = nil) {
    // Read raw items directly from the metadata file to preserve the filename-only storage invariant.
    // Using getDownloadedItems() would resolve absolute paths and write them back, undoing the fix.
    guard let rawData = try? Data(contentsOf: downloadsMetadataFileURL),
          var rawItems = try? JSONDecoder().decode([DownloadedItem].self, from: rawData),
          let index = rawItems.firstIndex(where: { $0.id == itemId }) else { return }
    rawItems[index].setResumePosition(positionSeconds, forProfileID: profileID ?? activeResumeProfileID)
    saveDownloadedItems(rawItems)
    cachedDownloadedItems = nil
  }

  /// Brings every download's stored age level up to date from the on-device catalog
  /// (FR-262). Backfills downloads made before levels were stored, and picks up a title the
  /// server has since re-rated. A title the catalog has no level for keeps what it had; one
  /// that never had a level stays unknown, which every restricted profile treats as hidden.
  /// Reads and writes the raw manifest, never the resolved paths (same invariant as
  /// `updateResumePosition`).
  func refreshAgeLevels() async {
    guard case .items(let before) = loadManifest(), !before.isEmpty else { return }
    var resolved: [String: Int] = [:]
    for item in before {
      if let level = await ageLevelLookup(item.id) { resolved[item.id] = level }
    }
    guard !resolved.isEmpty else { return }
    // Re-read after the awaits: a download may have completed, or a position been saved,
    // meanwhile, and writing `before` back would undo it.
    guard case .items(var rawItems) = loadManifest() else { return }
    var changed = false
    for index in rawItems.indices {
      guard let level = resolved[rawItems[index].id], rawItems[index].ageLevel != level else { continue }
      rawItems[index].ageLevel = level
      changed = true
    }
    guard changed else { return }
    saveDownloadedItems(rawItems)
    cachedDownloadedItems = nil
  }

  // MARK: - Surviving app termination (TASK-947)

  /// Re-attaches the transfers a previous process left in the background session, then settles
  /// every unfinished download that has no transfer left. Called once at launch with the
  /// session's `getAllTasks` answer; internal so a test can hand it tasks as the session would.
  ///
  /// Order matters: `restorePersistedDownloads()` has already rebuilt each download's metadata
  /// from disk, so an adopted task finds its title, age level and session here.
  func adoptSurvivingTasks(_ tasks: [URLSessionTask]) {
    // Items whose task is still in the session in any state. A task that already finished or
    // failed still has its delegate callback to come, and that callback settles the item;
    // marking it "interrupted" here would race it.
    var itemsWithATask: Set<String> = []
    for case let task as URLSessionDownloadTask in tasks {
      guard let itemId = task.taskDescription, !itemId.isEmpty else {
        // Unlabelled: started by a build that did not record the item, so nothing can say
        // which title it is or finish it. Stop it rather than let it run to a discarded file.
        if task.state == .running || task.state == .suspended { task.cancel() }
        continue
      }
      itemsWithATask.insert(itemId)
      guard task.state == .running || task.state == .suspended,
            downloadTasks[task] == nil else { continue }
      if isDownloaded(itemId: itemId) || activeDownloads[itemId] != nil {
        // Already finished, or a transfer for it is tracked: this one would be a duplicate.
        retire(task)
        continue
      }
      let info = pendingDownloadInfo[itemId] ?? minimalInfo(for: itemId)
      pendingDownloadInfo[itemId] = info
      downloadTasks[task] = itemId
      let expected = task.countOfBytesExpectedToReceive
      let progress = expected > 0 ? Double(task.countOfBytesReceived) / Double(expected) : 0
      activeDownloads[itemId] = ActiveDownload(id: itemId, title: info.title, progress: progress, task: task)
      downloadProgress[itemId] = progress
      downloadBytes[itemId] = TransferBytes(written: task.countOfBytesReceived, expected: expected)
      // The live transfer is the item's state now; an older paused or failed record is stale.
      pausedDownloads.removeValue(forKey: itemId)
      removeResumeBlob(for: itemId)
      clearFailure(itemId)
      if task.state == .suspended { task.resume() }
    }

    // Persisted as unfinished, but with no transfer, no resume data and no failure row: the
    // transfer was lost with the process (the system discards a task it could not continue).
    // Say so in a Failed row; never let the title silently disappear (FR-032).
    for itemId in loadPausedMetaFromDisk().keys
    where !itemsWithATask.contains(itemId) && activeDownloads[itemId] == nil
      && pausedDownloads[itemId] == nil && failedDownloads[itemId] == nil {
      if isDownloaded(itemId: itemId) {
        pendingDownloadInfo.removeValue(forKey: itemId)
        forgetDownload(for: itemId)
        continue
      }
      releasePlaybackSession(for: itemId)
      resumedFromData.remove(itemId)
      let info = pendingDownloadInfo.removeValue(forKey: itemId) ?? minimalInfo(for: itemId)
      forgetDownload(for: itemId)
      raiseFailure(failure(itemId: itemId, info: info,
                           message: "This download was interrupted. Tap to start it again."))
    }

    survivingTasksAdopted = true
    let held = startsAwaitingAdoption
    startsAwaitingAdoption = []
    held.forEach { $0() }
  }

  /// Stops a task this process has finished with, unlabelling it first so no delegate callback
  /// still in flight (or a later process) claims it through `owner(of:)`.
  private func retire(_ task: URLSessionDownloadTask) {
    task.taskDescription = nil
    task.cancel()
  }

  /// The item a task belongs to: this process's map, else the label the task carries, which is
  /// how a callback for a task started by a previous process is recognised.
  private func owner(of task: URLSessionTask) -> String? {
    if let downloadTask = task as? URLSessionDownloadTask, let itemId = downloadTasks[downloadTask] {
      return itemId
    }
    guard let label = task.taskDescription, !label.isEmpty else { return nil }
    // The item already has a transfer of this process's own: that one is its state, and a
    // stale task's late callback must not end it.
    if let active = activeDownloads[label], active.task !== task { return nil }
    return label
  }

  /// The metadata to finish (or fail) a download with, from the best record there is.
  private func finishingInfo(for itemId: String) -> DownloadInfo {
    if let info = pendingDownloadInfo[itemId] { return info }
    if let f = failedDownloads[itemId] {
      return (title: f.title, year: f.year, posterURL: f.posterURL, durationSeconds: f.durationSeconds,
              token: f.token, videoURL: f.videoURL, ageLevel: f.ageLevel)
    }
    return minimalInfo(for: itemId)
  }

  /// No record at all: the id stands in for the title and the level stays unknown, which every
  /// restricted profile treats as hidden (FR-262).
  private func minimalInfo(for itemId: String) -> DownloadInfo {
    (title: itemId, year: nil, posterURL: nil, durationSeconds: 0, token: nil, videoURL: nil, ageLevel: nil)
  }

  /// One shape for every Failed row this file raises. Always retryable: a retry re-resolves.
  private func failure(itemId: String, info: DownloadInfo, message: String) -> FailedDownload {
    FailedDownload(
      id: itemId, title: info.title, videoURL: info.videoURL,
      posterURL: info.posterURL, token: info.token, year: info.year,
      durationSeconds: info.durationSeconds, ageLevel: info.ageLevel,
      message: message
    )
  }

  /// The transfer finished but its file could not be kept on this device (TASK-971): the temp
  /// file could not be preserved, the move failed, or the manifest could not record it. The
  /// item leaves Downloading for a Failed row that names storage, never connection (FR-033).
  /// Retryable: freeing space fixes it, and a retry re-resolves a fresh session.
  private func recordSaveFailure(itemId: String, info: DownloadInfo, error: Error?) {
    activeDownloads.removeValue(forKey: itemId)
    forgetProgress(itemId)
    lastProgressUpdate.removeValue(forKey: itemId)
    pendingDownloadInfo.removeValue(forKey: itemId)
    resumedFromData.remove(itemId)
    releasePlaybackSession(for: itemId)
    forgetDownload(for: itemId)
    let message = Self.isOutOfSpace(error)
      ? "There isn't enough free storage to save this download. Free up space, then retry."
      : "Couldn't save the download on this device. Check free storage, then retry."
    raiseFailure(failure(itemId: itemId, info: info, message: message))
    log.error("download \(itemId) finished but could not be saved: \(error?.localizedDescription ?? "manifest write failed")")
  }

  private static func isOutOfSpace(_ error: Error?) -> Bool {
    guard let ns = error as NSError? else { return false }
    if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return true }
    if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return true }
    return isOutOfSpace(ns.userInfo[NSUnderlyingErrorKey] as? NSError)
  }

  /// A transfer stopped without finishing (pause, network loss, cancellation by the system).
  /// With resume data it is a paused row that continues from where it stopped; the playback
  /// session is kept because the resume data replays its stream URL (if the server reaped it
  /// meanwhile, `recordHTTPFailure` restarts fresh). Without resume data it cannot continue,
  /// and a Failed row says why.
  private func recordStop(itemId: String, task: URLSessionDownloadTask, errorCode: Int,
                          resumeData: Data?, cancelReason: Int?) {
    downloadTasks.removeValue(forKey: task)
    activeDownloads.removeValue(forKey: itemId)
    forgetProgress(itemId)
    lastProgressUpdate.removeValue(forKey: itemId)
    resumedFromData.remove(itemId)
    if let resumeData {
      if pendingDownloadInfo[itemId] == nil { pendingDownloadInfo[itemId] = minimalInfo(for: itemId) }
      pausedDownloads[itemId] = resumeData
      clearFailure(itemId)
      persistResumeData(resumeData, for: itemId)
      persistDownloadMeta(for: itemId)
      return
    }
    releasePlaybackSession(for: itemId)
    let info = pendingDownloadInfo.removeValue(forKey: itemId) ?? minimalInfo(for: itemId)
    pausedDownloads.removeValue(forKey: itemId)
    forgetDownload(for: itemId)
    raiseFailure(failure(
      itemId: itemId, info: info,
      message: Self.stopMessage(errorCode: errorCode, cancelReason: cancelReason)))
  }

  /// FR-033: the message names the real cause of a stop that left nothing to resume.
  private static func stopMessage(errorCode: Int, cancelReason: Int?) -> String {
    let storageCodes = [NSURLErrorCannotCreateFile, NSURLErrorCannotOpenFile, NSURLErrorCannotCloseFile,
                        NSURLErrorCannotWriteToFile, NSURLErrorCannotRemoveFile, NSURLErrorCannotMoveFile]
    if storageCodes.contains(errorCode) {
      return "Couldn't save the download on this device. Check free storage, then retry."
    }
    guard errorCode == NSURLErrorCancelled else {
      return "Download failed. Check your connection and retry."
    }
    switch cancelReason {
    case NSURLErrorCancelledReasonUserForceQuitApplication:
      return "The download stopped because the app was closed. Tap to start it again."
    case NSURLErrorCancelledReasonBackgroundUpdatesDisabled:
      return "The download stopped because Background App Refresh is off. Turn it on in Settings, then start it again."
    case NSURLErrorCancelledReasonInsufficientSystemResources:
      return "The download was stopped by the system to free resources. Tap to start it again."
    default:
      return "This download couldn't be paused and has to start over."
    }
  }

  // MARK: - Private

  // MARK: Resume Data Persistence

  /// Returns the filesystem URL for the resume data file of a given item.
  /// Resume data blobs can be multi-MB and must NOT be stored in UserDefaults.
  private func resumeDataFileURL(for itemId: String) -> URL {
    downloadsDirectory().appendingPathComponent("\(itemId).resumedata")
  }

  /// SEC-01: Unfinished-download metadata, stored in Application Support (not UserDefaults:
  /// it contains videoURLs, which are user data).
  ///
  /// Holds EVERY unfinished download, not only paused ones (TASK-947): written when a transfer
  /// starts, removed when it completes, fails, is cancelled or deleted. It is what the next
  /// process finishes a transfer with after the system terminated this one. The file name is
  /// historical and kept so existing installs read their paused downloads.
  private var pausedMetaFileURL: URL {
    // containerOverride is nil in production (R4 test seam) — same <AppSupport>/pausedMeta.json.
    let appSupport = containerOverride
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("pausedMeta.json")
  }

  private func loadPausedMetaFromDisk() -> [String: [String: String]] {
    guard let data = try? Data(contentsOf: pausedMetaFileURL),
          let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
      return [:]
    }
    return decoded
  }

  private func savePausedMetaToDisk(_ store: [String: [String: String]]) {
    let fileURL = pausedMetaFileURL
    let dir = fileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(store) else { return }
    try? data.write(to: fileURL, options: .atomic)
    try? FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: fileURL.path
    )
  }

  private var failedDownloadsFileURL: URL {
    (containerOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
      .appendingPathComponent("failedDownloads.json")
  }

  private var deferredWorkFileURL: URL {
    (containerOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
      .appendingPathComponent("deferredDownloadWork.json")
  }

  /// Writes `value` to `url` atomically, or removes the file when there is nothing to keep.
  private func writeJSON<T: Encodable>(_ value: T, isEmpty: Bool, to url: URL) {
    if isEmpty {
      try? FileManager.default.removeItem(at: url)
      return
    }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
      try JSONEncoder().encode(value).write(to: url, options: .atomic)
      try? FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path)
    } catch {
      log.error("could not write \(url.lastPathComponent): \(error.localizedDescription)")
    }
  }

  /// Failed rows persist without the token and with the `_sid=` credential stripped from the URL.
  private func persistFailures() {
    let safe = failedDownloads.values.map { f in
      FailedDownload(id: f.id, title: f.title, videoURL: f.videoURL.map(strippingSid(from:)),
                     posterURL: f.posterURL, token: nil, year: f.year,
                     durationSeconds: f.durationSeconds, ageLevel: f.ageLevel, message: f.message)
    }
    writeJSON(safe, isEmpty: safe.isEmpty, to: failedDownloadsFileURL)
  }

  private func persistDeferredWork() {
    writeJSON(deferredWork, isEmpty: deferredWork.isEmpty, to: deferredWorkFileURL)
  }

  /// One-time move of pre-SEC-01 resume state out of UserDefaults. `shared` only: a test
  /// manager must not move the host app's real keys.
  private func migrateLegacyResumeStore() {
    // Migrate legacy base64 blobs from UserDefaults to disk, then clear them.
    if let raw = UserDefaults.standard.dictionary(forKey: resumeDataKey) as? [String: String] {
      for (itemId, base64) in raw {
        if let data = Data(base64Encoded: base64) {
          try? data.write(to: resumeDataFileURL(for: itemId), options: .atomic)
        }
      }
      UserDefaults.standard.removeObject(forKey: resumeDataKey)
    }
    // SEC-01: Migrate legacy paused metadata from UserDefaults to Application Support file.
    if let legacy = UserDefaults.standard.dictionary(forKey: pausedMetaKey) as? [String: [String: String]], !legacy.isEmpty {
      let existing = loadPausedMetaFromDisk()
      let merged = existing.merging(legacy) { file, _ in file }  // prefer already-migrated entries
      savePausedMetaToDisk(merged)
      UserDefaults.standard.removeObject(forKey: pausedMetaKey)
    }
  }

  /// Rebuilds the in-memory state of every unfinished download from disk: its metadata, its
  /// resume data if it has any, and the playback session it holds. Runs at launch, before the
  /// session can deliver a previous process's task, so that delivery finds what it needs.
  private func restorePersistedDownloads() {
    if let data = try? Data(contentsOf: failedDownloadsFileURL),
       let saved = try? JSONDecoder().decode([FailedDownload].self, from: data) {
      for failure in saved { failedDownloads[failure.id] = failure }
    }
    if let data = try? Data(contentsOf: deferredWorkFileURL),
       let saved = try? JSONDecoder().decode(DeferredWork.self, from: data) {
      deferredWork = saved
    }
    for (itemId, meta) in loadPausedMetaFromDisk() {
      if let data = try? Data(contentsOf: resumeDataFileURL(for: itemId)) {
        pausedDownloads[itemId] = data
      }
      pendingDownloadInfo[itemId] = (
        title: meta["title"] ?? itemId,
        year: meta["year"].flatMap { Int($0) },
        posterURL: meta["posterURL"].flatMap { URL(string: $0) },
        durationSeconds: meta["durationSeconds"].flatMap { Int($0) } ?? 0,
        token: nil,   // a credential, never persisted; tokenProvider supplies a live one
        videoURL: meta["videoURL"].flatMap { URL(string: $0) },
        ageLevel: meta["ageLevel"].flatMap { Int($0) }
      )
      if let sessionID = meta["sessionID"] { downloadSessionIDs[itemId] = sessionID }
      // Started from resume data by the process that wrote this (see `resumedFromData`).
      if meta["resumed"] == "1" { resumedFromData.insert(itemId) }
    }
  }

  /// Persist resume data blob to a file in the Downloads directory.
  private func persistResumeData(_ data: Data, for itemId: String) {
    try? data.write(to: resumeDataFileURL(for: itemId), options: .atomic)
  }

  /// Persist an unfinished download's metadata so the next process can show, resume or
  /// finish it (TASK-947). Stores the video URL so resumeDownload can fall back to a fresh
  /// start if resume data is lost, the age level so a download finished after a relaunch keeps
  /// its FR-262 stamp, and the playback session so whichever process ends the transfer
  /// releases it. The session id is already the path of the stored stream URL, so recording it
  /// exposes nothing new. The `_sid=` query parameter (Video Station) is stripped: it is a
  /// short-lived credential.
  private func persistDownloadMeta(for itemId: String) {
    guard let info = pendingDownloadInfo[itemId] else { return }
    var store = loadPausedMetaFromDisk()
    var meta: [String: String] = ["title": info.title]
    if let year = info.year { meta["year"] = "\(year)" }
    if let posterURL = info.posterURL { meta["posterURL"] = posterURL.absoluteString }
    if let videoURL = info.videoURL {
      // Strip _sid= before persisting — it is a session credential.
      // startDownload re-attaches auth on resume.
      meta["videoURL"] = strippingSid(from: videoURL).absoluteString
    }
    meta["durationSeconds"] = "\(info.durationSeconds)"
    if let ageLevel = info.ageLevel { meta["ageLevel"] = "\(ageLevel)" }
    if let sessionID = downloadSessionIDs[itemId] { meta["sessionID"] = sessionID }
    if resumedFromData.contains(itemId) { meta["resumed"] = "1" }
    store[itemId] = meta
    savePausedMetaToDisk(store)
  }

  /// Returns a copy of `url` with the `_sid` query parameter removed.
  private func strippingSid(from url: URL) -> URL {
    guard url.absoluteString.contains("_sid="),
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url
    }
    components.queryItems = components.queryItems?.filter { $0.name != "_sid" }
    if components.queryItems?.isEmpty == true { components.queryItems = nil }
    return components.url ?? url
  }

  /// Remove an item's resume-data blob only; its metadata stays (the download is unfinished).
  private func removeResumeBlob(for itemId: String) {
    try? FileManager.default.removeItem(at: resumeDataFileURL(for: itemId))
  }

  /// Remove every persisted trace of an unfinished download: resume data and metadata. Called
  /// when the download ends for good (completed, failed, cancelled, deleted).
  private func forgetDownload(for itemId: String) {
    removeResumeBlob(for: itemId)
    var store = loadPausedMetaFromDisk()
    guard store.removeValue(forKey: itemId) != nil else { return }
    savePausedMetaToDisk(store)
  }

  /// URL for the downloads metadata JSON file in Application Support.
  /// This is the canonical storage location; UserDefaults is only consulted for migration.
  private var downloadsMetadataFileURL: URL {
    // containerOverride is nil in production (R4 test seam) — same <AppSupport>/downloads.json.
    let appSupport = containerOverride
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("downloads.json")
  }

  /// Returns false when the manifest could not be written (TASK-971: a caller that just landed
  /// a file must not report it downloaded if the record of it was lost).
  @discardableResult
  private func saveDownloadedItems(_ items: [DownloadedItem]) -> Bool {
    // FIX-9: Log encode/write failures instead of silently discarding download metadata.
    let data: Data
    do {
      data = try JSONEncoder().encode(items)
    } catch {
      log.error("saveDownloadedItems: encode failed — \(error.localizedDescription)")
      return false
    }
    let fileURL = downloadsMetadataFileURL
    // Ensure the Application Support directory exists
    let dir = fileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    do {
      try data.write(to: fileURL, options: .atomic)
    } catch {
      log.error("saveDownloadedItems: write failed — \(error.localizedDescription)")
      return false
    }
    // See applyFileProtection in LocalStore: .complete would make this unwritable while
    // the device is locked, which is precisely when background playback updates it.
    try? FileManager.default.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: fileURL.path
    )
    return true
  }

  private func downloadsDirectory() -> URL {
    let fm = FileManager.default
    // containerOverride is nil in production (R4 test seam) — same <Documents>/Downloads.
    let docs = containerOverride ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    var dir = docs.appendingPathComponent("Downloads", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    // Exclude downloaded videos (multi-GB) and resume-data blobs from iCloud/iTunes
    // backup. Without this, large media files count against the user's iCloud quota
    // and the app risks App Review rejection under guideline 2.5.x for storing
    // re-downloadable content in a backed-up location.
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? dir.setResourceValues(values)
    return dir
  }

  /// Internal (not private) only so tests can finish a download without a live transfer.
  func completeDownload(itemId: String, tempURL: URL) {
    // A finished file is never thrown away for want of bookkeeping (TASK-947). Normally the
    // in-flight metadata is here (restored from disk after a relaunch); if the item was meanwhile
    // marked failed (an "interrupted" row raised before this late delivery), its failure record
    // carries the same fields; failing both, the id stands in for the title and the level stays
    // unknown, which every restricted profile hides until `refreshAgeLevels` learns it.
    let info = finishingInfo(for: itemId)

    let dir = downloadsDirectory()
    let videoFilename = "\(itemId).mp4"
    let videoPath = dir.appendingPathComponent(videoFilename)

    let fm = FileManager.default
    try? fm.removeItem(at: videoPath)

    do {
      try fm.moveItem(at: tempURL, to: videoPath)
    } catch {
      // A cross-volume move copies, so a failure can leave a partial at the destination too.
      try? fm.removeItem(at: tempURL)
      try? fm.removeItem(at: videoPath)
      recordSaveFailure(itemId: itemId, info: info, error: error)
      return
    }

    // Encrypted at rest, but readable once the device has been unlocked since boot.
    // NOT .complete: background audio is on by default, so a locked device playing a
    // downloaded file must still be able to READ it — and the metadata beside it must
    // still be WRITABLE to record the resume position.
    try? fm.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: videoPath.path
    )

    let fileSize = (try? fm.attributesOfItem(atPath: videoPath.path)[.size] as? Int64) ?? 0

    // Save the item immediately with no poster; the async poster fetch below will update it.
    let item = DownloadedItem(
      id: itemId,
      title: info.title,
      year: info.year,
      videoPath: videoFilename,   // Store filename only — avoids stale absolute paths after app updates
      posterPath: nil,
      fileSize: fileSize,
      downloadedAt: Date(),
      durationSeconds: info.durationSeconds,
      ageLevel: info.ageLevel
    )

    // Read raw items from the metadata file to preserve filename-only storage invariant,
    // then insert the new item (which already uses filename-only videoPath).
    // THE DATA-LOSS SITE. This used to be `try?` → `rawItems = []` → insert → save, so a
    // manifest that failed to decode was replaced by a one-element array. Twenty downloads
    // became one and the .mp4 files orphaned on disk.
    //
    // Now: absent means genuinely empty and `[]` is right; unreadable means quarantine the
    // file and rebuild from the media actually present, so the new item joins the recovered
    // set instead of replacing everything.
    let rawItems: [DownloadedItem]
    switch loadManifest() {
    case .items(let decoded):
      rawItems = decoded
    case .absent:
      rawItems = []
    case .unreadable(let reason):
      rawItems = quarantineAndRebuildManifest(reason: reason)
    }
    // Guard against a duplicate id — a rebuild from disk will already contain this item if
    // its file landed before the manifest was rewritten.
    var updatedItems = rawItems.filter { $0.id != item.id }
    updatedItems.insert(item, at: 0)
    guard saveDownloadedItems(updatedItems) else {
      // The file landed but the manifest could not record it (a full disk, typically). Unlisted,
      // it would be invisible bytes nothing can play or delete: remove it and say why (TASK-971).
      try? fm.removeItem(at: videoPath)
      cachedDownloadedItems = nil
      recordSaveFailure(itemId: itemId, info: info, error: nil)
      return
    }
    cachedDownloadedItems = nil

    activeDownloads.removeValue(forKey: itemId)
    forgetProgress(itemId)
    pendingDownloadInfo.removeValue(forKey: itemId)
    // Done for good: no failed, paused or persisted in-flight trace of it may remain.
    clearFailure(itemId)
    pausedDownloads.removeValue(forKey: itemId)
    resumedFromData.remove(itemId)
    forgetDownload(for: itemId)

    // Download finished and is now playable offline — confirm with a success haptic.
    Haptics.play(.success)

    // Fetch poster image asynchronously and update the stored item once done.
    guard let posterURL = info.posterURL else { return }
    guard info.token != nil || tokenProvider != nil else {
      // Completed in a background relaunch, before the app could supply a credential: the
      // poster is fetched when the providers are wired (TASK-994), not silently skipped.
      deferredWork.posters[itemId] = posterURL
      persistDeferredWork()
      return
    }
    fetchPoster(itemId: itemId, posterURL: posterURL, token: info.token)
  }

  /// Downloads a finished item's poster and records it on the stored item. Best-effort: the
  /// title stays playable without one.
  private func fetchPoster(itemId: String, posterURL: URL, token: String?) {
    let dir = downloadsDirectory()
    let posterFilename = "\(itemId).poster.jpg"
    let posterDestination = dir.appendingPathComponent(posterFilename)

    Task {
      var req = URLRequest(url: posterURL)
      // info.token is nil after a relaunch (never persisted) — fall back to a live one.
      if let tok = token ?? tokenProvider?() {
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
      }
      if usesTunnelCookieProvider?() == true {
        req.setValue("type=tunnel", forHTTPHeaderField: "Cookie")
      }
      // AC-002-44: every request from the app names the active profile.
      ActiveProfileStore.shared.applyHeader(to: &req)

      do {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              !data.isEmpty else {
          let status = (response as? HTTPURLResponse)?.statusCode ?? -1
          log.debug("[DownloadManager] Poster fetch failed: HTTP \(status)")
          return
        }

        try data.write(to: posterDestination, options: .atomic)
        try? FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
          ofItemAtPath: posterDestination.path
        )

        // Update the persisted item with the poster path (filename only).
        // Read raw from the metadata file to preserve the filename-only videoPath invariant.
        await MainActor.run {
          let metaURL = self.downloadsMetadataFileURL
          guard let rawData = try? Data(contentsOf: metaURL),
                var rawItems = try? JSONDecoder().decode([DownloadedItem].self, from: rawData),
                let idx = rawItems.firstIndex(where: { $0.id == itemId }) else { return }
          // Set in place: a rebuilt value would drop any field it failed to list.
          rawItems[idx].posterPath = posterFilename
          self.saveDownloadedItems(rawItems)
          // Invalidate in-memory cache so next read resolves fresh from disk.
          self.cachedDownloadedItems = nil
        }
      } catch {
        // Poster fetch failed — item remains playable without a poster thumbnail.
      }
    }
  }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {

  /// Whether a finished transfer's HTTP status means the bytes on disk are the MEDIA and may
  /// be kept, as opposed to an error body that must be discarded.
  ///
  /// TASK-887 (1.3.6 P0): `URLSession` reports `didFinishDownloadingTo` for ANY completed
  /// response, 4xx and 5xx included — `error` is only set for transport failures. Without
  /// this check a 22-byte `{"error":"not_found"}` was moved to `{itemId}.mp4` and marked
  /// downloaded, so offline playback failed on a file the UI insisted was present.
  ///
  /// Extracted from the delegate method purely so the decision is directly testable — the
  /// delegate takes a live `URLSessionDownloadTask`, which cannot be constructed with a
  /// chosen status in a unit test. Behaviour is identical to the inline check it replaced.
  ///
  /// A `nil` status means the response was not an `HTTPURLResponse` at all (e.g. a `file://`
  /// transfer), which has no status to reject on — accepted, matching the original
  /// `if let httpStatus` shape.
  nonisolated static func shouldAcceptResponse(status: Int?) -> Bool {
    guard let status else { return true }
    return (200...299).contains(status)
  }

  nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    // URLSession calls delegates on the OperationQueue supplied at init (a background queue, NOT main).
    // We must hop to @MainActor for all state mutations — hence the Task { @MainActor in } pattern.
    // URLSession calls this delegate for ANY completed response, including a 4xx/5xx — it
    // only reports `error` for transport failures. Without a status check the error BODY
    // gets written to disk as the movie: a 22-byte `{"error":"not_found"}` stored as
    // {itemId}.mp4 and marked "downloaded", so offline playback fails on a file the UI
    // swears is present. Read the status BEFORE copying anything.
    let httpStatus = (downloadTask.response as? HTTPURLResponse)?.statusCode
    if !DownloadManager.shouldAcceptResponse(status: httpStatus), let httpStatus {
      // The body names the cause ({"error": code}); it is only readable during this call.
      let errorCode = DownloadManager.errorCode(fromErrorBodyAt: location)
      Task { @MainActor in
        guard let itemId = owner(of: downloadTask) else { return }
        downloadTasks.removeValue(forKey: downloadTask)
        let sentProfileID = downloadTask.originalRequest?.value(forHTTPHeaderField: ActiveProfileStore.headerName)
        recordHTTPFailure(itemId: itemId, status: httpStatus, errorCode: errorCode, sentProfileID: sentProfileID)
      }
      return
    }

    // The temp file at `location` is only valid for the duration of this synchronous call, so
    // it is moved to a stable path before returning. A move, not a copy (TASK-971): a copy needs
    // the file's whole size free a second time, which is exactly what a nearly full device
    // lacks, and the same volume makes the move a rename.
    let stableCopy = FileManager.default.temporaryDirectory
      .appendingPathComponent("dsreel_dl_\(UUID().uuidString).tmp")
    let preserveError: Error?
    do {
      try FileManager.default.moveItem(at: location, to: stableCopy)
      preserveError = nil
    } catch {
      try? FileManager.default.removeItem(at: stableCopy)
      preserveError = error
    }
    let taskID = downloadTask.taskIdentifier
    Task { @MainActor in
      // The map, or the label the task carries when a previous process started it (TASK-947),
      // or the task a pause stopped with nothing to resume just as it finished (TASK-994).
      let pauseStopped = stoppedByPauseWithoutData.removeValue(forKey: taskID)
      guard let itemId = owner(of: downloadTask) ?? pauseStopped else {
        try? FileManager.default.removeItem(at: stableCopy)
        return
      }
      downloadTasks.removeValue(forKey: downloadTask)
      lastProgressUpdate.removeValue(forKey: itemId)
      if let preserveError {
        // The bytes are gone with the temp file. The row must leave Downloading, not sit at
        // 100% for good: didCompleteWithError reports success, so nothing else would end it.
        recordSaveFailure(itemId: itemId, info: finishingInfo(for: itemId), error: preserveError)
        return
      }
      // The transfer is done with the session's stream URL — release it now instead of
      // leaving the transcode and its temp dir pinned until the server's idle reaper runs.
      releasePlaybackSession(for: itemId)
      completeDownload(itemId: itemId, tempURL: stableCopy)
    }
  }

  /// Re-resolve a fresh playback session for an item, then start the download against it.
  ///
  /// Used by resume-after-relaunch and by retry. Both previously reused the stored URL, whose
  /// session no longer exists — the request 404s, and before the status check below landed,
  /// the 404 body was written to disk as the movie.
  private func restartWithFreshURL(
    itemId: String,
    info: DownloadInfo
  ) {
    guard let urlResolver else {
      // No resolver wired (should not happen in the app; possible in tests). Surface it
      // rather than starting a download that is guaranteed to fail.
      raiseFailure(FailedDownload(
        id: itemId, title: info.title, videoURL: info.videoURL,
        posterURL: info.posterURL, token: nil, year: info.year,
        durationSeconds: info.durationSeconds, ageLevel: info.ageLevel,
        message: "This download can't be restarted right now. Try again."
      ))
      return
    }
    Task { @MainActor in
      guard let resolved = await urlResolver(itemId) else {
        raiseFailure(FailedDownload(
          id: itemId, title: info.title, videoURL: info.videoURL,
          posterURL: info.posterURL, token: nil, year: info.year,
          durationSeconds: info.durationSeconds, ageLevel: info.ageLevel,
          message: "Couldn't reach the server to restart this download. Try again."
        ))
        return
      }
      startDownload(
        itemId: itemId,
        title: info.title,
        year: info.year,
        videoURL: resolved.url,
        posterURL: info.posterURL,
        // info.token is nil after a relaunch — the credential is deliberately not persisted.
        token: info.token ?? tokenProvider?(),
        durationSeconds: info.durationSeconds,
        ageLevel: info.ageLevel,
        playbackSessionID: resolved.sessionID
      )
    }
  }

  /// Release the playback session backing a download, exactly once. Safe to call from every
  /// terminal path (success, HTTP failure, transport failure, cancel) — the entry is removed
  /// as it is read, so a second call is a no-op.
  private func releasePlaybackSession(for itemId: String) {
    guard let sessionID = downloadSessionIDs.removeValue(forKey: itemId) else { return }
    guard let releaseSessionProvider else {
      // A background relaunch finishes transfers before the scene wires its providers
      // (TASK-994). Dropping the id would pin the server's transcode until its idle reaper
      // runs, so it is kept and released by `flushDeferredWork()` once the app is up.
      deferredWork.sessionReleases.append(sessionID)
      persistDeferredWork()
      return
    }
    releaseSessionProvider(sessionID)
  }

  /// Runs the work a background relaunch could not: releases the playback sessions of transfers
  /// that finished, and fetches the posters of downloads that completed without a credential
  /// (TASK-994). Called by the app once the providers are wired; a no-op until they are.
  func flushDeferredWork() {
    guard releaseSessionProvider != nil, tokenProvider != nil else { return }
    let work = deferredWork
    guard !work.isEmpty else { return }
    deferredWork = DeferredWork()
    persistDeferredWork()
    for sessionID in work.sessionReleases { releaseSessionProvider?(sessionID) }
    for (itemId, posterURL) in work.posters where isDownloaded(itemId: itemId) {
      fetchPoster(itemId: itemId, posterURL: posterURL, token: nil)
    }
  }

  /// The server's error code from a rejected transfer's body (`{"error": code}`), or nil when
  /// there is no readable JSON body. Reads at most 4 KB: an error body is a few dozen bytes,
  /// and a misbehaving server must not make this read a whole file into memory.
  nonisolated static func errorCode(fromErrorBodyAt location: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: location) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 4096), !data.isEmpty else { return nil }
    // JSONSerialization, not APIErrorResponse: that type is main-actor isolated and this runs
    // on the session's delegate queue.
    let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    return body?["error"] as? String
  }

  /// The Failed-row message for a transfer the server answered with `status` (and, when the
  /// body had one, `errorCode`).
  ///
  /// TASK-961 (FR-033): only a session failure says "session expired". A 403 is NOT a session
  /// failure by default: the stream route answers 403 `content_restricted` for a title above the
  /// profile's age rating and 403 `unknown_profile` for a deleted profile, neither of which
  /// signing in again can fix. A 403 with a code reads that code's own sentence (one home:
  /// `APIError.userMessage`); the session test is `APIError.isAuthFailure`, also one home.
  static func httpFailureMessage(status: Int, errorCode: String?) -> String {
    if APIError.server(errorCode ?? "", status: status).isAuthFailure {
      return "Your session expired. Sign in again, then retry the download."
    }
    switch status {
    case 403 where errorCode != nil:
      return APIError.server(errorCode ?? "", status: status).userMessage
    case 404, 410:
      return "The server couldn't provide this video. Try the download again."
    case 500...599:
      return "The server had a problem preparing this video. Try again shortly."
    default:
      return "The download failed (HTTP \(status)). Try again."
    }
  }

  /// Surface an HTTP-level download failure through the same path as a transport failure,
  /// so the Downloads list shows a real "failed — retry" row instead of a bogus success.
  ///
  /// The message names the actual cause (`httpFailureMessage`). None is marked permanent: a
  /// retry re-resolves a fresh session. A 404 means the stream URL no longer resolves, which is
  /// what happens when the playback session backing it was already released. A 403
  /// `unknown_profile` also takes the profile-gone path every other request takes (FR-206):
  /// the app goes back to the picker. Internal, not private, so tests can drive it directly:
  /// the delegate takes a live download task, which a unit test cannot build with a status.
  func recordHTTPFailure(itemId: String, status: Int, errorCode: String? = nil, sentProfileID: String? = nil) {
    activeDownloads.removeValue(forKey: itemId)
    forgetProgress(itemId)
    lastProgressUpdate.removeValue(forKey: itemId)

    // Resumed from data and the stream is gone (TASK-947): the resume data replayed a session
    // the server has since reaped (idle reaper). Not a failure: start over on a fresh session.
    // The old session is already gone server-side, so there is nothing to release.
    if resumedFromData.remove(itemId) != nil, status == 404 || status == 410,
       let info = pendingDownloadInfo.removeValue(forKey: itemId) {
      downloadSessionIDs.removeValue(forKey: itemId)
      forgetDownload(for: itemId)
      log.info("download \(itemId): resumed session gone (HTTP \(status)), restarting on a fresh one")
      restartWithFreshURL(itemId: itemId, info: info)
      return
    }

    releasePlaybackSession(for: itemId)
    let message = Self.httpFailureMessage(status: status, errorCode: errorCode)
    if errorCode == "unknown_profile" {
      NotificationCenter.default.post(name: .activeProfileRejected, object: sentProfileID)
    }

    let info = pendingDownloadInfo.removeValue(forKey: itemId) ?? finishingInfo(for: itemId)
    raiseFailure(failure(itemId: itemId, info: info, message: message))
    forgetDownload(for: itemId)
    log.error("download \(itemId) failed with HTTP \(status) \(errorCode ?? "no error code") — no file written")
  }

  nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    let writtenSnapshot = totalBytesWritten
    let expectedSnapshot = totalBytesExpectedToWrite
    Task { @MainActor in
      guard let itemId = downloadTasks[downloadTask] else { return }
      let now = Date()
      if let last = lastProgressUpdate[itemId], now.timeIntervalSince(last) < 0.1 { return }
      lastProgressUpdate[itemId] = now
      let progress = expectedSnapshot > 0 ? Double(writtenSnapshot) / Double(expectedSnapshot) : 0
      downloadProgress[itemId] = progress
      downloadBytes[itemId] = TransferBytes(written: writtenSnapshot, expected: expectedSnapshot)
    }
  }

  nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    // Success was already settled by didFinishDownloadingTo (or its HTTP-status branch).
    guard let downloadTask = task as? URLSessionDownloadTask, let error else { return }
    // Read everything off the error before crossing into the main actor.
    let nsError = error as NSError
    let code = nsError.code
    // Kept whenever the system hands it over, not only on an explicit pause: a Wi-Fi blip
    // arrives as .networkConnectionLost WITH resume data, and a force-quit arrives on the next
    // launch as a cancel with resume data.
    let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    let cancelReason = nsError.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int
    let taskID = downloadTask.taskIdentifier
    Task { @MainActor in
      // The task's last callback: a late delivery, had there been one, has already come.
      stoppedByPauseWithoutData.removeValue(forKey: taskID)
      // The map, or the task's label when a previous process started it (TASK-947).
      guard let itemId = owner(of: downloadTask) else { return }
      // A pause in progress records its own stop with the resume data it was handed.
      guard !pausing.contains(itemId) else { return }
      recordStop(itemId: itemId, task: downloadTask, errorCode: code,
                 resumeData: resumeData, cancelReason: cancelReason)
    }
  }

  // FIX-7: Called by URLSession after all background events for a session are delivered.
  // Invoke the stored completion handler so iOS knows the app has finished processing,
  // allowing the system to take a new snapshot and release the background runtime extension.
  nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    Task { @MainActor in
      backgroundCompletionHandler?()
      backgroundCompletionHandler = nil
    }
  }
}
