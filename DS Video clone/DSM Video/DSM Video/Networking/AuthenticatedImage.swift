import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Shared Image URLSession (disk-cached)

/// Dedicated URLSession for image fetches with 512MB disk cache.
/// Respects Cache-Control headers from the server so TMDb posters are cached for 7 days.
private enum ImageSession {
  static let shared: URLSession = {
    let cache = URLCache(
      memoryCapacity: 50 * 1024 * 1024,   // 50MB memory
      diskCapacity: 512 * 1024 * 1024,    // 512MB disk
      directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("com.dsm.imagecache")
    )
    let config = URLSessionConfiguration.default
    config.urlCache = cache
    config.requestCachePolicy = .returnCacheDataElseLoad
    return URLSession(configuration: config)
  }()
}

/// Backoff before image-fetch retry N (0-based): ~0.3s, then ~0.9s. Short on purpose —
/// a poster the user is looking at right now is worthless if it arrives ten seconds
/// late. Platform-neutral: both the UIKit and AppKit fetch paths use it.
private func backoffNanos(_ attempt: Int) -> UInt64 {
  UInt64(300_000_000.0 * pow(3.0, Double(attempt)))
}

// MARK: - Image Cache (UIKit platforms only)

#if canImport(UIKit)
/// Shared image cache to prevent re-downloading images
private actor ImageCache {
  static let shared = ImageCache()

  private let cache = NSCache<NSURL, UIImage>()
  private var inFlightTasks: [URL: Task<UIImage?, Never>] = [:]

  init() {
    // Limit cache to ~100MB worth of images
    cache.totalCostLimit = 100 * 1024 * 1024
    cache.countLimit = 200
  }

  func image(for url: URL) -> UIImage? {
    cache.object(forKey: url as NSURL)
  }

  func setImage(_ image: UIImage, for url: URL) {
    let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
    cache.setObject(image, forKey: url as NSURL, cost: cost)
  }

  /// Removes the in-flight task when complete
  func clearInFlightTask(for url: URL) {
    inFlightTasks[url] = nil
  }

  /// Atomically checks cache, joins an in-flight task, or signals the caller to create one.
  /// All three checks happen in a single actor turn — no TOCTOU window.
  ///
  /// Returns:
  ///   - `(cached: image, task: nil, isNew: false)`  — cache hit, use image directly
  ///   - `(cached: nil, task: existing, isNew: false)` — join the in-flight task
  ///   - `(cached: nil, task: nil, isNew: true)`      — caller must create + register task
  func fetchOrJoin(for url: URL) -> (cached: UIImage?, task: Task<UIImage?, Never>?, isNew: Bool) {
    if let cached = cache.object(forKey: url as NSURL) {
      return (cached: cached, task: nil, isNew: false)
    }
    if let existing = inFlightTasks[url] {
      return (cached: nil, task: existing, isNew: false)
    }
    return (cached: nil, task: nil, isNew: true)
  }

  /// Registers a newly created fetch task so subsequent callers can join it.
  func registerTask(_ task: Task<UIImage?, Never>, for url: URL) {
    inFlightTasks[url] = task
  }

  /// True when this URL is already cached or being fetched — i.e. prefetching it
  /// would be wasted work.
  func isWarm(_ url: URL) -> Bool {
    cache.object(forKey: url as NSURL) != nil || inFlightTasks[url] != nil
  }
}

// MARK: - Prefetch

/// Warms the image cache for posters about to scroll into view, so a rail's first
/// cards don't start from the grey placeholder on every cold scroll.
///
/// Deliberately fire-and-forget and best-effort: prefetch must never delay or
/// out-prioritise a visible cell's own fetch. It shares ImageCache's in-flight
/// registry, so a prefetch already running for a URL is simply joined by the real
/// load when the cell appears — never duplicated.
enum ImagePrefetcher {
  /// Bounded so a fast fling can't queue hundreds of concurrent requests at a NAS
  /// that is also transcoding. One screenful of lookahead is the useful window.
  private static let maxPerBatch = 12

  static func prefetch(urls: [URL?], token: String?, usesTunnelCookie: Bool) {
    #if canImport(UIKit)
    let targets = urls.compactMap { $0 }.prefix(maxPerBatch)
    guard !targets.isEmpty else { return }
    Task.detached(priority: .utility) {
      for url in targets {
        if await ImageCache.shared.isWarm(url) { continue }
        var req = URLRequest(url: url, timeoutInterval: 15)
        if url.absoluteString.contains("_sid=") {
          // Video Station: session ID already in the URL.
        } else if let token {
          req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if usesTunnelCookie {
          req.setValue("type=tunnel", forHTTPHeaderField: "Cookie")
        }
        // No retry here on purpose: a prefetch that misses costs nothing, and the
        // visible-cell load will retry properly when the card actually appears.
        guard let (data, response) = try? await ImageSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: data) else { continue }
        await ImageCache.shared.setImage(image, for: url)
      }
    }
    #endif
  }
}
#endif

// MARK: - Image Cache (AppKit platforms only)

#if canImport(AppKit)
private actor MacImageCache {
  static let shared = MacImageCache()

  private let cache = NSCache<NSURL, NSImage>()
  private var inFlightTasks: [URL: Task<NSImage?, Never>] = [:]

  init() {
    cache.totalCostLimit = 100 * 1024 * 1024
    cache.countLimit = 200
  }

  func fetchOrJoin(for url: URL) -> (cached: NSImage?, task: Task<NSImage?, Never>?, isNew: Bool) {
    if let cached = cache.object(forKey: url as NSURL) {
      return (cached, nil, false)
    }
    if let existing = inFlightTasks[url] {
      return (nil, existing, false)
    }
    return (nil, nil, true)
  }

  func registerTask(_ task: Task<NSImage?, Never>, for url: URL) {
    inFlightTasks[url] = task
  }

  func setImage(_ image: NSImage, for url: URL) {
    // Approximate cost in bytes so totalCostLimit is actually enforced
    let cost = image.representations.reduce(0) { acc, rep in
      acc + rep.pixelsWide * rep.pixelsHigh * 4
    }
    cache.setObject(image, forKey: url as NSURL, cost: max(cost, 1))
  }

  func clearInFlightTask(for url: URL) {
    inFlightTasks[url] = nil
  }
}
#endif

// MARK: - AuthenticatedImage

struct AuthenticatedImage: View {
  let url: URL?
  let token: String?
  // FIX-4: When true, adds Cookie: type=tunnel for QuickConnect relay image requests.
  var usesTunnelCookie: Bool = false

  #if canImport(UIKit) || canImport(AppKit)
  @State private var image: Image?
  @State private var isLoading: Bool = false
  @State private var didFail: Bool = false
  // Monotonic load generation. Captured at the start of each loadIfNeeded() and
  // re-checked before every @State write, so a fetch that completes AFTER its cell
  // was recycled to a different URL (fast flinging) is discarded instead of writing
  // a stale poster into the reused cell.
  @State private var loadGeneration: Int = 0
  // The loadKey the currently-displayed `image` was fetched for. When loadKey changes
  // (e.g. baseURL flips LAN→WAN on reconnect, or the token refreshes — neither of which
  // changes the actual poster), we keep showing this image and refetch in the
  // background, swapping only when the new fetch succeeds. This prevents the
  // "poster vanishes a few seconds after launch" flash and stops a transient
  // refetch failure from leaving a permanently-blank cell.
  @State private var loadedKey: String?
  // The loadKey of the fetch currently in flight, or nil when idle. Replaces a bare
  // `isLoading` bool as the re-entry guard: a bool latches true forever if the .task
  // is cancelled mid-fetch (cell recycled / row re-rendered), and every subsequent
  // .task then bails on `!isLoading` — the cell stays grey until it is scrolled off
  // and back, which destroys the @State and clears the flag. Keying the guard on the
  // in-flight key means a re-fired task for the SAME key still no-ops, but a task for
  // a different key (or after a reset) always proceeds.
  @State private var inFlightKey: String?
  #endif

  // Composite identity for the load task: a token refresh keeps the same URL, so a
  // task keyed on url alone would not re-fire and a cell that hit a 401 before the
  // refresh would stay stuck on the broken-image glyph. Keying on url + token makes
  // the load restart when either changes.
  private var loadKey: String { "\(url?.absoluteString ?? "")|\(token ?? "")" }

  var body: some View {
    #if canImport(UIKit)
    uiKitBody
    #elseif canImport(AppKit)
    macOSBody
    #endif
  }

  #if canImport(UIKit)
  private var uiKitBody: some View {
    // The .task / .onChange modifiers MUST live on the outer Group, NOT inside the
    // `else` (placeholder) branch. In a LazyVGrid, cells are recycled as they scroll;
    // when a recycled cell lands on the `if let image` branch with a stale or nil
    // image, a .task attached only to the placeholder never re-fires — the cell shows
    // blank (and its NavigationLink loses a clean hit-test) until you scroll past it
    // and force a full re-layout. Attaching the loader to the Group makes it fire for
    // every cell state, fixing the "black, untappable mid-scroll, reappears after you
    // scroll past" bug.
    Group {
      if let image {
        image
          .resizable()
      } else {
        Rectangle()
          .fill(.white.opacity(0.12))
          .overlay {
            if isLoading {
              ProgressView()
                .tint(.white)
            } else if didFail || url == nil {
              Image(systemName: "photo")
                .font(.title)
                .foregroundStyle(.white.opacity(0.3))
                .accessibilityLabel("Image unavailable")
            }
          }
      }
    }
    .task(id: loadKey) {
      // Keyed on url + token: SwiftUI cancels and restarts this task whenever the
      // cell is reused with a different URL OR the auth token changes (e.g. after a
      // refresh), so a recycled cell always loads its own poster and a cell that hit
      // a 401 retries once the new token is available.
      await loadIfNeeded()

      // Cancellation unwinds through here without running the completion path in
      // loadIfNeeded(), so clear the in-flight marker explicitly. Without this the
      // guard stays latched and every later .task for this cell no-ops — the
      // "card goes grey a few seconds in and only comes back after scrolling
      // off and back" bug.
      if Task.isCancelled, inFlightKey == loadKey {
        inFlightKey = nil
        isLoading = false
      }
    }
    .onChange(of: loadKey) { _, _ in
      // URL or token changed. Do NOT blank `image` — during a LAN→WAN reconnect the
      // baseURL (and token) change but the poster is identical, so clearing here just
      // flashes the cell empty and, if the refetch transiently fails, strands it blank.
      // Instead clear only the failure/loading flags and let loadIfNeeded() refetch;
      // it swaps `image` in place once the new key resolves. `loadedKey != loadKey`
      // is what lets it run despite a non-nil `image`.
      didFail = false
      isLoading = false
    }
  }

  private func loadIfNeeded() async {
    // Refetch when there's no image yet OR the current image belongs to a stale key
    // (recycled cell / reconnect). `loadedKey == loadKey` with a non-nil image means
    // we're already showing the right poster — nothing to do.
    // Re-entry guard keyed on the in-flight load, not a bare bool: a fetch already
    // running for THIS key is left alone, but anything else proceeds. A cancelled
    // task can no longer strand the cell (see inFlightKey).
    guard let url, inFlightKey != loadKey, (image == nil || loadedKey != loadKey) else { return }
    let keyAtStart = loadKey
    inFlightKey = keyAtStart
    // Clears on every exit path — success, failure, stale-generation bail, or a
    // cancellation that unwinds mid-await — so the guard can never latch.
    defer { if inFlightKey == keyAtStart { inFlightKey = nil } }

    // Capture this load's generation. Every @State write below is gated on it still
    // being current, so a completion that lands after the cell was recycled to a
    // different URL/token is dropped instead of writing a stale image.
    loadGeneration += 1
    let generation = loadGeneration
    let isCurrent = { generation == loadGeneration }

    // Single actor turn: cache hit, join in-flight, or signal new fetch needed.
    // This eliminates the TOCTOU window that existed between two separate awaits.
    let outcome = await ImageCache.shared.fetchOrJoin(for: url)

    if let cached = outcome.cached {
      if isCurrent() { image = Image(uiImage: cached); loadedKey = keyAtStart }
      return
    }

    if let existingTask = outcome.task {
      // Join in-flight — someone else is already fetching this URL
      let result = await existingTask.value
      guard isCurrent() else { return }
      if let result { image = Image(uiImage: result); loadedKey = keyAtStart }
      else if image == nil { didFail = true }  // don't hide a good poster on a reconnect refetch miss
      return
    }

    // outcome.isNew == true: we are responsible for the fetch
    isLoading = true

    let usesTunnel = usesTunnelCookie
    let fetchTask = Task<UIImage?, Never> {
      var req = URLRequest(url: url, timeoutInterval: 15)

      // Check if URL already has _sid parameter (Video Station) or use Bearer token (REST API)
      if url.absoluteString.contains("_sid=") {
        // Video Station: session ID already in URL, no header needed
      } else if let token = token {
        // REST API: use Bearer token
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      }
      // FIX-4: QuickConnect relay requires Cookie: type=tunnel on every request.
      if usesTunnel {
        req.setValue("type=tunnel", forHTTPHeaderField: "Cookie")
      }

      // Retry transient failures. Previously a single dropped packet or a NAS busy
      // for one second greyed the card permanently — nothing retried until the token
      // or baseURL changed. Only network errors and 5xx/429 are retried; a 404 poster
      // or a 401 fails immediately (retrying those is pure latency, and the token
      // refresh path already re-fires the load via loadKey).
      for attempt in 0..<3 {
        if Task.isCancelled { return nil }
        do {
          let (data, response) = try await ImageSession.shared.data(for: req)

          if let httpResponse = response as? HTTPURLResponse,
             httpResponse.statusCode != 200 {
            let code = httpResponse.statusCode
            let transient = code == 429 || (500...599).contains(code)
            if transient, attempt < 2 {
              try? await Task.sleep(nanoseconds: backoffNanos(attempt))
              continue
            }
            return nil
          }

          if let uiImage = UIImage(data: data) {
            await ImageCache.shared.setImage(uiImage, for: url)
            return uiImage
          }
          // 200 with undecodable bytes — a truncated response is worth one more try.
          if attempt < 2 {
            try? await Task.sleep(nanoseconds: backoffNanos(attempt))
            continue
          }
          return nil
        } catch is CancellationError {
          return nil
        } catch {
          // URLError (timeout, connection lost, DNS) — the transient case worth retrying.
          if attempt < 2 {
            try? await Task.sleep(nanoseconds: backoffNanos(attempt))
            continue
          }
          return nil
        }
      }
      return nil
    }

    // Register before awaiting so any concurrent caller sees the task immediately
    await ImageCache.shared.registerTask(fetchTask, for: url)

    // The clear MUST survive cancellation. This `.task` is cancelled whenever the cell
    // scrolls away — the common case — and the await below then throws straight past a
    // plain trailing call, leaving the entry in inFlightTasks forever. fetchOrJoin then
    // hands that dead task to every future caller and isWarm reports true, so the
    // prefetcher skips the URL permanently: the cell stays grey for the rest of the run.
    defer { Task { await ImageCache.shared.clearInFlightTask(for: url) } }

    let result = await fetchTask.value

    // Clear the spinner before the staleness check, not after. Gating this on
    // isCurrent() left a superseded fetch spinning forever on a cell that had moved
    // on — the spinner is this cell's own UI state and is always wrong once the
    // fetch it belongs to has finished.
    isLoading = false

    // Drop the result if this cell was recycled to a different URL/token while the
    // fetch was in flight — the image is cached for whoever needs it, but we must not
    // write it into a cell that has since moved on.
    guard isCurrent() else { return }

    if let uiImage = result {
      image = Image(uiImage: uiImage)
      loadedKey = keyAtStart
    } else if image == nil {
      // Only surface failure if we have nothing to show. A reconnect refetch that
      // misses must leave the existing poster in place, not blank the cell.
      didFail = true
    }
  }
  #endif

  // MARK: - macOS (AppKit-backed, authenticated fetch)

  #if canImport(AppKit)
  /// On macOS, manually fetch with auth headers — AsyncImage(url:) cannot pass custom headers
  /// and will receive HTTP 401 from Video Station / REST endpoints that require auth.
  private var macOSBody: some View {
    // .task / .onChange on the outer Group (not the placeholder branch) so a recycled
    // cell always loads its own image. See the UIKit body for the full rationale.
    Group {
      if let image {
        image
          .resizable()
      } else {
        Rectangle()
          .fill(.white.opacity(0.12))
          .overlay {
            if isLoading {
              ProgressView()
                .tint(.white)
            } else if didFail || url == nil {
              Image(systemName: "photo")
                .font(.title)
                .foregroundStyle(.white.opacity(0.3))
                .accessibilityLabel("Image unavailable")
            }
          }
      }
    }
    .task(id: loadKey) {
      await loadIfNeeded()

      // See the UIKit body: a cancelled task must clear the in-flight marker itself,
      // or the guard latches and the cell stays grey until it's recycled.
      if Task.isCancelled, inFlightKey == loadKey {
        inFlightKey = nil
        isLoading = false
      }
    }
    .onChange(of: loadKey) { _, _ in
      // See the UIKit body: don't blank `image` on a key change (LAN→WAN reconnect
      // keeps the same poster) — just clear the flags and let loadIfNeeded() swap in place.
      didFail = false
      isLoading = false
    }
  }

  private func loadIfNeeded() async {
    // See the UIKit body: guard on the in-flight key, not a latching bool.
    guard let url, inFlightKey != loadKey, (image == nil || loadedKey != loadKey) else { return }
    let keyAtStart = loadKey
    inFlightKey = keyAtStart
    defer { if inFlightKey == keyAtStart { inFlightKey = nil } }

    // See the UIKit body: gate every @State write on this generation so a stale
    // completion (cell recycled mid-fetch) is dropped instead of writing a wrong image.
    loadGeneration += 1
    let generation = loadGeneration
    let isCurrent = { generation == loadGeneration }

    let outcome = await MacImageCache.shared.fetchOrJoin(for: url)

    if let cached = outcome.cached {
      if isCurrent() { image = Image(nsImage: cached); loadedKey = keyAtStart }
      return
    }

    if let existingTask = outcome.task {
      let result = await existingTask.value
      guard isCurrent() else { return }
      if let result { image = Image(nsImage: result); loadedKey = keyAtStart }
      else if image == nil { didFail = true }
      return
    }

    // outcome.isNew == true: we are responsible for the fetch
    isLoading = true

    let usesTunnel = usesTunnelCookie
    let fetchTask = Task<NSImage?, Never> {
      var req = URLRequest(url: url, timeoutInterval: 15)
      if url.absoluteString.contains("_sid=") {
        // Video Station: session ID already in URL
      } else if let token {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      }
      // FIX-4: QuickConnect relay requires Cookie: type=tunnel on every request.
      if usesTunnel {
        req.setValue("type=tunnel", forHTTPHeaderField: "Cookie")
      }
      // See the UIKit body: retry transient failures only (network error, 5xx, 429).
      for attempt in 0..<3 {
        if Task.isCancelled { return nil }
        do {
          let (data, response) = try await ImageSession.shared.data(for: req)
          if let httpResponse = response as? HTTPURLResponse,
             httpResponse.statusCode != 200 {
            let code = httpResponse.statusCode
            let transient = code == 429 || (500...599).contains(code)
            if transient, attempt < 2 {
              try? await Task.sleep(nanoseconds: backoffNanos(attempt))
              continue
            }
            return nil
          }
          if let img = NSImage(data: data) { return img }
          if attempt < 2 {
            try? await Task.sleep(nanoseconds: backoffNanos(attempt))
            continue
          }
          return nil
        } catch is CancellationError {
          return nil
        } catch {
          if attempt < 2 {
            try? await Task.sleep(nanoseconds: backoffNanos(attempt))
            continue
          }
          return nil
        }
      }
      return nil
    }

    await MacImageCache.shared.registerTask(fetchTask, for: url)

    // Cancellation-safe: see the UIKit body. Without the defer, a cell scrolling away
    // mid-fetch strands the entry in inFlightTasks permanently.
    defer { Task { await MacImageCache.shared.clearInFlightTask(for: url) } }

    // Cache INSIDE the task, so an image that was fully downloaded is kept even if this
    // view's task is cancelled while suspended on the await below — otherwise the work
    // is thrown away and the next viewer re-downloads it.
    let result = await fetchTask.value
    if let nsImage = result {
      await MacImageCache.shared.setImage(nsImage, for: url)
    }

    // See the UIKit body: clear the spinner before the staleness check, never after.
    isLoading = false

    guard isCurrent() else { return }

    if let nsImage = result {
      image = Image(nsImage: nsImage)
      loadedKey = keyAtStart
    } else if image == nil {
      didFail = true
    }
  }
  #endif
}

