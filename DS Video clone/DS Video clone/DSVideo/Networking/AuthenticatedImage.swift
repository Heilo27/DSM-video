import SwiftUI
import UIKit

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
    let cost = image.jpegData(compressionQuality: 1.0)?.count ?? 0
    cache.setObject(image, forKey: url as NSURL, cost: cost)
  }

  /// Returns an existing in-flight task for this URL, or nil if none exists
  func inFlightTask(for url: URL) -> Task<UIImage?, Never>? {
    inFlightTasks[url]
  }

  /// Registers an in-flight task for deduplication
  func setInFlightTask(_ task: Task<UIImage?, Never>, for url: URL) {
    inFlightTasks[url] = task
  }

  /// Removes the in-flight task when complete
  func clearInFlightTask(for url: URL) {
    inFlightTasks[url] = nil
  }
}

struct AuthenticatedImage: View {
  let url: URL?
  let token: String?

  @State private var image: Image?
  @State private var isLoading: Bool = false
  @State private var didFail: Bool = false

  var body: some View {
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

    // Check cache first (instant)
    if let cached = await ImageCache.shared.image(for: url) {
      image = Image(uiImage: cached)
      return
    }

    // Check for in-flight request to deduplicate
    if let existingTask = await ImageCache.shared.inFlightTask(for: url) {
      if let result = await existingTask.value {
        image = Image(uiImage: result)
      } else {
        didFail = true
      }
      return
    }

    isLoading = true

    // Create and register the fetch task
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
          // Cache the result
          await ImageCache.shared.setImage(uiImage, for: url)
          return uiImage
        }
        return nil
      } catch {
        return nil
      }
    }

    await ImageCache.shared.setInFlightTask(fetchTask, for: url)

    let result = await fetchTask.value
    await ImageCache.shared.clearInFlightTask(for: url)

    isLoading = false

    if let uiImage = result {
      image = Image(uiImage: uiImage)
    } else {
      didFail = true
    }
  }
}
