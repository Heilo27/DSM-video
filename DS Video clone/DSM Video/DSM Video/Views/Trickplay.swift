import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// TASK-740: client model for trick-play scrubbing previews. Loads the server's
/// WebVTT (timestamp → sprite #xywh tile) and the sprite sheet, and crops the tile
/// for a given playback time. iOS-only (tvOS scrubbing has no drag preview surface).
#if canImport(UIKit)
struct Trickplay {
  struct Cue {
    let start: Double
    let end: Double
    let rect: CGRect  // tile rect within the sprite, in pixels
  }

  let sprite: UIImage
  let cues: [Cue]

  /// Returns the cropped thumbnail for the given time, or nil if out of range.
  func thumbnail(at seconds: Double) -> UIImage? {
    guard let cue = cues.first(where: { seconds >= $0.start && seconds < $0.end }) ?? cues.last,
          let cg = sprite.cgImage else { return nil }
    let scale = sprite.scale
    let px = CGRect(x: cue.rect.minX * scale, y: cue.rect.minY * scale,
                    width: cue.rect.width * scale, height: cue.rect.height * scale)
    guard let cropped = cg.cropping(to: px) else { return nil }
    return UIImage(cgImage: cropped, scale: scale, orientation: .up)
  }

  /// Load the VTT + sprite from the trick-play base URL. Returns nil on any failure
  /// (no preview is shown). `auth` applies the same header logic as media requests.
  static func load(baseURL: URL, token: String?, usesTunnelCookie: Bool) async -> Trickplay? {
    let vttURL = baseURL.appendingPathComponent("trickplay.vtt")
    let spriteURL = baseURL.appendingPathComponent("trickplay.jpg")

    func request(_ url: URL) -> URLRequest {
      var r = URLRequest(url: url, timeoutInterval: 20)
      if !url.absoluteString.contains("_sid="), let token {
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      }
      if usesTunnelCookie {
        r.setValue("type=tunnel", forHTTPHeaderField: "Cookie")
      }
      return r
    }

    do {
      let (vttData, vttResp) = try await URLSession.shared.data(for: request(vttURL))
      guard (vttResp as? HTTPURLResponse)?.statusCode == 200,
            let vttText = String(data: vttData, encoding: .utf8) else { return nil }
      let cues = parseVTT(vttText)
      guard !cues.isEmpty else { return nil }

      let (imgData, imgResp) = try await URLSession.shared.data(for: request(spriteURL))
      guard (imgResp as? HTTPURLResponse)?.statusCode == 200,
            let img = UIImage(data: imgData) else { return nil }

      return Trickplay(sprite: img, cues: cues)
    } catch {
      return nil
    }
  }

  /// Parse WebVTT cues of the form:
  ///   00:00:00.000 --> 00:00:10.000
  ///   trickplay.jpg#xywh=0,0,160,90
  static func parseVTT(_ text: String) -> [Cue] {
    var cues: [Cue] = []
    let lines = text.components(separatedBy: .newlines)
    var i = 0
    while i < lines.count {
      let line = lines[i].trimmingCharacters(in: .whitespaces)
      if line.contains("-->") {
        let times = line.components(separatedBy: "-->")
        if times.count == 2,
           let start = parseTimestamp(times[0]),
           let end = parseTimestamp(times[1]),
           i + 1 < lines.count,
           let rect = parseXYWH(lines[i + 1]) {
          cues.append(Cue(start: start, end: end, rect: rect))
          i += 2
          continue
        }
      }
      i += 1
    }
    return cues
  }

  private static func parseTimestamp(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces)
    let parts = t.components(separatedBy: ":")
    guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]),
          let sec = Double(parts[2]) else { return nil }
    return h * 3600 + m * 60 + sec
  }

  private static func parseXYWH(_ s: String) -> CGRect? {
    guard let hashRange = s.range(of: "#xywh=") else { return nil }
    let nums = s[hashRange.upperBound...].trimmingCharacters(in: .whitespaces)
      .components(separatedBy: ",").compactMap { Double($0) }
    guard nums.count == 4 else { return nil }
    return CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
  }
}
#endif
