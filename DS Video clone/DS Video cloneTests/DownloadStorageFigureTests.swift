import Foundation
import Testing
@testable import DSM_Video

// MARK: - Downloads storage figure (TASK-1042 · OC-1050 · FR-030..043)
//
// The text the Downloads screen shows for storage: how much the downloads use, how much of the
// device is free, and how full the bar is. Expected values are literals (the system's file-size
// wording under an en_US locale), never recomputed with the formatter under test.

@Suite("Downloads storage figure")
@MainActor
struct DownloadStorageFigureTests {

  /// OC-1050 · a byte count reads as the system's file-size text at each boundary.
  /// Red if: the unit conversion changes (decimal vs binary base, wrong unit step, bytes dropped).
  @Test func sizeReadsAsFileSizeTextAtTheBoundaries() {
    let cases: [(Int64, String)] = [
      (0, "Zero KB"),
      (1, "1 byte"),
      (999, "999 bytes"),
      (1_000, "1 KB"),
      (1_500_000, "1.5 MB"),
      (4_500_000_000, "4.5 GB"),
      (Int64.max, "9.22 EB"),   // past the largest unit a download can reach, still a figure
    ]
    for (bytes, text) in cases {
      #expect(DownloadStorageFigure.size(bytes) == text, "\(bytes) bytes")
    }
  }

  /// OC-1050 · the header and caption wording around the sizes.
  /// Red if: the wording or the used/available/total order changes.
  @Test func headerAndCaptionNameWhatEachNumberIs() {
    #expect(DownloadStorageFigure.usedText(usedBytes: 0) == "Zero KB used")
    #expect(DownloadStorageFigure.usedText(usedBytes: 1) == "1 byte used")
    #expect(DownloadStorageFigure.usedText(usedBytes: 4_500_000_000) == "4.5 GB used")
    #expect(DownloadStorageFigure.availableText(availableBytes: 60_000_000_000, totalBytes: 128_000_000_000)
            == "60 GB of 128 GB available")
    #expect(DownloadStorageFigure.accessibilityLabel(
      usedBytes: 4_500_000_000, availableBytes: 60_000_000_000, totalBytes: 128_000_000_000)
            == "Storage: 4.5 GB used by downloads, 60 GB of 128 GB available")
  }

  /// OC-1050 · the bar fills used over total, and stays empty (not NaN or infinite) when the
  /// device total is unknown.
  /// Red if: the fraction is inverted, uses available instead of used, or divides by a zero total.
  @Test func barFillsUsedOverTotalAndStaysEmptyWithoutATotal() {
    #expect(DownloadStorageFigure.fillFraction(usedBytes: 0, totalBytes: 100) == 0)
    #expect(DownloadStorageFigure.fillFraction(usedBytes: 25, totalBytes: 100) == 0.25)
    #expect(DownloadStorageFigure.fillFraction(usedBytes: 100, totalBytes: 100) == 1)
    #expect(DownloadStorageFigure.fillFraction(usedBytes: 50, totalBytes: 0) == 0)
    #expect(DownloadStorageFigure.fillFraction(usedBytes: 50, totalBytes: -1) == 0)
  }
}
