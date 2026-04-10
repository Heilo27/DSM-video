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

  #if canImport(UIKit) || canImport(AppKit)
  @State private var image: Image?
  @State private var isLoading: Bool = false
  @State private var didFail: Bool = false
  #endif

  var body: some View {
    #if canImport(UIKit)
    uiKitBody
    #elseif canImport(AppKit)
    macOSBody
    #endif
  }

  #if canImport(UIKit)
  private var uiKitBody: some View {
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
          .task { await loadIfNeeded() }
      }
    }
  }

  private func loadIfNeeded() async {
    guard let url, !isLoading, image == nil else { return }

    // Single actor turn: cache hit, join in-flight, or signal new fetch needed.
    // This eliminates the TOCTOU window that existed between two separate awaits.
    let outcome = await ImageCache.shared.fetchOrJoin(for: url)

    if let cached = outcome.cached {
      image = Image(uiImage: cached)
      return
    }

    if let existingTask = outcome.task {
      // Join in-flight — someone else is already fetching this URL
      if let result = await existingTask.value {
        image = Image(uiImage: result)
      } else {
        didFail = true
      }
      return
    }

    // outcome.isNew == true: we are responsible for the fetch
    isLoading = true

    let fetchTask = Task<UIImage?, Never> {
      var req = URLRequest(url: url, timeoutInterval: 15)

      // Check if URL already has _sid parameter (Video Station) or use Bearer token (REST API)
      if url.absoluteString.contains("_sid=") {
        // Video Station: session ID already in URL, no header needed
      } else if let token = token {
        // REST API: use Bearer token
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      }

      do {
        let (data, response) = try await ImageSession.shared.data(for: req)

        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
          return nil
        }

        if let uiImage = UIImage(data: data) {
          await ImageCache.shared.setImage(uiImage, for: url)
          return uiImage
        }
        return nil
      } catch {
        return nil
      }
    }

    // Register before awaiting so any concurrent caller sees the task immediately
    await ImageCache.shared.registerTask(fetchTask, for: url)

    let result = await fetchTask.value
    await ImageCache.shared.clearInFlightTask(for: url)

    isLoading = false

    if let uiImage = result {
      image = Image(uiImage: uiImage)
    } else {
      didFail = true
    }
  }
  #endif

  // MARK: - macOS (AppKit-backed, authenticated fetch)

  #if canImport(AppKit)
  /// On macOS, manually fetch with auth headers — AsyncImage(url:) cannot pass custom headers
  /// and will receive HTTP 401 from Video Station / REST endpoints that require auth.
  private var macOSBody: some View {
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
          .task { await loadIfNeeded() }
      }
    }
  }

  private func loadIfNeeded() async {
    guard let url, !isLoading, image == nil else { return }

    let outcome = await MacImageCache.shared.fetchOrJoin(for: url)

    if let cached = outcome.cached {
      image = Image(nsImage: cached)
      return
    }

    if let existingTask = outcome.task {
      if let result = await existingTask.value {
        image = Image(nsImage: result)
      } else {
        didFail = true
      }
      return
    }

    // outcome.isNew == true: we are responsible for the fetch
    isLoading = true

    let fetchTask = Task<NSImage?, Never> {
      var req = URLRequest(url: url, timeoutInterval: 15)
      if url.absoluteString.contains("_sid=") {
        // Video Station: session ID already in URL
      } else if let token {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      }
      do {
        let (data, response) = try await ImageSession.shared.data(for: req)
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode != 200 {
          return nil
        }
        return NSImage(data: data)
      } catch {
        return nil
      }
    }

    await MacImageCache.shared.registerTask(fetchTask, for: url)

    let result = await fetchTask.value
    if let nsImage = result {
      await MacImageCache.shared.setImage(nsImage, for: url)
    }
    await MacImageCache.shared.clearInFlightTask(for: url)

    isLoading = false

    if let nsImage = result {
      image = Image(nsImage: nsImage)
    } else {
      didFail = true
    }
  }
  #endif
}

