import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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

// MARK: - AuthenticatedImage

struct AuthenticatedImage: View {
  let url: URL?
  let token: String?

  #if canImport(UIKit)
  @State private var image: Image?
  @State private var isLoading: Bool = false
  @State private var didFail: Bool = false
  #endif

  var body: some View {
    #if canImport(UIKit)
    uiKitBody
    #else
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
      var req = URLRequest(url: url)

      // Check if URL already has _sid parameter (Video Station) or use Bearer token (REST API)
      if url.absoluteString.contains("_sid=") {
        // Video Station: session ID already in URL, no header needed
      } else if let token = token {
        // REST API: use Bearer token
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      }

      do {
        let (data, response) = try await URLSession.shared.data(for: req)

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

  // MARK: - macOS fallback (no UIKit, no cache)

  #if !canImport(UIKit)
  /// On macOS, fall back to AsyncImage which handles auth headers via URLSession.
  /// No in-memory cache — macOS usage is secondary and URL-session-level caching applies.
  private var macOSBody: some View {
    Group {
      if let url {
        AsyncImage(url: url) { phase in
          switch phase {
          case .empty:
            Rectangle()
              .fill(.white.opacity(0.12))
              .overlay {
                ProgressView()
                  .tint(.white)
              }
          case .success(let loadedImage):
            loadedImage
              .resizable()
          case .failure:
            Rectangle()
              .fill(.white.opacity(0.12))
              .overlay {
                Image(systemName: "photo")
                  .font(.title)
                  .foregroundStyle(.white.opacity(0.3))
                  .accessibilityLabel("Image unavailable")
              }
          @unknown default:
            Rectangle()
              .fill(.white.opacity(0.12))
          }
        }
      } else {
        Rectangle()
          .fill(.white.opacity(0.12))
          .overlay {
            Image(systemName: "photo")
              .font(.title)
              .foregroundStyle(.white.opacity(0.3))
              .accessibilityLabel("Image unavailable")
          }
      }
    }
  }
  #endif
}
