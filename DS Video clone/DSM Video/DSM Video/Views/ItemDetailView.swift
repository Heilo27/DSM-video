import AVKit
import SwiftUI

struct ItemDetailView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.dismiss) private var dismiss
  @Environment(\.theme) private var theme
  @State private var downloadManager = DownloadManager.shared
  let itemID: String
  let fallbackTitle: String
  var autoPlay: Bool = false
  var nextEpisode: ItemSummary? = nil
  var onNextEpisode: (() -> Void)? = nil
  var onGoToShow: (() -> Void)? = nil
  var isLastOfSeason: Bool = false
  var seasonNumber: Int? = nil
  var episodeNumber: Int? = nil

  @State private var detail: ItemDetail?
  @State private var isLoading: Bool = false
  @State private var error: String?
  @State private var downloadError: String?

  @State private var showPlayer: Bool = false
  @State private var playFromBeginning: Bool = false
  @State private var savedPositionSeconds: Int = 0
  @State private var isStartingDownload: Bool = false
  @State private var showMetadataFixer: Bool = false
  // Set when the player requests the next episode. The advance must run in the
  // cover's onDismiss — firing it while the cover is still presented swaps this
  // view's identity (.id) mid-dismissal, and tvOS silently drops the next
  // episode's fullScreenCover presentation.
  @State private var advanceToNextAfterDismiss: Bool = false
  @State private var viewHeight: CGFloat = 852  // sensible default (iPhone 15 Pro)
  #if os(tvOS)
  @Namespace private var actionNamespace
  #endif

  private var isDownloaded: Bool {
    downloadManager.isDownloaded(itemId: itemID)
  }

  private var isDownloading: Bool {
    downloadManager.isDownloading(itemId: itemID)
  }

  private var downloadProgress: Double {
    downloadManager.downloadProgress[itemID] ?? 0
  }

  var body: some View {
    #if os(tvOS)
    tvBody
      .navigationTitle("")
      .task(id: itemID) { await load(); loadProgress() }
      .onAppear {
        if autoPlay { showPlayer = true }
      }
      .fullScreenCover(isPresented: $showPlayer, onDismiss: {
        playFromBeginning = false
        loadProgress()
        if advanceToNextAfterDismiss {
          advanceToNextAfterDismiss = false
          onNextEpisode?()
        }
      }) {
        PlayerSheet(
          itemID: itemID,
          title: detail?.title ?? fallbackTitle,
          itemYear: detail?.year,
          forceFromBeginning: playFromBeginning,
          nextEpisode: nextEpisode,
          onPlayNextEpisode: onNextEpisode != nil ? { advanceToNextAfterDismiss = true } : nil,
          onGoToShow: onGoToShow
        )
        .environment(appState)
      }
    #else
    iOSBody
      .navigationTitle(detail?.title ?? fallbackTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbarBackground(Color.black.opacity(0.85), for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .task(id: itemID) { await load(); loadProgress() }
      .onAppear {
        if autoPlay { showPlayer = true }
      }
      .fullScreenCover(isPresented: $showPlayer, onDismiss: {
        playFromBeginning = false
        loadProgress()
        if advanceToNextAfterDismiss {
          advanceToNextAfterDismiss = false
          onNextEpisode?()
        }
      }) {
        PlayerSheet(
          itemID: itemID,
          title: detail?.title ?? fallbackTitle,
          itemYear: detail?.year,
          forceFromBeginning: playFromBeginning,
          nextEpisode: nextEpisode,
          onPlayNextEpisode: onNextEpisode != nil ? { advanceToNextAfterDismiss = true } : nil,
          onGoToShow: onGoToShow
        )
        .environment(appState)
        .toolbarVisibility(.hidden, for: .tabBar)
      }
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Button("Fix Metadata", systemImage: "magnifyingglass") {
              showMetadataFixer = true
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .accessibilityLabel("More options")
        }
      }
      .sheet(isPresented: $showMetadataFixer) {
        MetadataFixerSheet(itemID: itemID, initialQuery: detail?.title ?? fallbackTitle) {
          detail = nil
          Task { await load() }
        }
        .environment(appState)
      }
    #endif
  }

  // MARK: - tvOS layout: full-screen ZStack, content anchored to bottom

  #if os(tvOS)
  private var tvBody: some View {
    GeometryReader { geo in
      ZStack(alignment: .bottom) {
        // Image fills the full geometry frame
        Color.black
        backdropImage
          .scaledToFill()
          .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
          .clipped()

        // Panel anchored to bottom — capped so hero image always dominates the top
        contentPanel
          .background(.ultraThinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: theme.radiusLg, style: .continuous))
          // Fade the very top edge of the panel into the hero image
          .mask(
            LinearGradient(
              stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.03)
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .frame(width: geo.size.width, alignment: .bottom)
          .frame(maxHeight: geo.size.height * 0.52, alignment: .bottom)
          .clipped()
          .padding(.bottom, 20)
      }
      .frame(width: geo.size.width, height: geo.size.height)
    }
    .ignoresSafeArea(edges: .all)
    .privacySensitive()
  }
  #endif

  // MARK: - iOS layout: scrollable, image bleeds behind panel

  #if !os(tvOS)
  private var iOSBody: some View {
    // Deterministic top/bottom split (replaces the old content-height ZStack overlap
    // that let the panel grow over the artwork and overflow horizontally):
    //   • backdrop artwork fills the TOP portion
    //   • the content panel (pills, Play/Start Over, overview, cast) occupies the
    //     BOTTOM portion, frosted, with its own internal scroll for long overviews.
    // Every child is bounded to geo.size.width, so nothing can escape the screen.
    GeometryReader { geo in
      let panelHeight = max(260, geo.size.height * 0.42)  // bottom ~⅖
      ZStack(alignment: .bottom) {
        // Artwork fills the whole area; the frosted panel overlaps its lower part.
        header
          .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
          .clipped()

        ScrollView {
          contentPanel
            .frame(width: geo.size.width, alignment: .leading)
        }
        .frame(width: geo.size.width, height: panelHeight)
        .background(.ultraThinMaterial)
        .clipShape(
          .rect(topLeadingRadius: 20, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 20)
        )
        .mask(
          LinearGradient(
            stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06)],
            startPoint: .top, endPoint: .bottom
          )
        )
      }
      .frame(width: geo.size.width, height: geo.size.height)
      .onAppear { viewHeight = geo.size.height }
      .onChange(of: geo.size.height) { _, h in viewHeight = h }
    }
    .id(showPlayer)
    .background(Color.black.ignoresSafeArea())
    .privacySensitive()
  }
  #endif

  // MARK: - Content Panel (metadata + actions)

  // MARK: - Action Buttons

  #if os(tvOS)
  @FocusState private var focusedAction: ActionButton?
  enum ActionButton: Hashable { case play, fromBeginning, watchlist }

  private var tvPlayButton: some View {
    let focused = focusedAction == .play
    return Button {
      // TASK-796: guard so a Play/Start Over double-tap can't flip playFromBeginning
      // after the player is already presenting.
      guard !showPlayer else { return }
      playFromBeginning = false
      showPlayer = true
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "play.fill")
        Text("Play")
        if isDownloaded {
          Image(systemName: "arrow.down.circle.fill")
            .font(.subheadline)
            .accessibilityHidden(true)
        }
      }
        .font(.headline.weight(.semibold))
        .foregroundStyle(Color.dsAccentOn)
        .frame(width: 260, height: 54)
        .background(Color.dsAccent.brightness(focused ? 0.12 : 0))
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous))
        .scaleEffect(focused ? 1.04 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: focused)
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .shadow(color: Color.dsAccent.opacity(focused ? 0.7 : 0.3), radius: focused ? 10 : 5, x: 0, y: 3)
    .focused($focusedAction, equals: .play)
    .prefersDefaultFocus(in: actionNamespace)
    .accessibilityLabel("Play \(detail?.title ?? fallbackTitle)")
  }

  private var tvStartOverButton: some View {
    let focused = focusedAction == .fromBeginning
    return Button {
      guard !showPlayer else { return }  // TASK-796
      playFromBeginning = true
      showPlayer = true
    } label: {
      Label("Start Over", systemImage: "arrow.counterclockwise")
        .font(.headline.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: 260, height: 54)
        .background(focused ? Color.dsSurfaceRaised : Color.dsSurfaceHigh)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous))
        .scaleEffect(focused ? 1.04 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: focused)
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .focused($focusedAction, equals: .fromBeginning)
    .accessibilityLabel("Start \(detail?.title ?? fallbackTitle) from the beginning")
  }

  private var tvWatchlistButton: some View {
    let focused = focusedAction == .watchlist
    let inList = isInWatchlist
    return Button {
      guard let d = detail else { return }
      let summary = ItemSummary(
        id: d.id, type: d.type, title: d.title, year: d.year,
        durationSeconds: d.durationSeconds, addedAt: "",
        rating: d.rating, posterImageId: d.images?.poster.id
      )
      Task { await appState.toggleWatchlist(item: summary) }
    } label: {
      Image(systemName: inList ? "bookmark.fill" : "bookmark")
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(inList ? Color.dsAccent : .white)
        .frame(width: 54, height: 54)
        .background(focused ? Color.dsSurfaceRaised : Color.dsSurfaceHigh)
        .clipShape(RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous))
        .scaleEffect(focused ? 1.04 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: focused)
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .focused($focusedAction, equals: .watchlist)
    .disabled(detail == nil)
    .accessibilityLabel(inList ? "Remove from Watchlist" : "Add to Watchlist")
  }
  #endif

  @ViewBuilder
  private var contentPanel: some View {
    VStack(alignment: .leading, spacing: 14) {
          // Metadata pills
          if detail != nil {
            metadataPills
          }

          #if os(tvOS)
          // tvOS: episode badge + title on left, action buttons on right — one row
          HStack(alignment: .center, spacing: 16) {
            // Episode badge + title (expands to fill available space)
            if seasonNumber != nil || episodeNumber != nil {
              let badge: String = {
                if let s = seasonNumber, let e = episodeNumber { return "S\(s) · E\(e)" }
                if let s = seasonNumber { return "Season \(s)" }
                if let e = episodeNumber { return "Episode \(e)" }
                return ""
              }()
              (Text(badge).foregroundStyle(Color.dsAccent)
                + Text("  \(detail?.title ?? fallbackTitle)").foregroundStyle(.white))
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .accessibilityLabel("\(badge), \(detail?.title ?? fallbackTitle)")
            } else {
              Text(detail?.title ?? fallbackTitle)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            }

            Spacer(minLength: 12)

            // Action buttons — fixed width, right-aligned
            // Start Over is always in the layout (opacity 0 when no saved position)
            // so the Play button never shifts when progress loads asynchronously.
            HStack(spacing: 12) {
              tvPlayButton
              tvStartOverButton
                .opacity(savedPositionSeconds > 0 ? 1 : 0)
                .disabled(savedPositionSeconds == 0)
                .allowsHitTesting(savedPositionSeconds > 0)
                .accessibilityHidden(savedPositionSeconds == 0)
              tvWatchlistButton
            }
            .focusScope(actionNamespace)
          }
          #else
          // iOS: action buttons row. Play + Start Over FLEX to share the available
          // width (was fixed 200pt each, which overflowed the panel); the icon
          // buttons stay fixed-size.
          HStack(spacing: 12) {
            Button {
              guard !showPlayer else { return }  // TASK-796
              playFromBeginning = false
              showPlayer = true
            } label: {
              HStack(spacing: 6) {
                Image(systemName: "play.fill")
                Text("Play")
                if isDownloaded {
                  Image(systemName: "arrow.down.circle.fill")
                    .font(.subheadline)
                    .accessibilityHidden(true)
                }
              }
              .font(.headline.weight(.semibold))
              .foregroundStyle(Color.dsAccentOn)
              .frame(maxWidth: .infinity)
              .frame(height: 44)
              .background(Color.dsAccent)
              .clipShape(RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous))
            }
            .buttonStyle(.plain)
            .shadow(color: Color.dsAccent.opacity(0.5), radius: 8, x: 0, y: 4)
            .accessibilityLabel(isDownloaded ? "Play \(detail?.title ?? fallbackTitle), downloaded" : "Play \(detail?.title ?? fallbackTitle)")

            if savedPositionSeconds > 0 {
              Button {
                guard !showPlayer else { return }  // TASK-796
                playFromBeginning = true
                showPlayer = true
              } label: {
                Label("Start Over", systemImage: "arrow.counterclockwise")
                  .font(.headline.weight(.semibold))
                  .foregroundStyle(.white)
                  .frame(maxWidth: .infinity)
                  .frame(height: 44)
                  .background(Color.dsSurfaceHigh)
                  .clipShape(RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous))
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Start \(detail?.title ?? fallbackTitle) from the beginning")
            }

            downloadIconButton
            watchlistIconButton
          }
          #endif

          // Download error (separate from detail-load error to avoid clobbering the header)
          #if !os(tvOS)
          if let dlErr = downloadError {
            Text(dlErr)
              .font(.footnote)
              .foregroundStyle(Color.dsError)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          #endif

          // Next Episode button (TV show context only — both tvOS and iOS)
          if let next = nextEpisode, let action = onNextEpisode {
            Button {
              action()
            } label: {
              HStack(spacing: 10) {
                Image(systemName: "forward.end.fill")
                  #if os(tvOS)
                  .font(.body.weight(.semibold))
                  #else
                  .font(.subheadline.weight(.semibold))
                  #endif
                VStack(alignment: .leading, spacing: 2) {
                  Text("Next Episode")
                    #if os(tvOS)
                    .font(.body.weight(.semibold))
                    #else
                    .font(.subheadline.weight(.semibold))
                    #endif
                  Text((next.episodeNumber.map { "E\($0) · " } ?? "") + next.title)
                    #if os(tvOS)
                    .font(.subheadline)
                    #else
                    .font(.caption)
                    #endif
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.white.opacity(0.5))
              }
              .foregroundStyle(.white)
              #if os(tvOS)
              .padding(.horizontal, 20)
              .padding(.vertical, 14)
              .frame(maxWidth: .infinity, minHeight: 64)
              #else
              .padding(.horizontal, 14)
              .padding(.vertical, 10)
              .frame(maxWidth: .infinity, minHeight: 52)
              #endif
              .background(Color.dsSurfaceHigh)
              .clipShape(RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next Episode\(next.episodeNumber.map { ", Episode \($0)" } ?? ""): \(next.title)")
            .accessibilityHint("Opens episode detail")
          } else if isLastOfSeason {
            HStack(spacing: 8) {
              Image(systemName: "flag.checkered")
                #if os(tvOS)
                .font(.body)
                #else
                .font(.subheadline)
                #endif
                .foregroundStyle(.white.opacity(0.45))
              Text("End of Season")
                #if os(tvOS)
                .font(.body)
                #else
                .font(.subheadline)
                #endif
                .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color.dsSurface)
            .clipShape(RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous))
            .accessibilityLabel("End of season — no more episodes in this season")
          }

          // iOS episode identifier — S·E (red) + title (tvOS has it in the action row)
          #if !os(tvOS)
          if seasonNumber != nil || episodeNumber != nil {
            let badge: String = {
              if let s = seasonNumber, let e = episodeNumber { return "S\(s) · E\(e)" }
              if let s = seasonNumber { return "Season \(s)" }
              if let e = episodeNumber { return "Episode \(e)" }
              return ""
            }()
            // iOS 26 deprecated Text + Text concatenation. HStack keeps the
            // two-color treatment (accent badge + white title) without it.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(badge).foregroundStyle(Color.dsAccent)
              Text(detail?.title ?? fallbackTitle).foregroundStyle(.white)
            }
            .font(.title3.weight(.bold))
            .lineLimit(2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(badge), \(detail?.title ?? fallbackTitle)")
          }
          #endif

          if let summary = detail?.summary, !summary.isEmpty {
            Text(summary)
              .font(.body)
              .foregroundStyle(.white.opacity(0.88))
              .fixedSize(horizontal: false, vertical: true)
          }

          if let cast = detail?.cast, !cast.isEmpty {
            castSection(cast: cast)
          }

          #if !os(tvOS)
          Spacer(minLength: 32)
          #endif
        }
        #if os(tvOS)
        .padding(.horizontal, 60)
        .padding(.top, 20)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        .padding(.horizontal, 16)
        .frame(maxWidth: horizontalSizeClass == .regular ? 720 : .infinity)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 16)
        .padding(.bottom, 32)
        #endif
  }
  // end contentPanel

  // MARK: - Header

  // TASK-846: horizontalSizeClass is ALWAYS .regular on tvOS — it carries no information
  // there, so this silently took the iPad branch (420pt) on a 1080pt-tall 10-foot display.
  // Give tvOS its own constant sized for the screen it actually runs on.
  private var backdropHeight: CGFloat {
    #if os(tvOS)
    return 620
    #else
    return horizontalSizeClass == .regular ? 420 : min(300, viewHeight * 0.35)
    #endif
  }

  @ViewBuilder
  private var header: some View {
    if isLoading && detail == nil {
      Color.black
        .frame(maxWidth: .infinity, minHeight: backdropHeight)
        .overlay(ProgressView("Loading").tint(.white).accessibilityLabel("Loading, please wait"))
    } else if let error {
      Color.black
        .frame(maxWidth: .infinity, minHeight: backdropHeight)
        .overlay(
          VStack(spacing: 12) {
            ContentUnavailableView(
              "Couldn't load details",
              systemImage: "exclamationmark.triangle",
              description: Text(error)
            )
            // FIX-18: retry button so users aren't stuck on error without navigating away
            Button("Retry") { Task { await load() } }
              .buttonStyle(.borderedProminent)
          }
        )
    } else {
      // Artwork fills the header area; iOSBody pins header to the full height and
      // clips, and the frosted content panel overlaps its lower portion.
      backdropImage
        .frame(maxWidth: .infinity, alignment: .top)
        #if os(tvOS)
        .frame(minHeight: backdropHeight)
        #endif
        #if !os(tvOS)
        .overlay(alignment: .topTrailing) {
          if !appState.isDemoMode,
             (detail?.summary == nil || detail?.summary?.isEmpty == true),
             detail?.images?.backdrop.id == nil {
            Button {
              showMetadataFixer = true
            } label: {
              Text("No metadata · Fix")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(minHeight: 44)
                .background(Color.black.opacity(0.7))
                .clipShape(Capsule())
            }
            .accessibilityLabel("Fix missing metadata for \(fallbackTitle)")
            .accessibilityHint("Opens metadata search")
            .padding(10)
          }
        }
        // Cinematic-only: a scrim + display-font title over the backdrop so the Detail
        // hero speaks the same language as the Home hero. No-op on flat themes, which
        // keep the plain backdrop + nav title.
        .overlay {
          if ThemeHolder.shared.current.usesCinematicChrome {
            // Position the title/eyebrow in the visible band just above where the frosted
            // content panel starts (the panel covers the bottom ~42% of the header). A
            // GeometryReader keeps it above the panel's top edge on any screen size.
            GeometryReader { geo in
              let panelTop = geo.size.height - max(260, geo.size.height * 0.42)
              ZStack(alignment: .bottomLeading) {
                LinearGradient(
                  stops: [.init(color: .clear, location: 0.4),
                          .init(color: Color.dsBackground.opacity(0.85), location: 1.0)],
                  startPoint: .top, endPoint: .bottom
                )
                .frame(height: panelTop + 30)
                .frame(maxHeight: .infinity, alignment: .top)

                VStack(alignment: .leading, spacing: 6) {
                  Text((detail?.type ?? "") == "tvshow" ? "SERIES" : "FEATURE")
                    .font(.dsEyebrow)
                    .tracking(2)
                    .foregroundStyle(Color.dsAccent)
                  Text(detail?.title ?? fallbackTitle)
                    .font(.dsDisplay)
                    .foregroundStyle(Color.dsTextPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.bottom, geo.size.height - panelTop + 16)
              }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
          }
        }
        #endif
    }
  }

  @ViewBuilder
  private var backdropImage: some View {
    if let backdropId = detail?.images?.backdrop.id ?? detail?.images?.backdrop.mapperId {
      AuthenticatedImage(
        url: appState.api.imageURL(id: backdropId, width: 1200, version: detail?.changeSeq),
        token: appState.sessionToken,
        usesTunnelCookie: appState.api.usesTunnelCookie
      )
      #if !os(tvOS)
      // Fill the header area (iOSBody gives header an explicit full-height frame +
      // .clipped()), so the artwork covers the top of the screen rather than
      // letterboxing into a short band.
      .scaledToFill()
      #endif
    } else {
      // No backdrop — gradient placeholder with title overlay
      LinearGradient(
        colors: [Color.dsSurfaceRaised, Color.black],
        startPoint: .top,
        endPoint: .bottom
      )
      .overlay(alignment: .bottomLeading) {
        Text(detail?.title ?? fallbackTitle)
          .font(.title2.bold())
          .foregroundStyle(.white.opacity(0.7))
          .padding(24)
          .accessibilityHidden(true)
      }
    }
  }

  // MARK: - Metadata Pills

  @ViewBuilder
  private var metadataPills: some View {
    let year = detail?.year
    let contentRating = detail?.contentRating
    let starRating = detail?.rating
    let genres = detail?.genres ?? []
    let durationSeconds = detail?.durationSeconds

    if year != nil || contentRating != nil || starRating != nil || !genres.isEmpty || durationSeconds != nil {
      let metaLabel: String = [
        year.map { String($0) },
        durationSeconds.flatMap { $0 > 0 ? formatDuration($0) : nil },
        contentRating.flatMap { $0.isEmpty ? nil : $0 },
        starRating.flatMap { $0 > 0 ? "Rating \(String(format: "%.1f", $0)) out of 10" : nil },
        { let b = detail?.qualityBadges ?? []; return b.isEmpty ? nil : b.joined(separator: ", ") }(),
        genres.isEmpty ? nil : genres.joined(separator: ", ")
      ].compactMap { $0 }.joined(separator: ", ")

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          if let year {
            MetadataPill(text: String(year))
          }
          if let secs = durationSeconds, secs > 0 {
            MetadataPill(text: formatDuration(secs))
          }
          if let contentRating, !contentRating.isEmpty {
            MetadataPill(text: contentRating)
          }
          // Guard > 0: items with no rating data come back as 0.0, which would
          // otherwise render an empty "0.0" star pill.
          if let starRating, starRating > 0 {
            HStack(spacing: 3) {
              Image(systemName: "star.fill")
                .foregroundStyle(Color.dsWarning)
                .font(.caption.weight(.medium))
                .accessibilityHidden(true)
              Text(String(format: "%.1f", starRating))
                .foregroundStyle(.white.opacity(0.85))
                .font(.caption.weight(.medium))
                .accessibilityLabel("Rating: \(String(format: "%.1f", starRating)) out of 10")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.dsSurfaceRaised)
            .clipShape(Capsule())
          }
          // TASK-728: quality/format badges (4K / HEVC / 5.1 / Atmos-ready), accent-
          // tinted so they read as a distinct class from the neutral metadata pills.
          if let d = detail {
            ForEach(d.qualityBadges, id: \.self) { badge in
              QualityBadge(text: badge)
            }
          }
          ForEach(genres, id: \.self) { genre in
            MetadataPill(text: genre)
          }
        }
        .padding(.vertical, 2)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(metaLabel)
    }
  }

  private func formatDuration(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m" }
    return "\(seconds)s"
  }

  // MARK: - Download Icon Button

  @ViewBuilder
  private var downloadIconButton: some View {
    Button {
      guard !appState.isDemoMode else { return }
      if isDownloading {
        Haptics.play(.light)
        downloadManager.cancelDownload(itemId: itemID)
      } else if isDownloaded {
        Haptics.play(.light)
        downloadManager.deleteDownload(itemId: itemID)
      } else {
        Haptics.play(.medium)
        Task { await startDownload() }
      }
    } label: {
      ZStack {
        if isDownloading {
          ZStack {
            Circle()
              .stroke(Color.dsBorderStrong, lineWidth: 2)
            Circle()
              .trim(from: 0, to: min(1.0, max(0.0, downloadProgress)))
              .stroke(Color.dsAccent, lineWidth: 2)
              .rotationEffect(.degrees(-90))
          }
          .frame(width: 22, height: 22)
        } else if isStartingDownload {
          ProgressView().tint(.white).frame(width: 22, height: 22)
        } else {
          Image(systemName: isDownloaded ? "checkmark" : "arrow.down")
            .font(.title3.weight(.semibold))
            .foregroundStyle(isDownloaded ? Color.dsAccent : .white)
        }
      }
      .frame(width: 52, height: 52)
    }
    .background(Color.dsSurfaceHigh)
    .clipShape(RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous))
    .disabled(isStartingDownload && !isDownloading)
    .accessibilityLabel(isStartingDownload ? "Starting download" : (isDownloaded ? "Remove download" : (isDownloading ? "Cancel download" : "Download")))
    .accessibilityValue(isDownloading && downloadProgress > 0 && downloadProgress < 1 ? "\(Int(downloadProgress * 100)) percent downloaded" : "")
  }

  // MARK: - Watchlist Icon Button

  private var isInWatchlist: Bool {
    guard let d = detail else { return false }
    return appState.watchlistItems.contains(where: { $0.id == d.id })
  }

  @ViewBuilder
  private var watchlistIconButton: some View {
    Button {
      guard let d = detail else { return }
      let summary = ItemSummary(
        id: d.id,
        type: d.type,
        title: d.title,
        year: d.year,
        durationSeconds: d.durationSeconds,
        addedAt: "",
        rating: d.rating,
        posterImageId: d.images?.poster.id
      )
      Haptics.play(.selection)
      Task { await appState.toggleWatchlist(item: summary) }
    } label: {
      Image(systemName: isInWatchlist ? "bookmark.fill" : "bookmark")
        .font(.title3.weight(.semibold))
        .foregroundStyle(isInWatchlist ? Color.dsAccent : .white)
        .frame(width: 52, height: 52)
    }
    .background(Color.dsSurfaceHigh)
    .clipShape(RoundedRectangle(cornerRadius: theme.radiusMd, style: .continuous))
    .disabled(detail == nil)
    .accessibilityLabel(isInWatchlist ? "Remove from Watchlist" : "Add to Watchlist")
  }

  // MARK: - Cast Section

  @ViewBuilder
  private func castSection(cast: [ItemDetail.Person]) -> some View {
    // A9: horizontal avatar scroll. The director is folded in as the first entry
    // (role labeled "Director"); remaining cast follow in order, director de-duped.
    let director = cast.first(where: { $0.role == "Director" })
    let others = cast.filter { $0.role != "Director" }
    let ordered: [ItemDetail.Person] = {
      guard let director else { return others }
      return [ItemDetail.Person(id: director.id, name: director.name, role: "Director", imageId: director.imageId)] + others
    }()

    VStack(alignment: .leading, spacing: 10) {
      Text("Cast & Crew")
        .font(.headline)
        .foregroundStyle(.white)
        .accessibilityAddTraits(.isHeader)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: 14) {
          ForEach(Array(ordered.enumerated()), id: \.offset) { _, person in
            castAvatar(person)
          }
        }
        .padding(.vertical, 2)
      }
    }
  }

  @ViewBuilder
  private func castAvatar(_ person: ItemDetail.Person) -> some View {
    let avatarSize: CGFloat = 64
    VStack(spacing: 6) {
      Group {
        // 64pt avatar → 192px at 3x, which lands on the server's 342 rung.
        if let imageId = person.imageId,
           let url = appState.api.imageURL(id: imageId, width: 342, version: detail?.changeSeq) {
          AuthenticatedImage(
            url: url,
            token: appState.sessionToken,
            usesTunnelCookie: appState.api.usesTunnelCookie
          )
          .scaledToFill()
        } else {
          Color.dsSurfaceHigh
            .overlay(
              Image(systemName: "person.fill")
                .font(.title2)
                .foregroundStyle(.white.opacity(0.4))
            )
        }
      }
      .frame(width: avatarSize, height: avatarSize)
      .clipShape(Circle())
      .overlay(Circle().strokeBorder(Color.dsBorderSubtle, lineWidth: 0.5))

      Text(person.name)
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .lineLimit(1)
      if let role = person.role, !role.isEmpty {
        Text(role)
          .font(.caption2)
          .foregroundStyle(Color.dsTextSecondary)
          .lineLimit(1)
      }
    }
    .frame(width: 84)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(person.role.flatMap { $0.isEmpty ? nil : "\(person.name), \($0)" } ?? person.name)
  }

  // MARK: - Data

  private func loadProgress() {
    Task { savedPositionSeconds = await LocalStore.shared.getProgressSeconds(itemId: itemID) }
  }

  private func load() async {
    guard !isLoading else { return }
    // Clear detail only after confirming we will actually start a load — avoids
    // a blank header flash when the guard exits early (TASK-425).
    detail = nil
    if appState.isDemoMode {
      detail = DemoData.detail(for: itemID)
      return
    }
    error = nil
    isLoading = true
    defer { isLoading = false }

    do {
      detail = try await appState.api.itemDetail(id: itemID)
    } catch {
      self.error = (error as? APIError)?.userMessage ?? "Unknown error."
    }
  }

  private func startDownload() async {
    guard !isStartingDownload else { return }
    isStartingDownload = true
    defer { isStartingDownload = false }

    do {
      // Get playback info to get the video URL
      let info = try await appState.api.playback(id: itemID)
      guard let videoURL = info.streamUrl ?? info.hlsMasterUrl else {
        self.downloadError = "No playable URL available for download."
        return
      }

      // Get poster URL if available
      var posterURL: URL? = nil
      if let posterId = detail?.images?.poster.id {
        posterURL = appState.api.imageURL(id: posterId, width: 400)
      }

      downloadManager.startDownload(
        itemId: itemID,
        title: detail?.title ?? fallbackTitle,
        year: detail?.year,
        videoURL: videoURL,
        posterURL: posterURL,
        token: appState.sessionToken,
        durationSeconds: detail?.durationSeconds ?? 0
      )
    } catch {
      let message = (error as? APIError)?.userMessage
        ?? error.localizedDescription
      self.downloadError = message
    }
  }
}

// MARK: - Metadata Fixer Sheet

#if !os(tvOS)
private struct MetadataFixerSheet: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  let itemID: String
  let initialQuery: String
  let onApplied: () -> Void

  @State private var searchQuery: String
  @State private var results: [TMDbCandidate] = []
  @State private var isSearching = false
  @State private var isApplying = false
  @State private var error: String?
  @State private var applied = false

  init(itemID: String, initialQuery: String, onApplied: @escaping () -> Void) {
    self.itemID = itemID
    self.initialQuery = initialQuery
    self.onApplied = onApplied
    _searchQuery = State(initialValue: initialQuery)
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          TextField("Search TMDb...", text: $searchQuery)
            .onSubmit { Task { await search() } }
            .foregroundStyle(.white)
        }
        .listRowBackground(Color(white: 0.12))

        if isSearching {
          HStack {
            Spacer()
            ProgressView("Searching").tint(.white)
            Spacer()
          }
          .listRowBackground(Color(white: 0.08))
        } else {
          ForEach(results) { candidate in
            Button {
              Task { await apply(candidate) }
            } label: {
              HStack(spacing: 12) {
                AsyncImage(url: candidate.posterURL) { img in
                  img.resizable().scaledToFill()
                    .frame(width: 50, height: 75, alignment: .top)
                } placeholder: {
                  Color(white: 0.15)
                }
                .frame(width: 50, height: 75)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                  Text(candidate.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                  if let year = candidate.year {
                    Text(String(year))
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  if let overview = candidate.overview, !overview.isEmpty {
                    Text(overview)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(3)
                  }
                }
              }
            }
            .buttonStyle(.plain)
            .disabled(isApplying)
            .listRowBackground(Color(white: 0.1))
          }
        }

        if let error {
          Text(error)
            .foregroundStyle(Color.dsError)
            .font(.caption)
            .listRowBackground(Color(white: 0.08))
        }
        if applied {
          Text("Metadata updated! Pull to refresh.")
            .foregroundStyle(.green)
            .font(.caption)
            .listRowBackground(Color(white: 0.08))
        }
      }
      .navigationTitle("Fix Metadata")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Search") { Task { await search() } }
            .disabled(isSearching)
        }
      }
      .task { await search() }
      .scrollContentBackground(.hidden)
      .background(Color.black)
    }
  }

  private func search() async {
    guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    isSearching = true
    error = nil
    defer { isSearching = false }
    do {
      let resp = try await appState.api.tmdbSearch(itemId: itemID, query: searchQuery)
      results = resp.results
    } catch {
      self.error = (error as? APIError)?.userMessage ?? "Search failed."
    }
  }

  private func apply(_ candidate: TMDbCandidate) async {
    isApplying = true
    defer { isApplying = false }
    do {
      try await appState.api.tmdbFix(itemId: itemID, tmdbId: candidate.tmdbId, type: candidate.type)
      applied = true
      onApplied()
      dismiss()
    } catch {
      self.error = (error as? APIError)?.userMessage ?? "Failed to apply."
    }
  }
}
#endif

// MARK: - Metadata Pill

private struct MetadataPill: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption.weight(.medium))
      .foregroundStyle(.white.opacity(0.85))
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(Color.dsSurfaceRaised)
      .clipShape(Capsule())
  }
}

/// Accent-outlined pill for media quality/format badges (4K, HEVC, 5.1, Atmos-ready).
/// Visually distinct from the neutral MetadataPill so format capability reads at a glance.
private struct QualityBadge: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption2.weight(.bold))
      .foregroundStyle(Color.dsAccent)
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .overlay(Capsule().stroke(Color.dsAccent.opacity(0.6), lineWidth: 1))
      .clipShape(Capsule())
  }
}

// MARK: - Player Sheet

private struct PlayerSheet: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.theme) private var theme
  let itemID: String
  let title: String
  var itemYear: Int? = nil
  var forceFromBeginning: Bool = false
  var nextEpisode: ItemSummary? = nil
  var onPlayNextEpisode: (() -> Void)? = nil
  var onGoToShow: (() -> Void)? = nil

  @State private var playbackURL: URL?
  @State private var error: String?
  @State private var resumePosition: Double = 0
  // Full runtime handed to the player so its scrubber is correct even while the HLS
  // transcode is still generating (a live-window playlist under-reports duration).
  // From the playback response's durationSeconds, falling back to the item's own.
  @State private var playbackDuration: Double = 0
  @State private var isOffline: Bool = false
  @State private var chapters: [Chapter] = []
  // TASK-828: semantic subtitle metadata (full/forced/image + autoEnable) from the
  // playback response, handed to the player so it can auto-enable the forced
  // translation track and label the picker correctly.
  @State private var subtitles: [Subtitle] = []
  @State private var subtitleOffset: Double = 0
  @State private var subtitleOffsetRestartTask: Task<Void, Never>? = nil

  // Progress sync debouncing
  @State private var lastSyncTime: Date = .distantPast
  @State private var lastSyncedPosition: Int = 0
  /// The most recent position reported by the player (~every 0.5s), NOT gated by the sync
  /// throttle. This is what the dismiss and background-flush paths must persist —
  /// `lastSyncedPosition` is only the last value that survived throttling. See TASK-838.
  @State private var livePosition: Int = 0
  @State private var lastKnownDuration: Int = 0
  private let syncInterval: TimeInterval = 10  // Sync at most every 10 seconds
  private let seekThreshold: Int = 15  // Or if position changes by 15+ seconds (seek)
  // TASK-719: when a mid-playback failure forces a stream refresh, carry the
  // last-known position/duration across start()'s reset so (a) the refreshed
  // stream resumes where the user was rather than the up-to-10s-stale server
  // position, and (b) an immediate dismiss after recovery still flushes progress
  // instead of being suppressed by the 0/0 guard.
  @State private var resumeOverrideSeconds: Int = 0
  @State private var resumeOverrideDuration: Int = 0

  // Autoplay next episode
  @State private var showNextEpisodeOverlay: Bool = false
  @State private var nextEpisodeCountdown: Int = 5
  @State private var countdownTask: Task<Void, Never>?

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let url = playbackURL {
        GestureVideoPlayer(
          url: url,
          title: title,
          resumePosition: resumePosition,
          serverDuration: playbackDuration,
          chapters: chapters,
          subtitles: subtitles,
          itemID: itemID,
          itemTitle: title,
          itemYear: itemYear,
          trickplayBaseURL: isOffline ? nil : appState.api.trickplayBaseURL(itemID: itemID),
          authToken: appState.sessionToken,
          usesTunnelCookie: appState.api.usesTunnelCookie,
          onDismiss: {
            // Guard: if user dismissed before video started or position/duration are
            // unknown, skip setProgress entirely — must not overwrite real saved progress
            // with 0/0 on instant dismiss (P2-3).
            // TASK-838: persist the LIVE position, not the throttled one. Falls back to
            // lastSyncedPosition if the player never reported a tick, so the "watched under
            // ~5s → write nothing" behaviour below is preserved exactly.
            let exitPosition = livePosition > 0 ? livePosition : lastSyncedPosition
            guard exitPosition > 0 && lastKnownDuration > 0 else {
              dismiss()
              return
            }
            if isOffline {
              // Persist final position locally for resume-on-reopen
              DownloadManager.shared.updateResumePosition(
                itemId: itemID,
                positionSeconds: exitPosition
              )
            }
            // Route through appState.recordProgress so LocalStore is updated (TASK-361).
            // Task is unavoidable here since onDismiss is a sync closure.
            let positionAtDismiss = exitPosition
            let durationAtDismiss = lastKnownDuration
            Task {
              await appState.recordProgress(
                itemId: itemID,
                positionSeconds: positionAtDismiss,
                durationSeconds: durationAtDismiss
              )
            }
            dismiss()
          },
          onProgressUpdate: { position, duration in
            let positionInt = Int(position)
            let durationInt = Int(duration)
            guard durationInt > 0 else { return }
            lastKnownDuration = durationInt

            // Record the LIVE position on every tick (~0.5s), before the throttle below.
            // `lastSyncedPosition` only advances when the throttle lets a sync through
            // (10s elapsed, 15s seek delta, or first sync), so using it at dismiss threw
            // away up to 10 seconds of watched content on every exit — and, near the end
            // of a title, could flip the 90s-remaining finish rule on a stale value so a
            // finished item was recorded as unfinished. The player has the true position
            // the whole time; this just stops discarding it.
            livePosition = positionInt

            let now = Date()
            let timeSinceLastSync = now.timeIntervalSince(lastSyncTime)
            let positionDelta = abs(positionInt - lastSyncedPosition)

            // Fire an immediate first sync if we haven't synced yet and playback
            // has progressed past 5 seconds — covers fast-exit before the 10s timer fires.
            let isFirstSync = lastSyncedPosition == 0 && positionInt > 5

            // Only sync if: enough time has passed OR user seeked significantly OR first sync
            guard timeSinceLastSync >= syncInterval || positionDelta >= seekThreshold || isFirstSync else {
              return
            }

            lastSyncTime = now
            lastSyncedPosition = positionInt

            if isOffline {
              // Persist position locally for resume-on-reopen
              DownloadManager.shared.updateResumePosition(
                itemId: itemID,
                positionSeconds: positionInt
              )
            }
            // Route through appState.recordProgress so LocalStore is updated (TASK-361).
            Task {
              await appState.recordProgress(
                itemId: itemID,
                positionSeconds: positionInt,
                durationSeconds: durationInt
              )
            }
          },
          onPlaybackFailed: {
            // Reset and re-fetch a fresh playback URL. Handles stale HLS sessions
            // (e.g. server restart clears in-memory sessions, causing 404 on stream).
            // TASK-719: snapshot the last-known position BEFORE start() wipes the sync
            // trackers, so recovery resumes where the user was and a quick dismiss
            // afterward still records progress.
            if lastSyncedPosition > 0 && lastKnownDuration > 0 {
              resumeOverrideSeconds = lastSyncedPosition
              resumeOverrideDuration = lastKnownDuration
            }
            playbackURL = nil
            Task { await start() }
          },
          onPlaybackFinished: {
            guard nextEpisode != nil, onPlayNextEpisode != nil else { return }
            showNextEpisodeOverlay = true
            nextEpisodeCountdown = 5
            countdownTask?.cancel()
            countdownTask = Task { @MainActor in
              for remaining in stride(from: 5, through: 0, by: -1) {
                guard !Task.isCancelled else { return }
                nextEpisodeCountdown = remaining
                if remaining == 0 {
                  showNextEpisodeOverlay = false
                  onPlayNextEpisode?()
                  dismiss()
                  return
                }
                do {
                  try await Task.sleep(for: .seconds(1))
                } catch {
                  return // Task cancelled — don't fire onPlayNextEpisode
                }
              }
            }
          },
          onSubtitleOffsetChange: { offset in
            subtitleOffset = offset
            subtitleOffsetRestartTask?.cancel()
            subtitleOffsetRestartTask = Task {
              try? await Task.sleep(for: .milliseconds(500))
              guard !Task.isCancelled else { return }
              // TASK-722: the stream is rebuilt with the new subtitle offset. Carry the
              // live position across the restart so playback resumes where the user was,
              // not at the up-to-10s-stale server heartbeat position.
              if lastSyncedPosition > 0 && lastKnownDuration > 0 {
                resumeOverrideSeconds = lastSyncedPosition
                resumeOverrideDuration = lastKnownDuration
              }
              playbackURL = nil
              await start()
            }
          },
          onGoToShow: onGoToShow,
          blockDpadSeek: showNextEpisodeOverlay
        )
        .ignoresSafeArea()

        if showNextEpisodeOverlay, let next = nextEpisode {
          nextEpisodeOverlay(next: next)
        }
      } else if let error {
        VStack(spacing: 20) {
          ContentUnavailableView("Playback failed", systemImage: "exclamationmark.triangle", description: Text(error))
            .foregroundStyle(.white)
          Button("Dismiss") { dismiss() }
            .buttonStyle(.borderedProminent)
        }
      } else {
        VStack(spacing: 20) {
          ProgressView("Loading video")
            .tint(.white)
          Button("Cancel") { dismiss() }
            .foregroundStyle(.white.opacity(0.7))
        }
      }
    }
    // Keyed on itemID, not bare .task. On autoplay-next-episode this view is reused with a
    // NEW itemID; an unkeyed .task does not re-fire, so start() never ran again and the
    // trackers it resets — livePosition in particular — still held the PREVIOUS episode's
    // position. That value could then be written against the new episode. The two sibling
    // .task modifiers in this file are already keyed this way.
    .task(id: itemID) { await start() }
    .onDisappear {
      // FIX-12: Cancel countdown when player is dismissed via system back gesture or swipe-to-dismiss.
      // Without this, the Task continues running against a deallocated binding and fires
      // onPlayNextEpisode into a dismissed view, causing a navigation no-op and potential crash.
      countdownTask?.cancel()
      countdownTask = nil
      subtitleOffsetRestartTask?.cancel()
      subtitleOffsetRestartTask = nil
    }
    .onChange(of: scenePhase) { _, newPhase in
      // TASK-270: flush pending progress when app goes to background so force-kill
      // doesn't lose the last known position.
      // TASK-838: same live-position fix as onDismiss. Using the throttled value here
      // undercut the very force-kill protection this flush was added for — it saved a
      // position up to 10s stale at the moment the app was about to be killed.
      if newPhase == .background, max(livePosition, lastSyncedPosition) > 0, lastKnownDuration > 0 {
        let pos = max(livePosition, lastSyncedPosition)
        let dur = lastKnownDuration
        if isOffline {
          DownloadManager.shared.updateResumePosition(itemId: itemID, positionSeconds: pos)
        }
        // TASK-719 / TASK-270: flush progress when backgrounding so a force-kill
        // doesn't lose position. recordProgress writes LocalStore first (the
        // durability guarantee) and then fires the network sync. Wrap in a UIKit
        // background-task assertion so iOS grants extra runtime to finish the local
        // write + sync before suspending, rather than killing us mid-flush.
        let itemSnapshot = itemID
        Task { @MainActor in
          let bgID = UIApplication.shared.beginBackgroundTask(withName: "FlushProgress")
          await appState.recordProgress(itemId: itemSnapshot, positionSeconds: pos, durationSeconds: dur)
          if bgID != .invalid { UIApplication.shared.endBackgroundTask(bgID) }
        }
      }
    }
  }

  @ViewBuilder
  private func nextEpisodeOverlay(next: ItemSummary) -> some View {
    #if os(tvOS)
    _NextEpisodeOverlayView(
      next: next,
      countdown: nextEpisodeCountdown,
      onPlayNow: {
        countdownTask?.cancel()
        showNextEpisodeOverlay = false
        onPlayNextEpisode?()
        dismiss()
      },
      onStay: {
        countdownTask?.cancel()
        showNextEpisodeOverlay = false
      }
    )
    #else
    VStack(spacing: 20) {
      Spacer()
      VStack(spacing: 12) {
        Text("Up Next")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.7))
          .textCase(.uppercase)
        Text(next.title)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)
          .lineLimit(2)
        Text("Playing in \(nextEpisodeCountdown)s")
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.7))
          .monospacedDigit()
        HStack(spacing: 16) {
          Button {
            countdownTask?.cancel()
            showNextEpisodeOverlay = false
            onPlayNextEpisode?()
            dismiss()
          } label: {
            Text("Play Now")
              .font(.headline)
              .foregroundStyle(Color.dsAccentOn)
              .padding(.horizontal, 24)
              .padding(.vertical, 10)
              .background(Color.dsAccent, in: Capsule())
          }
          .buttonStyle(.plain)
          Button {
            countdownTask?.cancel()
            showNextEpisodeOverlay = false
          } label: {
            Text("Cancel")
              .font(.headline)
              .foregroundStyle(.white)
              .padding(.horizontal, 24)
              .padding(.vertical, 10)
              .background(Color.white.opacity(0.2), in: Capsule())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(28)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: theme.radiusLg))
      .padding(.horizontal, 32)
      .padding(.bottom, 60)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black.opacity(0.45).ignoresSafeArea())
    .transition(.opacity)
    .animation(.easeInOut(duration: 0.25), value: showNextEpisodeOverlay)
    #endif
  }

  private func start() async {
    // Reset state for retry — ensures stale duration/position from a prior attempt
    // can't suppress the final progress write on the next dismiss (TASK-401).
    lastKnownDuration = 0
    lastSyncedPosition = 0
    // Same reason as the two above (TASK-401): a live position left over from a previous
    // item or a previous attempt must not be written against this one.
    livePosition = 0
    isOffline = false

    // TASK-719: if a failure-recovery snapshot exists, seed the trackers so an
    // immediate dismiss after recovery still flushes (vs. the 0/0 guard eating it).
    // Consumed once — cleared after use so a later legitimate reset isn't overridden.
    if resumeOverrideSeconds > 0 && resumeOverrideDuration > 0 {
      lastSyncedPosition = resumeOverrideSeconds
      lastKnownDuration = resumeOverrideDuration
    }

    // Demo mode — play the bundled royalty-free sample video (Big Buck Bunny,
    // Blender Foundation, CC BY 3.0) instead of hitting the server.
    if appState.isDemoMode {
      if let demoURL = Bundle.main.url(forResource: "demo_video", withExtension: "mp4") {
        playbackURL = demoURL
      } else {
        error = "Demo video not found."
      }
      return
    }

    // Check if we have a downloaded version first
    if let downloaded = DownloadManager.shared.getDownloadedItem(itemId: itemID) {
      let localURL = URL(fileURLWithPath: downloaded.videoPath)
      if FileManager.default.fileExists(atPath: downloaded.videoPath) {
        isOffline = true
        resumePosition = forceFromBeginning ? 0 : Double(PlaybackProgress.resumable(
          positionSeconds: downloaded.resumePositionSeconds,
          durationSeconds: downloaded.durationSeconds))
        playbackDuration = Double(downloaded.durationSeconds)
        playbackURL = localURL
        return
      }
    }

    // Fall back to streaming
    do {
      let info = try await appState.api.playback(id: itemID, quality: appState.qualityCap, subtitleOffset: subtitleOffset)
      let url = info.streamUrl ?? info.hlsMasterUrl
      guard let url else {
        error = "No playable URL."
        return
      }
      resumePosition = forceFromBeginning ? 0 : Double(PlaybackProgress.resumable(
        positionSeconds: max(info.resumePositionSeconds, resumeOverrideSeconds),
        durationSeconds: info.durationSeconds ?? 0))
      resumeOverrideSeconds = 0
      resumeOverrideDuration = 0
      chapters = info.chapters ?? []
      subtitles = info.subtitles ?? []
      playbackDuration = Double(info.durationSeconds ?? 0)
      playbackURL = url
    } catch APIError.converting {
      // Server is auto-normalizing this title (TASK-755). Show the informational
      // message; the server was reached, so don't treat it as a connection failure
      // or attempt a reconnect. The user can retry in a few minutes.
      self.error = APIError.converting.userMessage
      return
    } catch {
      // TASK-848: route through handlePlaybackFailure so an expired/revoked token is
      // recognised as auth expiry rather than surfacing a generic "Playback Failed" whose
      // Retry re-fetches with the same dead token forever. It tears the session down
      // identically to handleConnectionFailure and reports whether auth was the cause.
      if appState.handlePlaybackFailure(error) {
        self.error = "Your session expired. Please sign in again."
        return
      }
      // If this was a network failure and the server is a QuickConnect ID,
      // try re-resolving candidates (network context may have changed since login).
      if appState.serverUnreachable, await appState.reconnect() {
        do {
          let info = try await appState.api.playback(id: itemID, quality: appState.qualityCap, subtitleOffset: subtitleOffset)
          let url = info.streamUrl ?? info.hlsMasterUrl
          guard let url else { self.error = "No playable URL."; return }
          resumePosition = forceFromBeginning ? 0 : Double(PlaybackProgress.resumable(
            positionSeconds: max(info.resumePositionSeconds, resumeOverrideSeconds),
            durationSeconds: info.durationSeconds ?? 0))
          resumeOverrideSeconds = 0
          resumeOverrideDuration = 0
          chapters = info.chapters ?? []
          subtitles = info.subtitles ?? []
          playbackDuration = Double(info.durationSeconds ?? 0)
          playbackURL = url
          appState.clearNetworkError()
          return
        } catch {
          appState.handleConnectionFailure(error)
        }
      }
      self.error = (error as? APIError)?.userMessage ?? "Couldn't connect to server."
    }
  }
}

#if os(tvOS)
private struct _NextEpisodeOverlayView: View {
  @Environment(\.theme) private var theme
  let next: ItemSummary
  let countdown: Int
  let onPlayNow: () -> Void
  let onStay: () -> Void

  @Namespace private var ns
  @FocusState private var focused: OverlayButton?
  enum OverlayButton: Hashable { case playNow, stay }

  var body: some View {
    VStack(spacing: 20) {
      Spacer()
      VStack(spacing: 12) {
        Text("UP NEXT")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.7))
        Text(next.title)
          .font(.title3.weight(.semibold))
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)
          .lineLimit(2)
        Text("Playing in \(countdown)s")
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.7))
          .monospacedDigit()
        HStack(spacing: 24) {
          Button(action: onPlayNow) {
            Text("Play Now")
              .font(.headline)
              .foregroundStyle(Color.dsAccentOn)
              .padding(.horizontal, 28)
              .padding(.vertical, 14)
              .background(Color.dsAccent, in: Capsule())
              .brightness(focused == .playNow ? 0.1 : 0)
          }
          .buttonStyle(.plain)
          .focusEffectDisabled()
          .scaleEffect(focused == .playNow ? 1.05 : 1.0)
          .animation(.easeInOut(duration: 0.15), value: focused)
          .focused($focused, equals: .playNow)
          .prefersDefaultFocus(in: ns)

          Button(action: onStay) {
            Text("Stay")
              .font(.headline)
              .foregroundStyle(.white)
              .padding(.horizontal, 28)
              .padding(.vertical, 14)
              .background(Color.white.opacity(focused == .stay ? 0.3 : 0.18), in: Capsule())
          }
          .buttonStyle(.plain)
          .focusEffectDisabled()
          .scaleEffect(focused == .stay ? 1.05 : 1.0)
          .animation(.easeInOut(duration: 0.15), value: focused)
          .focused($focused, equals: .stay)
        }
        .focusScope(ns)
      }
      .padding(28)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: theme.radiusLg))
      .padding(.horizontal, 32)
      .padding(.bottom, 60)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black.opacity(0.45).ignoresSafeArea())
    .transition(.opacity)
    .animation(.easeInOut(duration: 0.25), value: countdown)
    .onAppear {
      // This overlay is a ZStack layer over the player, not a sheet/cover, so tvOS
      // does not automatically move focus into its focusScope — prefersDefaultFocus
      // alone won't fire. Claim focus explicitly so a Select press during the
      // countdown hits "Play Now" instead of falling through to the player beneath.
      DispatchQueue.main.async { focused = .playNow }
    }
  }
}
#endif
