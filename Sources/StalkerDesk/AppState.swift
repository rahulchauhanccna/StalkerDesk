//
//  AppState.swift
//  StalkerDesk
//
//  Coordinates portal connection, catalog loading, EPG and playback. All UI
//  state lives on the main actor; network work is isolated inside StalkerClient.
//

import Combine
import Foundation
import StalkerDeskCore

enum MediaSortOrder: String, CaseIterable, Identifiable {
    case recentlyAdded
    case title
    case year
    case rating

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recentlyAdded: return "Recently Added"
        case .title: return "Title A–Z"
        case .year: return "Year"
        case .rating: return "Rating"
        }
    }

    var symbolName: String {
        switch self {
        case .recentlyAdded: return "clock.arrow.circlepath"
        case .title: return "textformat.abc"
        case .year: return "calendar"
        case .rating: return "star"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected

        var isConnected: Bool { self == .connected }
    }

    @Published private(set) var activePortal: PortalProfile?
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var session: PortalSession?
    @Published private(set) var contentMode: StalkerContentMode = .live
    @Published private(set) var genres: [StalkerGenre] = []
    @Published private(set) var selectedGenre: StalkerGenre?
    @Published private(set) var channels: [StalkerChannel] = []
    @Published private(set) var selectedChannel: StalkerChannel?
    @Published private(set) var mediaItems: [StalkerMediaItem] = []
    @Published private(set) var mediaSortOrder: MediaSortOrder = .recentlyAdded
    @Published private(set) var selectedMedia: StalkerMediaItem?
    @Published private(set) var seasons: [StalkerMediaItem] = []
    @Published private(set) var selectedSeason: StalkerMediaItem?
    @Published private(set) var episodes: [StalkerMediaItem] = []
    @Published private(set) var selectedEpisode: StalkerMediaItem?
    @Published private(set) var epgPrograms: [StalkerEPGProgram] = []
    @Published private(set) var isLoadingChannels = false
    @Published private(set) var isLoadingMedia = false
    @Published private(set) var isLoadingMoreMedia = false
    @Published private(set) var mediaLoadWarning: String?
    @Published private(set) var isLoadingSeriesDetail = false
    @Published private(set) var isLoadingEPG = false
    @Published private(set) var isResolvingStream = false
    @Published private(set) var isRetryingGenres = false
    @Published private(set) var epgError: String?
    @Published private(set) var isFullscreen = false
    @Published var errorMessage: String?

    let player = PlayerCoordinator()
    let portalStore: PortalStore

    private var client: StalkerClient?
    private var connectTask: Task<Void, Never>?
    private var genresTask: Task<Void, Never>?
    private var channelTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    private var seriesTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var epgTask: Task<Void, Never>?
    private var connectionID = UUID()
    private var didBootstrap = false
    private var autoRepairedProfiles = Set<UUID>()
    private var vodCategoriesCache: [StalkerGenre] = []
    private var cancellables = Set<AnyCancellable>()
    private lazy var fullscreenWindow = FullscreenWindowController(player: player, appState: self)
    private static let lastPortalKey = "StalkerDesk.lastPortalID"

    init(portalStore: PortalStore) {
        self.portalStore = portalStore
        player.onNextChannel = { [weak self] in
            self?.stepChannel(by: 1)
        }
        player.onPreviousChannel = { [weak self] in
            self?.stepChannel(by: -1)
        }
        player.onToggleFullscreen = { [weak self] in
            self?.toggleFullscreenPresentation()
        }
        player.$isFullScreen
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isFullscreen in
                guard let self, self.isFullscreen != isFullscreen else { return }
                AppLog.info("Fullscreen state: \(isFullscreen)")
                self.isFullscreen = isFullscreen
            }
            .store(in: &cancellables)

        player.$state
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { state in
                AppLog.info("Player state: \(Self.describe(state))")
                if case .failed(let message) = state {
                    AppLog.error("Player error: \(message)")
                }
            }
            .store(in: &cancellables)
    }

    func toggleFullscreenPresentation() {
        fullscreenWindow.toggle()
    }

    private static func describe(_ state: PlaybackState) -> String {
        switch state {
        case .idle: return "idle"
        case .preparing: return "preparing"
        case .buffering: return "buffering"
        case .playing: return "playing"
        case .paused: return "paused"
        case .ended: return "ended"
        case .failed(let message): return "failed: \(message)"
        }
    }

    // MARK: Bootstrap

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await portalStore.waitUntilReady()
        repairLegacyGeneratedIdentitiesIfNeeded()

        guard activePortal == nil else { return }
        let storedID = UserDefaults.standard.string(forKey: Self.lastPortalKey).flatMap(UUID.init(uuidString:))
        let profile = portalStore.profiles.first { $0.id == storedID }
            ?? portalStore.defaultProfile

        if let profile {
            connect(to: profile)
        }
    }

    func portalConfigurationDidChange() {
        guard let activePortal else { return }
        guard let updated = portalStore.profiles.first(where: { $0.id == activePortal.id }) else {
            disconnect()
            return
        }
        if updated != activePortal {
            connect(to: updated)
        }
    }

    // MARK: Connection

    func connect(to profile: PortalProfile) {
        AppLog.info("Connecting portal '\(profile.name)' url=\(profile.portalURL) mac=\(profile.normalizedMAC)")
        connectTask?.cancel()
        genresTask?.cancel()
        channelTask?.cancel()
        mediaTask?.cancel()
        seriesTask?.cancel()
        streamTask?.cancel()
        epgTask?.cancel()
        player.stop()

        let generation = UUID()
        connectionID = generation
        activePortal = profile
        connectionState = .connecting
        session = nil
        contentMode = .live
        vodCategoriesCache = []
        genres = []
        selectedGenre = nil
        channels = []
        selectedChannel = nil
        mediaItems = []
        selectedMedia = nil
        seasons = []
        selectedSeason = nil
        episodes = []
        selectedEpisode = nil
        epgPrograms = []
        epgError = nil
        isResolvingStream = false
        isRetryingGenres = false
        isLoadingMedia = false
        isLoadingSeriesDetail = false
        errorMessage = nil
        UserDefaults.standard.set(profile.id.uuidString, forKey: Self.lastPortalKey)

        // A restored Keychain token has been observed to pass get_profile but
        // fail get_genres with "Authorization failed." on some Ministra
        // deployments. Prefer a clean handshake; token refresh within the
        // session still happens automatically on 401/session expiry.
        let client = StalkerClient(sessionCache: nil)
        self.client = client
        let credentials = portalStore.credentials(for: profile)
        let resolvedCredentials = credentials.isEmpty ? nil : credentials

        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await client.connect(
                    profile: profile,
                    credentials: resolvedCredentials
                )
                guard self.connectionID == generation, !Task.isCancelled else { return }

                self.session = session
                self.connectionState = .connected
                self.portalStore.markConnected(profile)
                AppLog.info("Connected endpoint=\(session.endpoint.absoluteString) id=\(session.userProfile.id ?? "nil") name=\(session.userProfile.name ?? "nil") login=\(session.userProfile.login ?? "nil")")

                do {
                    let fetched = try await self.fetchCategoriesWithRetry(client: client, mode: .live, generation: generation)
                    guard self.connectionID == generation, !Task.isCancelled else { return }
                    self.genres = [.all] + fetched
                    // Do not auto-fetch "All Channels" on connect. That can mean
                    // hundreds of pages and immediately exhaust portal rate limits.
                    self.selectedGenre = nil
                    AppLog.info("Loaded \(fetched.count) genres")
                } catch {
                    guard self.connectionID == generation, !Task.isCancelled else { return }
                    self.isRetryingGenres = false
                    AppLog.error("Genre load failed: \(error.localizedDescription)")
                    if case StalkerError.rateLimited = error {
                        self.errorMessage = "Connected, but the portal is rate-limiting category requests. Wait about a minute, then press Retry Categories."
                    } else {
                        self.errorMessage = Self.message(for: error, prefix: "Connected, but genres could not be loaded.")
                    }
                }
            } catch {
                guard self.connectionID == generation, !Task.isCancelled else { return }
                if case StalkerError.cancelled = error { return }

                if self.attemptGeneratedIdentityRepair(for: profile, error: error) {
                    return
                }

                self.connectionState = .disconnected
                AppLog.error("Connection failed: \(error.localizedDescription)")
                self.errorMessage = Self.message(for: error, prefix: "Could not connect to \(profile.name).")
            }
        }
    }

    /// One-time migration for profiles saved by early builds. Editing the MAC
    /// did not regenerate the derived device ID/serial, so handshake succeeded
    /// while get_profile/get_genres failed. App-generated values are exactly
    /// 64/13 uppercase hex chars; custom provider values outside that shape are
    /// never touched. The editor now keeps derived identities in sync.
    private func repairLegacyGeneratedIdentitiesIfNeeded() {
        let migrationKey = "StalkerDesk.didRepairLegacyGeneratedIdentitiesV1"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        UserDefaults.standard.set(true, forKey: migrationKey)

        for profile in portalStore.profiles {
            guard let mac = MACAddress(profile.macAddress) else { continue }
            let expectedDeviceID = DeviceIdentity.defaultDeviceID(for: mac)
            let expectedSerial = DeviceIdentity.defaultSerial(for: mac)
            guard profile.deviceID.caseInsensitiveCompare(expectedDeviceID) != .orderedSame
                    || profile.serialNumber.caseInsensitiveCompare(expectedSerial) != .orderedSame else {
                continue
            }

            let deviceLooksGenerated = profile.deviceID.count == 64 && profile.deviceID.allSatisfy(\.isHexDigit)
            let serialLooksGenerated = profile.serialNumber.count == 13 && profile.serialNumber.allSatisfy(\.isHexDigit)
            guard deviceLooksGenerated, serialLooksGenerated else { continue }

            _ = portalStore.updateDeviceIdentity(
                profileID: profile.id,
                deviceID: expectedDeviceID,
                serialNumber: expectedSerial
            )
            AppLog.warning("Migrated legacy MAC-derived identity for portal '\(profile.name)'")
        }
    }

    /// Older builds could leave a device ID/serial generated from a previous
    /// MAC after the user edited the MAC field. That passes handshake but makes
    /// get_profile return an empty object and get_genres return Authorization
    /// failed. Repair the app-generated identity once and reconnect.
    private func attemptGeneratedIdentityRepair(for profile: PortalProfile, error: Error) -> Bool {
        guard let stalkerError = error as? StalkerError,
              case .unauthorized = stalkerError,
              !autoRepairedProfiles.contains(profile.id),
              let mac = MACAddress(profile.macAddress) else {
            return false
        }

        let expectedDeviceID = DeviceIdentity.defaultDeviceID(for: mac)
        let expectedSerial = DeviceIdentity.defaultSerial(for: mac)
        let mismatch = profile.deviceID.caseInsensitiveCompare(expectedDeviceID) != .orderedSame
            || profile.serialNumber.caseInsensitiveCompare(expectedSerial) != .orderedSame
        guard mismatch else { return false }

        guard let repaired = portalStore.updateDeviceIdentity(
            profileID: profile.id,
            deviceID: expectedDeviceID,
            serialNumber: expectedSerial
        ) else {
            return false
        }

        autoRepairedProfiles.insert(profile.id)
        AppLog.warning("Repaired MAC-derived device identity for portal '\(profile.name)'")
        Task { @MainActor [weak self] in
            self?.connect(to: repaired)
        }
        return true
    }

    func disconnect() {
        connectionID = UUID()
        connectTask?.cancel()
        genresTask?.cancel()
        channelTask?.cancel()
        mediaTask?.cancel()
        seriesTask?.cancel()
        streamTask?.cancel()
        epgTask?.cancel()
        connectTask = nil
        genresTask = nil
        channelTask = nil
        mediaTask = nil
        seriesTask = nil
        streamTask = nil
        epgTask = nil

        if let client {
            Task {
                await client.disconnect(clearCachedSession: false)
            }
        }
        client = nil
        player.stop()
        activePortal = nil
        session = nil
        connectionState = .disconnected
        contentMode = .live
        vodCategoriesCache = []
        genres = []
        selectedGenre = nil
        channels = []
        selectedChannel = nil
        mediaItems = []
        selectedMedia = nil
        seasons = []
        selectedSeason = nil
        episodes = []
        selectedEpisode = nil
        epgPrograms = []
        epgError = nil
        isResolvingStream = false
        isRetryingGenres = false
        isLoadingMedia = false
        isLoadingMoreMedia = false
        isLoadingSeriesDetail = false
        mediaLoadWarning = nil
        errorMessage = nil
    }

    func refresh() {
        guard activePortal != nil else { return }
        if !connectionState.isConnected {
            if let activePortal {
                connect(to: activePortal)
            }
            return
        }
        if genres.isEmpty {
            reloadGenres()
            return
        }
        switch contentMode {
        case .live:
            if let selectedGenre {
                loadChannels(for: selectedGenre)
            }
            if let selectedChannel {
                loadEPG(for: selectedChannel)
            }
        case .movies, .series:
            if let selectedGenre {
                loadMedia(for: selectedGenre)
            }
        }
    }

    // MARK: Content mode

    func selectMode(_ mode: StalkerContentMode) {
        guard contentMode != mode else { return }
        guard activePortal != nil else {
            contentMode = mode
            return
        }

        genresTask?.cancel()
        channelTask?.cancel()
        mediaTask?.cancel()
        seriesTask?.cancel()
        streamTask?.cancel()
        epgTask?.cancel()
        player.stop()

        contentMode = mode
        genres = []
        selectedGenre = nil
        channels = []
        selectedChannel = nil
        mediaItems = []
        selectedMedia = nil
        seasons = []
        selectedSeason = nil
        episodes = []
        selectedEpisode = nil
        epgPrograms = []
        epgError = nil
        errorMessage = nil
        mediaLoadWarning = nil
        isLoadingMedia = false
        isLoadingMoreMedia = false
        isLoadingSeriesDetail = false
        isLoadingChannels = false
        isResolvingStream = false
        isRetryingGenres = false

        if mode == .live {
            reloadGenres()
        } else {
            loadVODCategories()
        }
    }

    private func loadVODCategories() {
        guard connectionState.isConnected, let client, let portalID = activePortal?.id else { return }

        if !vodCategoriesCache.isEmpty {
            genres = categoriesForCurrentVODMode(vodCategoriesCache)
            selectedGenre = nil
            isRetryingGenres = false
            return
        }

        genresTask?.cancel()
        isRetryingGenres = true
        let generation = connectionID
        let loadMode = contentMode

        genresTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await self.fetchCategoriesWithRetry(
                    client: client,
                    mode: loadMode,
                    generation: generation
                )
                guard self.activePortal?.id == portalID,
                      self.connectionID == generation,
                      self.contentMode == loadMode,
                      !Task.isCancelled else { return }
                self.vodCategoriesCache = fetched
                self.genres = self.categoriesForCurrentVODMode(fetched)
                self.selectedGenre = nil
                self.isRetryingGenres = false
                AppLog.info("Loaded \(fetched.count) VOD categories; showing \(self.genres.count) for \(loadMode.title)")
            } catch {
                guard self.activePortal?.id == portalID,
                      self.connectionID == generation,
                      self.contentMode == loadMode,
                      !Task.isCancelled else { return }
                self.isRetryingGenres = false
                AppLog.error("VOD category load failed: \(error.localizedDescription)")
                self.errorMessage = Self.message(for: error, prefix: "Video categories could not be loaded.")
            }
        }
    }

    func reloadGenres() {
        guard connectionState.isConnected, let client, let portalID = activePortal?.id else {
            retryConnection()
            return
        }

        genresTask?.cancel()
        errorMessage = nil
        isRetryingGenres = true
        let generation = connectionID
        let loadMode = contentMode

        genresTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await self.fetchCategoriesWithRetry(
                    client: client,
                    mode: loadMode,
                    generation: generation
                )
                guard self.activePortal?.id == portalID,
                      self.connectionID == generation,
                      self.contentMode == loadMode,
                      !Task.isCancelled else { return }
                if loadMode == .live {
                    self.genres = [.all] + fetched
                } else {
                    self.vodCategoriesCache = fetched
                    self.genres = self.categoriesForCurrentVODMode(fetched)
                }
                self.selectedGenre = nil
                self.channels = []
                self.selectedChannel = nil
                self.isRetryingGenres = false
                AppLog.info("Reloaded \(fetched.count) categories for \(loadMode.title)")
            } catch {
                guard self.activePortal?.id == portalID,
                      self.connectionID == generation,
                      self.contentMode == loadMode,
                      !Task.isCancelled else { return }
                self.isRetryingGenres = false
                AppLog.error("Category reload failed: \(error.localizedDescription)")
                if case StalkerError.rateLimited = error {
                    self.errorMessage = "The portal is rate-limiting category requests. Wait about a minute, then try again."
                } else {
                    self.errorMessage = Self.message(for: error, prefix: "Categories could not be loaded.")
                }
            }
        }
    }

    private func fetchCategoriesWithRetry(
        client: StalkerClient,
        mode: StalkerContentMode,
        generation: UUID
    ) async throws -> [StalkerGenre] {
        var lastError: Error?
        defer { isRetryingGenres = false }

        for attempt in 0..<3 {
            do {
                if mode == .live {
                    return try await client.fetchGenres()
                }
                return try await client.fetchVODCategories()
            } catch {
                lastError = error
                guard connectionID == generation, !Task.isCancelled else {
                    throw StalkerError.cancelled
                }
                guard let stalkerError = error as? StalkerError,
                      case .rateLimited = stalkerError,
                      attempt < 2 else {
                    throw error
                }
                isRetryingGenres = true
                let delay = attempt == 0 ? 8 : 18
                AppLog.warning("Categories rate-limited; retrying in \(delay)s (attempt \(attempt + 1)/2)")
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
        }

        throw lastError ?? StalkerError.rateLimited
    }

    func retryConnection() {
        guard let activePortal else { return }
        connect(to: activePortal)
    }

    // MARK: Catalog

    func selectGenre(_ genre: StalkerGenre) {
        let alreadyLoaded = contentMode == .live
            ? (!channels.isEmpty || selectedChannel != nil)
            : (!mediaItems.isEmpty || selectedMedia != nil)
        guard selectedGenre?.id != genre.id || !alreadyLoaded else { return }
        selectedGenre = genre
        if contentMode == .live {
            loadChannels(for: genre)
        } else {
            loadMedia(for: genre)
        }
    }

    private func loadChannels(for genre: StalkerGenre) {
        channelTask?.cancel()
        streamTask?.cancel()
        epgTask?.cancel()
        isResolvingStream = false
        selectedChannel = nil
        channels = []
        epgPrograms = []
        epgError = nil
        isLoadingChannels = true

        guard let client, let portalID = activePortal?.id else {
            isLoadingChannels = false
            return
        }

        AppLog.info("Loading channels genre='\(genre.title)' id=\(genre.id)")
        channelTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await client.fetchAllChannels(genreID: genre.id)
                guard self.activePortal?.id == portalID,
                      self.selectedGenre?.id == genre.id,
                      !Task.isCancelled else { return }
                self.channels = fetched
                self.isLoadingChannels = false
                AppLog.info("Loaded \(fetched.count) channels for '\(genre.title)'")
            } catch {
                guard self.activePortal?.id == portalID,
                      self.selectedGenre?.id == genre.id,
                      !Task.isCancelled else { return }
                self.isLoadingChannels = false
                if case StalkerError.cancelled = error { return }
                AppLog.error("Channel load failed for '\(genre.title)': \(error.localizedDescription)")
                self.errorMessage = Self.message(for: error, prefix: "Channels could not be loaded.")
            }
        }
    }

    // MARK: Movies / series

    private func loadMedia(for genre: StalkerGenre) {
        mediaTask?.cancel()
        seriesTask?.cancel()
        streamTask?.cancel()
        player.stop()

        mediaItems = []
        selectedMedia = nil
        seasons = []
        selectedSeason = nil
        episodes = []
        selectedEpisode = nil
        isLoadingMedia = true
        isLoadingMoreMedia = false
        mediaLoadWarning = nil
        isLoadingSeriesDetail = false
        isResolvingStream = false

        guard let client, let portalID = activePortal?.id else {
            isLoadingMedia = false
            return
        }

        let loadMode = contentMode
        guard loadMode != .live else {
            isLoadingMedia = false
            return
        }

        AppLog.info("Loading \(loadMode.title) category '\(genre.title)' id=\(genre.id)")
        mediaTask = Task { [weak self] in
            guard let self else { return }
            do {
                // Paint the first page immediately instead of waiting for every
                // page in large VOD categories (or the big "All" category).
                let first = try await client.fetchVODPage(categoryID: genre.id, page: 1)
                guard self.activePortal?.id == portalID,
                      self.contentMode == loadMode,
                      self.selectedGenre?.id == genre.id,
                      !Task.isCancelled else { return }

                let filter: (StalkerMediaItem) -> Bool = { item in
                    loadMode == .movies ? item.isMovie : item.isSeries
                }
                var loaded = first.items.filter(filter)
                var seen = Set(loaded.map { "\($0.kind.rawValue):\($0.id)" })
                self.mediaItems = loaded
                self.isLoadingMedia = false
                AppLog.info("Loaded VOD page 1: \(first.items.count) raw, \(loaded.count) \(loadMode.title); total pages \(first.totalPages)")

                let totalPages = min(max(first.totalPages, 1), configurationMaxVODPages)
                if totalPages > 1 {
                    self.isLoadingMoreMedia = true
                    for page in 2...totalPages {
                        guard self.activePortal?.id == portalID,
                              self.contentMode == loadMode,
                              self.selectedGenre?.id == genre.id,
                              !Task.isCancelled else { return }
                        do {
                            let next = try await client.fetchVODPage(categoryID: genre.id, page: page)
                            let newItems = next.items.filter(filter).filter {
                                seen.insert("\($0.kind.rawValue):\($0.id)").inserted
                            }
                            loaded.append(contentsOf: newItems)
                            self.mediaItems = loaded
                            if page % 5 == 0 || page == totalPages {
                                AppLog.info("Loaded VOD page \(page)/\(totalPages), \(loaded.count) visible items")
                            }
                        } catch {
                            if case StalkerError.cancelled = error { return }
                            AppLog.warning("VOD page \(page) failed for '\(genre.title)': \(error.localizedDescription)")
                            self.mediaLoadWarning = "Some titles could not be loaded. Pull to refresh or try again."
                            break
                        }
                    }
                    self.isLoadingMoreMedia = false
                }
            } catch {
                guard self.activePortal?.id == portalID,
                      self.contentMode == loadMode,
                      self.selectedGenre?.id == genre.id,
                      !Task.isCancelled else { return }
                self.isLoadingMedia = false
                self.isLoadingMoreMedia = false
                if case StalkerError.cancelled = error { return }
                AppLog.error("Video load failed for '\(genre.title)': \(error.localizedDescription)")
                self.errorMessage = Self.message(for: error, prefix: "\(loadMode.title) could not be loaded.")
            }
        }
    }

    private var configurationMaxVODPages: Int {
        40
    }

    /// Stalker exposes one VOD category list containing both movies and series.
    /// Category names are the only reliable discriminator on many Ministra
    /// builds, so split them for the Movies and Web Series tabs. The enormous
    /// "All" category is not shown: it can report tens of thousands of pages.
    private func categoriesForCurrentVODMode(_ categories: [StalkerGenre]) -> [StalkerGenre] {
        let usable = categories.filter { $0.title.localizedCaseInsensitiveCompare("All") != .orderedSame }
        let seriesKeywords = ["series", "web", "show", "tv", "collection", "episode", "season", "ott", "notok"]
        let isSeriesCategory = { (category: StalkerGenre) -> Bool in
            let title = category.title.lowercased()
            return seriesKeywords.contains { title.contains($0) }
        }

        switch contentMode {
        case .live:
            return categories
        case .series:
            let filtered = usable.filter(isSeriesCategory)
            return filtered.isEmpty ? usable : filtered
        case .movies:
            let filtered = usable.filter { !isSeriesCategory($0) }
            return filtered.isEmpty ? usable : filtered
        }
    }

    func selectMedia(_ media: StalkerMediaItem) {
        guard contentMode != .live else { return }
        guard selectedMedia?.id != media.id || selectedEpisode != nil else { return }

        selectedMedia = media
        selectedEpisode = nil
        seasons = []
        selectedSeason = nil
        episodes = []
        streamTask?.cancel()
        player.stop()
        isResolvingStream = false
        errorMessage = nil

        if media.isMovie {
            resolveAndPlay(media, title: media.name, subtitle: "Movie")
        } else if media.isSeries {
            loadSeasons(for: media)
        }
    }

    func playSelectedMedia() {
        guard let selectedMedia else { return }
        if selectedMedia.isMovie {
            resolveAndPlay(selectedMedia, title: selectedMedia.name, subtitle: "Movie")
        } else if let selectedEpisode {
            resolveAndPlay(
                selectedEpisode,
                title: selectedMedia.name,
                subtitle: selectedEpisode.name
            )
        }
    }

    private func loadSeasons(for series: StalkerMediaItem) {
        seriesTask?.cancel()
        seasons = []
        selectedSeason = nil
        episodes = []
        selectedEpisode = nil
        isLoadingSeriesDetail = true

        guard let client, let portalID = activePortal?.id else {
            isLoadingSeriesDetail = false
            return
        }

        seriesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await client.fetchSeasons(seriesID: series.movieID ?? series.id)
                guard self.activePortal?.id == portalID,
                      self.selectedMedia?.id == series.id,
                      !Task.isCancelled else { return }
                self.seasons = fetched
                if let first = fetched.first {
                    self.selectedSeason = first
                    self.loadEpisodes(for: series, season: first)
                } else {
                    self.isLoadingSeriesDetail = false
                    self.errorMessage = "This series did not return any seasons."
                }
                AppLog.info("Loaded \(fetched.count) seasons for '\(series.name)'")
            } catch {
                guard self.activePortal?.id == portalID,
                      self.selectedMedia?.id == series.id,
                      !Task.isCancelled else { return }
                self.isLoadingSeriesDetail = false
                if case StalkerError.cancelled = error { return }
                AppLog.error("Season load failed for '\(series.name)': \(error.localizedDescription)")
                self.errorMessage = Self.message(for: error, prefix: "Seasons could not be loaded.")
            }
        }
    }

    func selectSeason(_ season: StalkerMediaItem) {
        guard let series = selectedMedia, series.isSeries else { return }
        selectSeasonInternal(season, series: series)
    }

    private func selectSeasonInternal(_ season: StalkerMediaItem, series: StalkerMediaItem) {
        selectedSeason = season
        selectedEpisode = nil
        player.stop()
        loadEpisodes(for: series, season: season)
    }

    private func loadEpisodes(for series: StalkerMediaItem, season: StalkerMediaItem) {
        seriesTask?.cancel()
        episodes = []
        selectedEpisode = nil
        isLoadingSeriesDetail = true

        guard let client, let portalID = activePortal?.id else {
            isLoadingSeriesDetail = false
            return
        }

        seriesTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await client.fetchEpisodes(
                    seriesID: series.movieID ?? series.id,
                    seasonID: season.id
                )
                guard self.activePortal?.id == portalID,
                      self.selectedMedia?.id == series.id,
                      self.selectedSeason?.id == season.id,
                      !Task.isCancelled else { return }
                self.episodes = fetched
                self.isLoadingSeriesDetail = false
                if fetched.isEmpty {
                    self.errorMessage = "This season did not return any playable episodes."
                }
                AppLog.info("Loaded \(fetched.count) episodes for '\(series.name)' season '\(season.name)'")
            } catch {
                guard self.activePortal?.id == portalID,
                      self.selectedMedia?.id == series.id,
                      self.selectedSeason?.id == season.id,
                      !Task.isCancelled else { return }
                self.isLoadingSeriesDetail = false
                if case StalkerError.cancelled = error { return }
                AppLog.error("Episode load failed: \(error.localizedDescription)")
                self.errorMessage = Self.message(for: error, prefix: "Episodes could not be loaded.")
            }
        }
    }

    func selectEpisode(_ episode: StalkerMediaItem) {
        guard let series = selectedMedia, series.isSeries else { return }
        selectedEpisode = episode
        resolveAndPlay(
            episode,
            title: series.name,
            subtitle: episode.name
        )
    }

    private func resolveAndPlay(_ media: StalkerMediaItem, title: String, subtitle: String) {
        guard let client, let portalID = activePortal?.id else { return }

        streamTask?.cancel()
        isResolvingStream = true
        player.stop()

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await client.resolveStream(for: media)
                guard self.activePortal?.id == portalID,
                      self.selectedMedia?.id == media.movieID
                        || self.selectedMedia?.id == media.id
                        || self.selectedEpisode?.id == media.id,
                      !Task.isCancelled else { return }

                self.isResolvingStream = false
                AppLog.info("Resolved VOD stream for '\(media.name)'")
                self.player.play(PlaybackRequest(
                    url: stream.url,
                    headers: stream.headers,
                    title: title,
                    subtitle: subtitle,
                    channelID: media.id,
                    isLive: false
                ))
            } catch {
                guard self.activePortal?.id == portalID,
                      !Task.isCancelled else { return }
                self.isResolvingStream = false
                if case StalkerError.cancelled = error { return }
                AppLog.error("VOD stream resolution failed for '\(media.name)': \(error.localizedDescription)")
                self.errorMessage = Self.message(for: error, prefix: "This title could not be played.")
            }
        }
    }

    // MARK: Channel / EPG / stream

    func selectChannel(_ channel: StalkerChannel) {
        guard contentMode == .live else { return }
        guard selectedChannel?.id != channel.id else { return }
        selectedChannel = channel
        epgPrograms = []
        epgError = nil
        isResolvingStream = true
        player.stop()

        loadEPG(for: channel)

        guard let client, let portalID = activePortal?.id else {
            isResolvingStream = false
            return
        }

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await client.resolveStream(for: channel)
                guard self.activePortal?.id == portalID,
                      self.selectedChannel?.id == channel.id,
                      !Task.isCancelled else { return }

                self.isResolvingStream = false
                AppLog.info("Resolved stream for channel='\(channel.name)'")
                let request = PlaybackRequest(
                    url: stream.url,
                    headers: stream.headers,
                    title: channel.name,
                    subtitle: channel.displayNumber,
                    channelID: channel.id,
                    isLive: true
                )
                self.player.play(request)
            } catch {
                guard self.activePortal?.id == portalID,
                      self.selectedChannel?.id == channel.id,
                      !Task.isCancelled else { return }
                self.isResolvingStream = false
                if case StalkerError.cancelled = error { return }
                AppLog.error("Stream resolution failed for '\(channel.name)': \(error.localizedDescription)")
                self.errorMessage = Self.message(for: error, prefix: "This channel could not be played.")
            }
        }
    }

    func retryPlayback() {
        if contentMode == .live {
            guard let channel = selectedChannel else { return }
            selectedChannel = nil
            selectChannel(channel)
            return
        }

        if let selectedEpisode {
            selectEpisode(selectedEpisode)
        } else {
            playSelectedMedia()
        }
    }

    func stepChannel(by offset: Int) {
        guard contentMode == .live else { return }
        guard !channels.isEmpty else { return }
        let currentIndex = selectedChannel.flatMap { selected in
            channels.firstIndex(where: { $0.id == selected.id })
        } ?? (offset > 0 ? -1 : 0)
        let nextIndex = (currentIndex + offset + channels.count) % channels.count
        selectChannel(channels[nextIndex])
    }

    func loadEPG(for channel: StalkerChannel) {
        guard contentMode == .live else { return }
        epgTask?.cancel()
        epgPrograms = []
        epgError = nil
        isLoadingEPG = true

        guard let client, let portalID = activePortal?.id else {
            isLoadingEPG = false
            return
        }

        epgTask = Task { [weak self] in
            guard let self else { return }
            do {
                let programs = try await client.fetchEPG(channelID: channel.id, hours: 6)
                guard self.activePortal?.id == portalID,
                      self.selectedChannel?.id == channel.id,
                      !Task.isCancelled else { return }
                self.epgPrograms = programs
                self.isLoadingEPG = false
            } catch {
                guard self.activePortal?.id == portalID,
                      self.selectedChannel?.id == channel.id,
                      !Task.isCancelled else { return }
                self.isLoadingEPG = false
                self.epgError = error.localizedDescription
            }
        }
    }

    // MARK: Derived state

    var currentProgram: StalkerEPGProgram? {
        let now = Date()
        return epgPrograms.first(where: { $0.isLive(at: now) })
            ?? epgPrograms.first(where: { $0.start > now })
            ?? epgPrograms.last
    }

    var upcomingPrograms: [StalkerEPGProgram] {
        let now = Date()
        return epgPrograms
            .filter { $0.end > now && $0.id != currentProgram?.id }
            .sorted { $0.start < $1.start }
            .prefix(8)
            .map { $0 }
    }

    var accountDisplayName: String {
        session?.userProfile.displayName ?? activePortal?.name ?? "No portal"
    }

    var isVideoMode: Bool {
        contentMode == .movies || contentMode == .series
    }

    func setMediaSortOrder(_ order: MediaSortOrder) {
        guard mediaSortOrder != order else { return }
        mediaSortOrder = order
        AppLog.info("Video sort changed to \(order.displayName)")
    }

    var sortedMediaItems: [StalkerMediaItem] {
        mediaItems.sorted { lhs, rhs in
            switch mediaSortOrder {
            case .recentlyAdded:
                if lhs.addedSortValue != rhs.addedSortValue {
                    return lhs.addedSortValue > rhs.addedSortValue
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending

            case .title:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending

            case .year:
                let lhsYear = Int(lhs.year ?? "") ?? 0
                let rhsYear = Int(rhs.year ?? "") ?? 0
                if lhsYear != rhsYear { return lhsYear > rhsYear }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending

            case .rating:
                let lhsRating = Double(lhs.rating ?? "") ?? 0
                let rhsRating = Double(rhs.rating ?? "") ?? 0
                if lhsRating != rhsRating { return lhsRating > rhsRating }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }


    var playingTitle: String? {
        player.currentRequest?.title
    }

    func dismissDetail() {
        streamTask?.cancel()
        epgTask?.cancel()
        seriesTask?.cancel()
        player.stop()
        selectedChannel = nil
        selectedMedia = nil
        selectedSeason = nil
        selectedEpisode = nil
        seasons = []
        episodes = []
        epgPrograms = []
        epgError = nil
        isResolvingStream = false
    }

    func clearError() {
        errorMessage = nil
    }

    private static func message(for error: Error, prefix: String) -> String {
        let detail: String
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            detail = description
        } else {
            detail = error.localizedDescription
        }
        return "\(prefix) \(detail)"
    }
}
