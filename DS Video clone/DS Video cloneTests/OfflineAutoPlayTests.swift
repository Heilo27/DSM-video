import Testing
@testable import DSM_Video

// TASK-984 repro (FR-071 / FR-133): the Home hero's Play and the Continue Watching movie
// card push ItemDetailView with autoPlay, and its onAppear opened the player without
// consulting playUnavailableOffline. Offline, a title that isn't downloaded went straight
// to the playback-failed panel instead of the detail screen with Play disabled.

@MainActor
@Suite("Offline autoPlay guard (TASK-984)")
struct OfflineAutoPlayTests {

  @Test("Offline and not downloaded: autoPlay does not open the player")
  func offlineNotDownloadedSuppressesAutoPlay() {
    let unavailable = ItemDetailView.playUnavailableOffline(
      serverUnreachable: false, isOffline: true, isDownloaded: false)
    #expect(unavailable)
    #expect(ItemDetailView.shouldAutoPlay(requested: true, playUnavailableOffline: unavailable) == false)
  }

  @Test("NAS unreachable and not downloaded: autoPlay does not open the player")
  func unreachableNotDownloadedSuppressesAutoPlay() {
    let unavailable = ItemDetailView.playUnavailableOffline(
      serverUnreachable: true, isOffline: false, isDownloaded: false)
    #expect(ItemDetailView.shouldAutoPlay(requested: true, playUnavailableOffline: unavailable) == false)
  }

  @Test("Offline but downloaded: autoPlay still plays the local file")
  func downloadedStillAutoPlays() {
    let unavailable = ItemDetailView.playUnavailableOffline(
      serverUnreachable: true, isOffline: true, isDownloaded: true)
    #expect(unavailable == false)
    #expect(ItemDetailView.shouldAutoPlay(requested: true, playUnavailableOffline: unavailable))
  }

  @Test("Online: autoPlay plays; no autoPlay requested stays on the detail screen")
  func onlineHonoursRequest() {
    let unavailable = ItemDetailView.playUnavailableOffline(
      serverUnreachable: false, isOffline: false, isDownloaded: false)
    #expect(ItemDetailView.shouldAutoPlay(requested: true, playUnavailableOffline: unavailable))
    #expect(ItemDetailView.shouldAutoPlay(requested: false, playUnavailableOffline: unavailable) == false)
  }
}
