//
//  MediaCatalog.swift
//  StalkerDesk
//
//  Movies and Web Series browser/detail experience, plus the player-only
//  fullscreen presentation shared by live and VOD playback.
//

import StalkerDeskCore
import SwiftUI

// MARK: - Browser (middle column)

struct MediaBrowserPane: View {
    @EnvironmentObject private var appState: AppState
    @Binding var searchText: String

    private var filteredItems: [StalkerMediaItem] {
        let items = appState.mediaItems
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || ($0.genre?.localizedCaseInsensitiveContains(searchText) ?? false)
                || ($0.year?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .navigationTitle(appState.selectedGenre?.title ?? appState.contentMode.title)
        .navigationSubtitle(appState.activePortal?.name ?? "")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.selectedGenre?.title ?? appState.contentMode.title)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(countLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if appState.selectedGenre != nil {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search \(appState.contentMode.title.lowercased())", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55))
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        if appState.isRetryingGenres && appState.genres.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading video categories…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appState.genres.isEmpty {
            ActionEmptyView(
                symbol: "film",
                title: "Video categories unavailable",
                message: "The portal did not return movie/series categories, or the request was rate-limited.",
                actionTitle: "Retry Categories",
                action: { appState.reloadGenres() }
            )
        } else if appState.selectedGenre == nil {
            EmptyColumnView(
                symbol: appState.contentMode.symbolName,
                title: "Choose a category",
                message: "Select a \(appState.contentMode.title.lowercased()) category in the sidebar."
            )
        } else if appState.isLoadingMedia {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading \(appState.contentMode.title.lowercased())…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appState.mediaItems.isEmpty {
            EmptyColumnView(
                symbol: appState.contentMode == .movies ? "film" : "rectangle.stack.badge.play",
                title: "Nothing here yet",
                message: "This category has no \(appState.contentMode == .movies ? "movies" : "web series") for this portal."
            )
        } else if filteredItems.isEmpty {
            EmptyColumnView(
                symbol: "magnifyingglass",
                title: "No matches",
                message: "No titles match “\(searchText)”."
            )
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(filteredItems) { item in
                        MediaCard(
                            item: item,
                            isSelected: appState.selectedMedia?.id == item.id
                        ) {
                            appState.selectMedia(item)
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private var countLabel: String {
        if appState.isLoadingMedia { return "Loading…" }
        if appState.mediaItems.isEmpty { return appState.contentMode.title }
        return "\(appState.mediaItems.count) \(appState.contentMode == .movies ? "movies" : "series")"
    }
}

private struct MediaCard: View {
    let item: StalkerMediaItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.black.opacity(0.25))
                    AsyncImage(url: item.posterURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            posterPlaceholder
                        case .empty:
                            ProgressView()
                                .controlSize(.small)
                        @unknown default:
                            posterPlaceholder
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                    if item.isSeries {
                        Text("SERIES")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.4)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.72), in: Capsule())
                            .padding(7)
                    }
                }
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.06), lineWidth: isSelected ? 2 : 1)
                }

                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    if let year = item.yearLabel {
                        Text(year)
                    }
                    if let rating = item.ratingLabel {
                        Text(rating)
                            .foregroundStyle(.yellow.opacity(0.9))
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 11)
            )
        }
        .buttonStyle(.plain)
    }

    private var posterPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.22), Color.black.opacity(0.4)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: item.isSeries ? "rectangle.stack.badge.play" : "film")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.65))
        }
    }
}

// MARK: - Detail (right column)

struct MediaDetailPane: View {
    @ObservedObject var player: PlayerCoordinator
    @EnvironmentObject private var appState: AppState
    var isSurfaceActive: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            if player.currentRequest != nil || appState.isResolvingStream {
                playerStage
                playerControls
                Divider()
            }

            if let media = appState.selectedMedia {
                MediaMetadataView(media: media, player: player)
                    .environmentObject(appState)
            } else {
                EmptyColumnView(
                    symbol: appState.contentMode.symbolName,
                    title: "Select \(appState.contentMode == .movies ? "a movie" : "a series")",
                    message: "Choose a title from the list to see details and start playback."
                )
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var playerStage: some View {
        ZStack {
            Color.black
            PlayerSurface(player: player, isActive: isSurfaceActive)

            if appState.isResolvingStream || player.state == .preparing {
                VStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    Text("Preparing stream…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
            } else if player.state == .buffering {
                ProgressView()
                    .tint(.white)
            }

            if case .failed(let message) = player.state {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Button("Try Again") {
                        appState.retryPlayback()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(80)
            }

            VStack {
                HStack {
                    Text(player.currentRequest?.title ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    Text(player.engineKind.rawValue)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.13), in: Capsule())
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 24)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.65), .black.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                Spacer()
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var playerControls: some View {
        VStack(spacing: 3) {
            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 1)
            )
            .controlSize(.mini)
            .padding(.horizontal, 12)

            HStack(spacing: 13) {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                        .frame(width: 22)
                }
                .buttonStyle(.borderless)

                Button {
                    player.toggleMute()
                } label: {
                    Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.borderless)

                Text(timeLabel(player.currentTime))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("/")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(timeLabel(player.duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Menu {
                    ForEach(PlayerAspectRatio.allCases) { ratio in
                        Button {
                            player.setAspectRatio(ratio)
                        } label: {
                            if ratio == player.aspectRatio {
                                Label(ratio.displayName, systemImage: "checkmark")
                            } else {
                                Label(ratio.displayName, systemImage: ratio.symbolName)
                            }
                        }
                    }
                } label: {
                    Image(systemName: player.aspectRatio.symbolName)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    player.togglePictureInPicture()
                } label: {
                    Image(systemName: player.isPiPActive ? "pip.exit" : "pip.enter")
                }
                .buttonStyle(.borderless)
                .disabled(!player.isPiPAvailable && !player.isPiPActive)

                Button {
                    player.toggleFullscreen()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Fullscreen (F)")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

private struct MediaMetadataView: View {
    let media: StalkerMediaItem
    @EnvironmentObject private var appState: AppState
    @ObservedObject var player: PlayerCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    AsyncImage(url: media.posterURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            ZStack {
                                Color.accentColor.opacity(0.15)
                                Image(systemName: media.isSeries ? "rectangle.stack.badge.play" : "film")
                                    .font(.system(size: 34, weight: .light))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 150, height: 225)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.white.opacity(0.07))
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        Text(media.name)
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                        HStack(spacing: 10) {
                            if let year = media.yearLabel { Text(year) }
                            if let rating = media.ratingLabel { Text(rating).foregroundStyle(.yellow) }
                            if let duration = media.durationLabel { Text(duration) }
                            Text(media.isSeries ? "Web Series" : "Movie")
                                .foregroundStyle(Color.accentColor)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if let genre = media.genre {
                            Text(genre)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !media.description.isEmpty {
                            Text(media.description)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(6)
                        }

                        if media.isMovie {
                            Button {
                                appState.playSelectedMedia()
                            } label: {
                                Label(player.currentRequest?.channelID == media.id ? "Restart Movie" : "Play Movie",
                                      systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if media.isSeries {
                    seriesDetail(media: media)
                }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func seriesDetail(media: StalkerMediaItem) -> some View {
        Divider()

        if appState.isLoadingSeriesDetail && appState.seasons.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading seasons…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if !appState.seasons.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("Seasons")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(appState.seasons) { season in
                            Button {
                                appState.selectSeason(season)
                            } label: {
                                Text(season.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        appState.selectedSeason?.id == season.id
                                            ? Color.accentColor.opacity(0.2)
                                            : Color(nsColor: .controlBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 7)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 7)
                                            .strokeBorder(
                                                appState.selectedSeason?.id == season.id
                                                    ? Color.accentColor
                                                    : Color(nsColor: .separatorColor).opacity(0.4)
                                            )
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }

                SectionTitle("Episodes")
                if appState.isLoadingSeriesDetail {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 8)
                } else if appState.episodes.isEmpty {
                    Text("No episodes returned for this season.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 1) {
                        ForEach(Array(appState.episodes.enumerated()), id: \.element.id) { index, episode in
                            EpisodeRow(
                                index: index + 1,
                                episode: episode,
                                isSelected: appState.selectedEpisode?.id == episode.id
                            ) {
                                appState.selectEpisode(episode)
                            }
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4))
                    }
                }
            }
        } else if let errorMessage = appState.errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct EpisodeRow: View {
    let index: Int
    let episode: StalkerMediaItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Text(String(format: "%02d", index))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 24, alignment: .trailing)

                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if !episode.description.isEmpty {
                        Text(episode.description)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                if let duration = episode.durationLabel {
                    Text(duration)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: isSelected ? "waveform" : "play.circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Fullscreen

struct FullscreenPlayerView: View {
    @ObservedObject var player: PlayerCoordinator
    @EnvironmentObject private var appState: AppState
    let onExit: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerSurface(player: player)

            if appState.isResolvingStream || player.state == .preparing || player.state == .buffering {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            if case .failed(let message) = player.state {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.82))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                    HStack {
                        Button("Try Again") {
                            appState.retryPlayback()
                        }
                        Button("Exit Fullscreen") {
                            onExit()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(28)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
            }

            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.currentRequest?.title ?? "Arya IPTV Portal")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(player.currentRequest?.subtitle ?? "")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Button {
                        onExit()
                    } label: {
                        Label("Exit Fullscreen", systemImage: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Exit fullscreen")
                }
                .padding(20)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.75), .black.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Spacer()

                HStack(spacing: 16) {
                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.toggleMute()
                    } label: {
                        Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Slider(
                        value: Binding(
                            get: { player.volume },
                            set: { player.setVolume($0) }
                        ),
                        in: 0...1
                    )
                    .frame(width: 100)
                    .controlSize(.mini)

                    if !player.isLive {
                        Slider(
                            value: Binding(
                                get: { player.currentTime },
                                set: { player.seek(to: $0) }
                            ),
                            in: 0...max(player.duration, 1)
                        )
                        .frame(width: 240)
                        .controlSize(.mini)
                    }

                    Spacer()

                    Menu {
                        ForEach(PlayerAspectRatio.allCases) { ratio in
                            Button(ratio.displayName) {
                                player.setAspectRatio(ratio)
                            }
                        }
                    } label: {
                        Label(player.aspectRatio.displayName, systemImage: player.aspectRatio.symbolName)
                            .foregroundStyle(.white)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Button {
                        player.togglePictureInPicture()
                    } label: {
                        Image(systemName: player.isPiPActive ? "pip.exit" : "pip.enter")
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(!player.isPiPAvailable && !player.isPiPActive)

                    Button {
                        onExit()
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(.black.opacity(0.62))
            }
        }
        .ignoresSafeArea()
    }
}
