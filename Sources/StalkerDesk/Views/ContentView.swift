//
//  ContentView.swift
//  StalkerDesk
//
//  A couch-first, Apple TV-style browsing shell:
//  top navigation + large category rail + content shelves, with a full-width
//  detail/player stage. Layout uses only cross-platform SwiftUI so the same
//  structure can be reused by a future tvOS target.
//

import StalkerDeskCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var portalStore: PortalStore

    @State private var searchText = ""
    @State private var showPortalManager = false
    @State private var showAddPortal = false

    private var isShowingDetail: Bool {
        if appState.selectedChannel != nil { return true }
        return appState.isVideoMode && appState.selectedMedia != nil
    }

    var body: some View {
        ZStack {
            TVTheme.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                if isShowingDetail {
                    detailStage
                } else {
                    browseStage
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(TVTheme.accent)
        .task {
            await appState.bootstrap()
        }
        .onAppear {
            if appState.selectedChannel != nil || appState.selectedMedia != nil {
                appState.player.beginKeyboardMonitoring()
            }
        }
        .onChange(of: appState.selectedChannel) { channel in
            if channel == nil, appState.selectedMedia == nil {
                appState.player.stopKeyboardMonitoring()
            } else {
                appState.player.beginKeyboardMonitoring()
            }
        }
        .onChange(of: appState.selectedMedia) { media in
            if media == nil, appState.selectedChannel == nil {
                appState.player.stopKeyboardMonitoring()
            } else {
                appState.player.beginKeyboardMonitoring()
            }
        }
        .onChange(of: appState.contentMode) { _ in
            searchText = ""
        }
        .onChange(of: appState.isFullscreen) { isFullscreen in
            if !isFullscreen {
                appState.player.restorePrimarySurface()
            }
        }
        .onDisappear {
            appState.player.stopKeyboardMonitoring()
        }
        .sheet(isPresented: $showPortalManager) {
            PortalManagerView()
                .environmentObject(appState)
                .environmentObject(portalStore)
        }
        .sheet(isPresented: $showAddPortal) {
            PortalEditorView(draft: .newProfile()) { saved in
                if appState.activePortal == nil {
                    appState.connect(to: saved)
                }
            }
            .environmentObject(portalStore)
        }
        .alert("Arya IPTV Portal", isPresented: errorPresented) {
            Button("OK") { appState.clearError() }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }

    // MARK: Top navigation

    private var topBar: some View {
        HStack(spacing: 18) {
            brand
            portalMenu

            Spacer(minLength: 8)

            modeTabs

            Spacer(minLength: 8)

            if !isShowingDetail {
                searchField
                    .frame(width: 230)
            }

            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(TVTheme.secondaryText)
            }

            Button {
                appState.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(TVTheme.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Refresh")
            .disabled(appState.activePortal == nil)

            Menu {
                Button("Manage Portals…") { showPortalManager = true }
                Button("Add Portal…") { showAddPortal = true }
                Divider()
                Button("Reconnect") { appState.retryConnection() }
                    .disabled(appState.activePortal == nil)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(TVTheme.surface, in: Circle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 13)
        .background(.black.opacity(0.24))
        .overlay(alignment: .bottom) {
            Rectangle().fill(TVTheme.hairline).frame(height: 1)
        }
    }

    private var brand: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(
                        colors: [TVTheme.accent, TVTheme.accentDim],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(.black)
                    .offset(x: 1)
            }
            .frame(width: 30, height: 30)

            Text("Arya IPTV Portal")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private var portalMenu: some View {
        Menu {
            if portalStore.profiles.isEmpty {
                Text("No saved portals")
            } else {
                ForEach(portalStore.profiles) { profile in
                    Button {
                        appState.connect(to: profile)
                    } label: {
                        if appState.activePortal?.id == profile.id {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
            }
            Divider()
            Button("Manage Portals…") { showPortalManager = true }
            Button("Add Portal…") { showAddPortal = true }
        } label: {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("PORTAL")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(TVTheme.tertiaryText)
                    Text(appState.activePortal?.name ?? "Choose portal")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(TVTheme.secondaryText)
            }
            .frame(minWidth: 95, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var modeTabs: some View {
        HStack(spacing: 3) {
            ForEach(StalkerContentMode.allCases) { mode in
                Button {
                    appState.selectMode(mode)
                } label: {
                    Text(mode.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(appState.contentMode == mode ? Color.black : Color.white.opacity(0.78))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                        .background(
                            appState.contentMode == mode ? TVTheme.accent : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(appState.activePortal == nil)
            }
        }
        .padding(4)
        .background(TVTheme.surface, in: Capsule())
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TVTheme.secondaryText)
            TextField(searchPlaceholder, text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(TVTheme.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(TVTheme.surface, in: Capsule())
        .overlay {
            Capsule().strokeBorder(TVTheme.hairline, lineWidth: 1)
        }
    }

    // MARK: Browse

    private var browseStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if appState.activePortal == nil {
                    onboardingHero
                } else if appState.connectionState == .connecting {
                    connectingHero
                } else {
                    categoryRail

                    if let genre = appState.selectedGenre {
                        contentShelf(genre: genre)
                    } else {
                        categoryShelf
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
            .frame(maxWidth: 1500, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var categoryRail: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(appState.contentMode.title) Categories")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(appState.selectedGenre == nil ? "Pick a category to start browsing" : "Swipe through genres")
                        .font(.system(size: 12))
                        .foregroundStyle(TVTheme.tertiaryText)
                }
                Spacer()
                if appState.isRetryingGenres {
                    ProgressView().controlSize(.small)
                } else if !appState.genres.isEmpty {
                    Text("\(appState.genres.count) categories")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TVTheme.tertiaryText)
                }
            }

            if appState.isRetryingGenres && appState.genres.isEmpty {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Loading categories…")
                        .font(.system(size: 13))
                        .foregroundStyle(TVTheme.secondaryText)
                }
                .padding(.vertical, 10)
            } else if appState.genres.isEmpty {
                HStack(spacing: 10) {
                    Text("Categories are unavailable.")
                        .font(.system(size: 13))
                        .foregroundStyle(TVTheme.secondaryText)
                    Button("Retry") { appState.reloadGenres() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(TVTheme.accent)
                }
                .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(filteredCategories) { genre in
                            TVCategoryPill(
                                title: genre.title,
                                isSelected: appState.selectedGenre?.id == genre.id
                            ) {
                                appState.selectGenre(genre)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var categoryShelf: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Browse \(appState.contentMode.title)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
            }

            if filteredCategories.isEmpty {
                TVEmptyState(
                    symbol: "square.grid.2x2",
                    title: "No categories",
                    message: "This portal did not return any categories for \(appState.contentMode.title).",
                    actionTitle: "Retry",
                    action: { appState.reloadGenres() }
                )
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(filteredCategories) { genre in
                        CategoryTile(mode: appState.contentMode, title: genre.title) {
                            appState.selectGenre(genre)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func contentShelf(genre: StalkerGenre) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(genre.title)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(contentCountLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TVTheme.secondaryText)
                }
                Spacer()

                if appState.isVideoMode {
                    Menu {
                        ForEach(MediaSortOrder.allCases) { order in
                            Button {
                                appState.setMediaSortOrder(order)
                            } label: {
                                if order == appState.mediaSortOrder {
                                    Label(order.displayName, systemImage: "checkmark")
                                } else {
                                    Label(order.displayName, systemImage: order.symbolName)
                                }
                            }
                        }
                    } label: {
                        Label(appState.mediaSortOrder.displayName, systemImage: "arrow.up.arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(TVTheme.surface, in: Capsule())
                            .overlay {
                                Capsule().strokeBorder(TVTheme.hairline, lineWidth: 1)
                            }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Sort videos")
                }
            }

            if appState.contentMode == .live {
                liveContent
            } else {
                videoContent
            }
        }
    }

    @ViewBuilder
    private var liveContent: some View {
        if appState.isLoadingChannels {
            LoadingShelf(label: "Loading channels…")
        } else if filteredChannels.isEmpty {
            TVEmptyState(
                symbol: "tv.slash",
                title: "No channels",
                message: "This category returned no live channels, or the filter has no matches."
            )
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 16)],
                spacing: 16
            ) {
                ForEach(filteredChannels) { channel in
                    ChannelTile(channel: channel) {
                        appState.selectChannel(channel)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var videoContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let warning = appState.mediaLoadWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange.opacity(0.9))
            }

            if appState.isLoadingMedia {
                LoadingShelf(label: "Loading \(appState.contentMode.title.lowercased())…")
            } else if filteredMedia.isEmpty {
                if appState.isLoadingMoreMedia {
                    LoadingShelf(label: "Loading more titles…")
                } else {
                    TVEmptyState(
                        symbol: appState.contentMode == .movies ? "film" : "rectangle.stack.badge.play",
                        title: "Nothing here",
                        message: "This category has no \(appState.contentMode == .movies ? "movies" : "series") for this portal."
                    )
                }
            } else {
                if appState.isLoadingMoreMedia {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading more titles…")
                            .font(.system(size: 11))
                            .foregroundStyle(TVTheme.tertiaryText)
                    }
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 156, maximum: 200), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(filteredMedia) { media in
                        PosterTile(media: media) {
                            appState.selectMedia(media)
                        }
                    }
                }
            }
        }
    }

    private var onboardingHero: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your portal.\nBig-screen ready.")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Live TV, movies and web series in a single ten-foot interface. Built with native macOS playback and designed to translate to tvOS.")
                    .font(.system(size: 16))
                    .foregroundStyle(TVTheme.secondaryText)
                    .frame(maxWidth: 650, alignment: .leading)
            }

            HStack(spacing: 12) {
                if portalStore.profiles.isEmpty {
                    Button("Add Portal") { showAddPortal = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(TVTheme.accent)
                } else {
                    Button("Manage Portals") { showPortalManager = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(TVTheme.accent)
                    if let profile = portalStore.defaultProfile {
                        Button("Connect \(profile.name)") {
                            appState.connect(to: profile)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
            }

            HStack(spacing: 26) {
                FeaturePill(symbol: "tv", title: "Live TV")
                FeaturePill(symbol: "film", title: "Movies")
                FeaturePill(symbol: "play.tv", title: "Web Series")
            }
            .padding(.top, 8)
        }
        .padding(.vertical, 36)
    }

    private var connectingHero: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting to \(appState.activePortal?.name ?? "portal")…")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("Authenticating the MAG device and loading categories")
                .font(.system(size: 13))
                .foregroundStyle(TVTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 120)
    }

    // MARK: Detail

    private var detailStage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    appState.dismissDetail()
                } label: {
                    Label("Browse", systemImage: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(TVTheme.surface, in: Capsule())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(detailTitle)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(detailSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(TVTheme.tertiaryText)
                        .lineLimit(1)
                }

                Spacer()

                if appState.player.isLive {
                    Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 9, weight: .black))
                        .tracking(0.5)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(TVTheme.surface, in: Capsule())
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 11)

            Rectangle().fill(TVTheme.hairline).frame(height: 1)

            if let channel = appState.selectedChannel {
                PlayerPane(
                    player: appState.player,
                    channel: channel,
                    isSurfaceActive: !appState.isFullscreen
                )
                .environmentObject(appState)
            } else if appState.isVideoMode, let media = appState.selectedMedia {
                MediaDetailPane(
                    player: appState.player,
                    isSurfaceActive: !appState.isFullscreen
                )
                .environmentObject(appState)
                .id(media.id)
            }
        }
    }

    // MARK: Computed

    private var filteredCategories: [StalkerGenre] {
        let categories = appState.genres
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return categories }
        return categories.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredChannels: [StalkerChannel] {
        let channels = appState.channels
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return channels }
        return channels.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.displayNumber.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredMedia: [StalkerMediaItem] {
        let items = appState.sortedMediaItems
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || ($0.genre?.localizedCaseInsensitiveContains(searchText) ?? false)
                || ($0.year?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var searchPlaceholder: String {
        switch appState.contentMode {
        case .live: return "Search channels"
        case .movies: return "Search movies"
        case .series: return "Search series"
        }
    }

    private var contentCountLabel: String {
        switch appState.contentMode {
        case .live:
            return appState.isLoadingChannels ? "Loading…" : "\(appState.channels.count) channels"
        case .movies, .series:
            if appState.isLoadingMedia { return "Loading…" }
            if appState.isLoadingMoreMedia {
                return "\(appState.mediaItems.count)+ titles · loading more"
            }
            return "\(appState.mediaItems.count) titles"
        }
    }

    private var detailTitle: String {
        if let channel = appState.selectedChannel { return channel.name }
        if let media = appState.selectedMedia { return media.name }
        return "Now Playing"
    }

    private var detailSubtitle: String {
        if let channel = appState.selectedChannel {
            return channel.displayNumber.isEmpty ? "Live TV" : "Channel \(channel.displayNumber)"
        }
        if let media = appState.selectedMedia {
            return media.isSeries ? "Web Series" : "Movie"
        }
        return ""
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.clearError() } }
        )
    }

    private var statusColor: Color {
        switch appState.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return appState.activePortal == nil ? .secondary : .red
        }
    }

    private var statusText: String {
        switch appState.connectionState {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnected: return appState.activePortal == nil ? "Offline" : "Disconnected"
        }
    }
}

// MARK: - Browse cards

private struct CategoryTile: View {
    let mode: StalkerContentMode
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(TVTheme.accent.opacity(0.16))
                    Image(systemName: mode.symbolName)
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(TVTheme.accent)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(mode.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TVTheme.tertiaryText)
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TVTheme.tertiaryText)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TVTheme.surface, in: RoundedRectangle(cornerRadius: TVTheme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: TVTheme.cardRadius)
                    .strokeBorder(TVTheme.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .tvHoverScale()
    }
}

private struct ChannelTile: View {
    let channel: StalkerChannel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: TVTheme.cardRadius)
                    .fill(LinearGradient(
                        colors: [
                            Color.white.opacity(0.09),
                            Color.white.opacity(0.025)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))

                AsyncImage(url: channel.logoURL) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(28)
                    } else {
                        Image(systemName: "tv")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(TVTheme.tertiaryText)
                    }
                }

                LinearGradient(
                    colors: [.clear, .black.opacity(0.82)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: TVTheme.cardRadius))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(.red)
                            .frame(width: 5, height: 5)
                        Text("LIVE")
                            .font(.system(size: 8, weight: .black))
                            .tracking(0.5)
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        if channel.isHD {
                            Text("HD")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    Text(channel.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !channel.displayNumber.isEmpty {
                        Text("Channel \(channel.displayNumber)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .padding(12)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: TVTheme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: TVTheme.cardRadius)
                    .strokeBorder(TVTheme.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .tvHoverScale()
    }
}

private struct PosterTile: View {
    let media: StalkerMediaItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: TVTheme.cardRadius)
                        .fill(Color.black.opacity(0.25))
                    AsyncImage(url: media.posterURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            ZStack {
                                LinearGradient(
                                    colors: [TVTheme.accent.opacity(0.22), Color.black.opacity(0.45)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                Image(systemName: media.isSeries ? "rectangle.stack.badge.play" : "film")
                                    .font(.system(size: 32, weight: .light))
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: TVTheme.cardRadius))

                    if media.isSeries {
                        Text("SERIES")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.4)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.72), in: Capsule())
                            .padding(8)
                    }
                }
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: TVTheme.cardRadius)
                        .strokeBorder(TVTheme.hairline, lineWidth: 1)
                }

                Text(media.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 7) {
                    if let year = media.yearLabel { Text(year) }
                    if let rating = media.ratingLabel {
                        Text(rating).foregroundStyle(.yellow.opacity(0.9))
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10))
                .foregroundStyle(TVTheme.secondaryText)

                if let added = media.addedLabel {
                    Text(added)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(TVTheme.tertiaryText)
                }
            }
            .padding(9)
            .background(TVTheme.surface, in: RoundedRectangle(cornerRadius: TVTheme.cardRadius + 3))
            .overlay {
                RoundedRectangle(cornerRadius: TVTheme.cardRadius + 3)
                    .strokeBorder(TVTheme.hairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .tvHoverScale()
    }
}

private struct FeaturePill: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(TVTheme.accent)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TVTheme.secondaryText)
        }
    }
}

private struct LoadingShelf: View {
    let label: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(TVTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }
}

// MARK: - Shared support views

struct EmptyColumnView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        TVEmptyState(symbol: symbol, title: title, message: message)
    }
}

struct ActionEmptyView: View {
    let symbol: String
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        TVEmptyState(
            symbol: symbol,
            title: title,
            message: message,
            actionTitle: actionTitle,
            action: action
        )
    }
}

struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(TVTheme.secondaryText)
    }
}
