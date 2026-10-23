//
//  StalkerClient+API.swift
//  StalkerDeskCore
//
//  Public live-TV API surface built on the authenticated transport in
//  StalkerClient.swift.
//

import Foundation

public extension StalkerClient {

    // MARK: Genres

    /// action=get_genres. The UI prepends a synthetic "All Channels" genre.
    func fetchGenres() async throws -> [StalkerGenre] {
        let json = try await requestJSON(
            items: [
                URLQueryItem(name: "type", value: "itv"),
                URLQueryItem(name: "action", value: "get_genres")
            ],
            authenticated: true
        )
        let js = try Self.jsPayload(json)
        return StalkerPayloadParser.genres(from: js)
    }

    // MARK: Channels

    /// One page of action=get_ordered_list. page is 1-based.
    func fetchChannelsPage(genreID: String, page: Int) async throws -> StalkerPage<StalkerChannel> {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "type", value: "itv"),
            URLQueryItem(name: "action", value: "get_ordered_list"),
            URLQueryItem(name: "p", value: String(max(1, page))),
            URLQueryItem(name: "fav", value: "0"),
            URLQueryItem(name: "sortby", value: "number")
        ]
        if genreID != "*" {
            items.append(URLQueryItem(name: "genre", value: genreID))
        }

        let json = try await requestJSON(items: items, authenticated: true)
        let js = try Self.jsPayload(json)
        return StalkerPayloadParser.channelPage(from: js, page: max(1, page), endpoint: endpoint)
    }

    /// Fetches every page for a genre, at most maxChannelPages, using a small
    /// concurrent batch to keep large portals responsive.
    func fetchAllChannels(genreID: String) async throws -> [StalkerChannel] {
        let first = try await fetchChannelsPage(genreID: genreID, page: 1)
        var allChannels = first.items
        let totalPages = min(max(first.totalPages, 1), configuration.maxChannelPages)

        if totalPages > 1 {
            var nextPage = 2
            while nextPage <= totalPages {
                let endPage = min(nextPage + configuration.maxConcurrentPageRequests - 1, totalPages)
                let pageNumbers = Array(nextPage...endPage)

                let pages = try await withThrowingTaskGroup(of: (Int, StalkerPage<StalkerChannel>).self) { group in
                    for pageNumber in pageNumbers {
                        group.addTask { [self] in
                            let page = try await self.fetchChannelsPage(genreID: genreID, page: pageNumber)
                            return (pageNumber, page)
                        }
                    }

                    var results: [(Int, StalkerPage<StalkerChannel>)] = []
                    for try await result in group {
                        results.append(result)
                    }
                    return results
                }

                for (_, page) in pages.sorted(by: { $0.0 < $1.0 }) {
                    allChannels.append(contentsOf: page.items)
                }

                // Some portals over-report total_items. Stop if a whole batch
                // came back empty instead of hammering nonexistent pages.
                if pages.allSatisfy({ $0.1.items.isEmpty }) { break }
                nextPage = endPage + 1
            }
        }

        var seen = Set<String>()
        return allChannels.filter { seen.insert($0.id).inserted }
    }

    // MARK: VOD / series catalog

    /// action=get_categories for type=vod. These categories contain both movies
    /// and series; the app filters items by is_series for the Movies/Web Series
    /// modes.
    func fetchVODCategories() async throws -> [StalkerGenre] {
        let json = try await requestJSON(
            items: [
                URLQueryItem(name: "type", value: "vod"),
                URLQueryItem(name: "action", value: "get_categories")
            ],
            authenticated: true
        )
        let js = try Self.jsPayload(json)
        return StalkerPayloadParser.genres(from: js)
    }

    func fetchVODPage(categoryID: String, page: Int) async throws -> StalkerPage<StalkerMediaItem> {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "type", value: "vod"),
            URLQueryItem(name: "action", value: "get_ordered_list"),
            URLQueryItem(name: "p", value: String(max(1, page))),
            URLQueryItem(name: "sortby", value: "added")
        ]
        if categoryID != "*" {
            items.append(URLQueryItem(name: "category", value: categoryID))
        }

        let json = try await requestJSON(items: items, authenticated: true)
        let js = try Self.jsPayload(json)
        return StalkerPayloadParser.mediaPage(
            from: js,
            page: max(1, page),
            endpoint: endpoint,
            context: .vod
        )
    }

    /// Returns all VOD items in a category. Movies and series are separated by
    /// the caller using the item kind.
    func fetchAllVOD(categoryID: String) async throws -> [StalkerMediaItem] {
        let first = try await fetchVODPage(categoryID: categoryID, page: 1)
        var allItems = first.items
        let totalPages = min(max(first.totalPages, 1), configuration.maxChannelPages)

        if totalPages > 1 {
            var nextPage = 2
            while nextPage <= totalPages {
                let endPage = min(nextPage + configuration.maxConcurrentPageRequests - 1, totalPages)
                let pages = try await withThrowingTaskGroup(of: (Int, StalkerPage<StalkerMediaItem>).self) { group in
                    for pageNumber in nextPage...endPage {
                        group.addTask { [self] in
                            let page = try await self.fetchVODPage(categoryID: categoryID, page: pageNumber)
                            return (pageNumber, page)
                        }
                    }
                    var results: [(Int, StalkerPage<StalkerMediaItem>)] = []
                    for try await result in group {
                        results.append(result)
                    }
                    return results
                }

                for (_, page) in pages.sorted(by: { $0.0 < $1.0 }) {
                    allItems.append(contentsOf: page.items)
                }
                if pages.allSatisfy({ $0.1.items.isEmpty }) { break }
                nextPage = endPage + 1
            }
        }

        var seen = Set<String>()
        return allItems.filter { item in
            seen.insert("\(item.kind.rawValue):\(item.id)").inserted
        }
    }

    /// Seasons are returned by get_ordered_list with movie_id + season_id=0.
    func fetchSeasons(seriesID: String) async throws -> [StalkerMediaItem] {
        var allSeasons: [StalkerMediaItem] = []
        var page = 1
        var totalPages = 1

        repeat {
            let json = try await requestJSON(
                items: [
                    URLQueryItem(name: "type", value: "vod"),
                    URLQueryItem(name: "action", value: "get_ordered_list"),
                    URLQueryItem(name: "movie_id", value: seriesID),
                    URLQueryItem(name: "season_id", value: "0"),
                    URLQueryItem(name: "episode_id", value: "0"),
                    URLQueryItem(name: "p", value: String(page))
                ],
                authenticated: true
            )
            let js = try Self.jsPayload(json)
            let result = StalkerPayloadParser.mediaPage(
                from: js,
                page: page,
                endpoint: endpoint,
                context: .season,
                parentMovieID: seriesID
            )
            allSeasons.append(contentsOf: result.items)
            totalPages = min(max(result.totalPages, 1), 20)
            page += 1
        } while page <= totalPages

        var seen = Set<String>()
        return allSeasons.filter { seen.insert($0.id).inserted }
    }

    /// Episodes are returned by get_ordered_list with movie_id + season_id.
    func fetchEpisodes(seriesID: String, seasonID: String) async throws -> [StalkerMediaItem] {
        var allEpisodes: [StalkerMediaItem] = []
        var page = 1
        var totalPages = 1

        repeat {
            let json = try await requestJSON(
                items: [
                    URLQueryItem(name: "type", value: "vod"),
                    URLQueryItem(name: "action", value: "get_ordered_list"),
                    URLQueryItem(name: "movie_id", value: seriesID),
                    URLQueryItem(name: "season_id", value: seasonID),
                    URLQueryItem(name: "episode_id", value: "0"),
                    URLQueryItem(name: "p", value: String(page))
                ],
                authenticated: true
            )
            let js = try Self.jsPayload(json)
            let result = StalkerPayloadParser.mediaPage(
                from: js,
                page: page,
                endpoint: endpoint,
                context: .episode,
                parentMovieID: seriesID,
                parentSeasonID: seasonID
            )
            allEpisodes.append(contentsOf: result.items)
            totalPages = min(max(result.totalPages, 1), 20)
            page += 1
        } while page <= totalPages

        var seen = Set<String>()
        return allEpisodes.filter { seen.insert($0.id).inserted }
    }

    /// Resolves a movie or series episode to a playable URL using the most
    /// common Stalker VOD create_link variants.
    func resolveStream(for media: StalkerMediaItem) async throws -> ResolvedStream {
        var lastError: Error?

        // 1. Some portals put the playable cmd directly on the VOD item.
        if !media.command.isEmpty {
            do {
                let command = try await createVODLink(command: media.command)
                return try makeVODStream(from: command, media: media)
            } catch {
                lastError = error
            }
        }

        // 2. Series episodes: get_episode_stream is supported by several
        //    Ministra builds.
        if media.kind == .episode {
            do {
                let command = try await fetchEpisodeStream(episodeID: media.episodeID ?? media.id)
                return try makeVODStream(from: command, media: media)
            } catch {
                lastError = error
            }
        }

        // 3. Fallback: get_ordered_list returns a stream record; create_link
        //    with /media/file_<id>.mpg is the legacy VOD convention.
        do {
            let streamID = try await fetchVODStreamID(for: media)
            let command = try await createVODLink(command: "/media/file_\(streamID).mpg")
            return try makeVODStream(from: command, media: media)
        } catch {
            lastError = error
        }

        throw lastError ?? StalkerError.createLinkFailed("The portal did not return a VOD stream.")
    }

    private func createVODLink(command: String) async throws -> String {
        let json = try await requestJSON(
            items: [
                URLQueryItem(name: "type", value: "vod"),
                URLQueryItem(name: "action", value: "create_link"),
                URLQueryItem(name: "cmd", value: command),
                URLQueryItem(name: "series", value: "0"),
                URLQueryItem(name: "forced_storage", value: "0"),
                URLQueryItem(name: "disable_ad", value: "0"),
                URLQueryItem(name: "download", value: "0")
            ],
            authenticated: true
        )
        let js = try Self.jsPayload(json)
        guard let resolved = StalkerPayloadParser.streamCommand(from: js) else {
            throw StalkerError.createLinkFailed("create_link did not return a VOD stream command.")
        }
        return resolved
    }

    private func fetchEpisodeStream(episodeID: String) async throws -> String {
        let json = try await requestJSON(
            items: [
                URLQueryItem(name: "type", value: "vod"),
                URLQueryItem(name: "action", value: "get_episode_stream"),
                URLQueryItem(name: "episode_id", value: episodeID)
            ],
            authenticated: true
        )
        let js = try Self.jsPayload(json)
        guard let command = StalkerPayloadParser.streamCommand(from: js) else {
            throw StalkerError.createLinkFailed("get_episode_stream did not return a command.")
        }
        return command
    }

    private func fetchVODStreamID(for media: StalkerMediaItem) async throws -> String {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "type", value: "vod"),
            URLQueryItem(name: "action", value: "get_ordered_list"),
            URLQueryItem(name: "movie_id", value: media.movieID ?? media.id)
        ]
        if let seasonID = media.seasonID, !seasonID.isEmpty {
            items.append(URLQueryItem(name: "season_id", value: seasonID))
        }
        if media.kind == .episode {
            items.append(URLQueryItem(name: "episode_id", value: media.episodeID ?? media.id))
        }

        let json = try await requestJSON(items: items, authenticated: true)
        let js = try Self.jsPayload(json)
        let values = js["data"]?.arrayValue ?? js.arrayValue ?? []
        guard let first = values.first?.objectValue,
              let streamID = first.firstString("id", "video_id", "episode_id") else {
            throw StalkerError.createLinkFailed("The portal returned no playable VOD record.")
        }
        return streamID
    }

    private func makeVODStream(from command: String, media: StalkerMediaItem) throws -> ResolvedStream {
        let rewriteEndpoint = configuration.enableLocalhostRewrite ? endpoint : nil
        guard let url = StreamCommandParser.extractURL(from: command, portalEndpoint: rewriteEndpoint) else {
            throw StalkerError.createLinkFailed("The VOD stream command does not contain a valid URL.")
        }
        guard url.scheme == "http" || url.scheme == "https" else {
            throw StalkerError.unsupportedStream("Only HTTP(S) streams are supported.")
        }
        return ResolvedStream(
            channelID: media.id,
            url: url,
            headers: streamHeaders(for: url),
            rawCommand: command
        )
    }

    // MARK: EPG

    /// Uses the bulk action=get_epg_info endpoint and falls back to
    /// action=get_short_epg for portals that do not implement it correctly.
    func fetchEPG(channelID: String, hours: Int = 6) async throws -> [StalkerEPGProgram] {
        if let cached = epgCache[channelID],
           Date().timeIntervalSince(cached.fetchedAt) < 5 * 60 {
            return cached.programs[channelID] ?? []
        }

        var bulkFailure: Error?

        do {
            let map = try await fetchBulkEPG(hours: hours)
            let now = Date()
            for (key, programs) in map {
                epgCache[key] = CachedEPG(programs: [key: programs], fetchedAt: now)
            }
            if let programs = map[channelID], !programs.isEmpty {
                return programs
            }
        } catch {
            bulkFailure = error
        }

        do {
            let short = try await fetchShortEPG(channelID: channelID)
            epgCache[channelID] = CachedEPG(programs: [channelID: short], fetchedAt: Date())
            return short
        } catch {
            if let bulkFailure { throw bulkFailure }
            throw error
        }
    }

    private func fetchBulkEPG(hours: Int) async throws -> [String: [StalkerEPGProgram]] {
        let json = try await requestJSON(
            items: [
                URLQueryItem(name: "type", value: "itv"),
                URLQueryItem(name: "action", value: "get_epg_info"),
                URLQueryItem(name: "period", value: String(max(1, hours)))
            ],
            authenticated: true
        )
        let js = try Self.jsPayload(json)
        return StalkerPayloadParser.epgPrograms(
            from: js,
            fallbackChannelID: nil,
            timezone: activeProfile?.timezone ?? TimeZone.current.identifier
        )
    }

    private func fetchShortEPG(channelID: String) async throws -> [StalkerEPGProgram] {
        let json = try await requestJSON(
            items: [
                URLQueryItem(name: "type", value: "itv"),
                URLQueryItem(name: "action", value: "get_short_epg"),
                URLQueryItem(name: "ch_id", value: channelID),
                URLQueryItem(name: "size", value: "12")
            ],
            authenticated: true
        )
        let js = try Self.jsPayload(json)
        let grouped = StalkerPayloadParser.epgPrograms(
            from: js,
            fallbackChannelID: channelID,
            timezone: activeProfile?.timezone ?? TimeZone.current.identifier
        )
        return grouped[channelID] ?? grouped.values.first ?? []
    }

    func invalidateEPGCache() {
        epgCache.removeAll()
    }

    // MARK: Stream resolution

    /// action=create_link against the channel's cmd, returning a URL plus the
    /// cookie/authorization headers required by the stream server.
    func resolveStream(for channel: StalkerChannel) async throws -> ResolvedStream {
        guard !channel.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StalkerError.createLinkFailed("The channel has no playable command from the portal.")
        }

        let json = try await requestJSON(
            items: [
                URLQueryItem(name: "type", value: "itv"),
                URLQueryItem(name: "action", value: "create_link"),
                URLQueryItem(name: "cmd", value: channel.command),
                URLQueryItem(name: "series", value: "0"),
                URLQueryItem(name: "forced_storage", value: "0"),
                URLQueryItem(name: "disable_ad", value: "0"),
                URLQueryItem(name: "download", value: "0"),
                URLQueryItem(name: "force_ch_link_check", value: "0"),
                URLQueryItem(name: "fav", value: "0")
            ],
            authenticated: true
        )

        let js = try Self.jsPayload(json)
        guard let command = StalkerPayloadParser.streamCommand(from: js) else {
            throw StalkerError.createLinkFailed("create_link did not return a stream command.")
        }

        let rewriteEndpoint = configuration.enableLocalhostRewrite ? endpoint : nil
        guard let url = StreamCommandParser.extractURL(from: command, portalEndpoint: rewriteEndpoint) else {
            throw StalkerError.createLinkFailed("The returned stream command does not contain a valid HTTP URL.")
        }

        guard url.scheme == "http" || url.scheme == "https" else {
            throw StalkerError.unsupportedStream("Only HTTP(S) streams are supported.")
        }

        let headers = streamHeaders(for: url)
        logger.debug("Resolved stream for channel \(channel.id, privacy: .public)")
        return ResolvedStream(
            channelID: channel.id,
            url: url,
            headers: headers,
            rawCommand: command
        )
    }

    /// Exposed for UI refresh timers and retry buttons.
    func refreshIfNeeded() async throws {
        guard token != nil else { return }
        try await ensureTokenValid()
    }
}
