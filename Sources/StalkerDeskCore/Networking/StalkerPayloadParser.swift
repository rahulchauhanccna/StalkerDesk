//
//  StalkerPayloadParser.swift
//  StalkerDeskCore
//
//  Defensive mapping from the loosely-typed Stalker js payloads into the
//  strongly typed IPTV models.
//

import Foundation

enum StalkerPayloadParser {

    // MARK: Genres

    static func genres(from js: JSONValue) -> [StalkerGenre] {
        let candidates = js.arrayValue ?? js["data"]?.arrayValue ?? []
        var seen = Set<String>()
        var genres: [StalkerGenre] = []

        for item in candidates {
            guard let object = item.objectValue,
                  let id = object.firstString("id", "genre_id", "tv_genre_id"),
                  seen.insert(id).inserted else { continue }

            let title = object.firstString("title", "name") ?? "Genre \(id)"
            let alias = object.firstString("alias")
            let censored = object.firstBool("censored") ?? false
            genres.append(StalkerGenre(id: id, title: title, alias: alias, censored: censored))
        }

        return genres.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    // MARK: Channels

    static func channelPage(
        from js: JSONValue,
        page: Int,
        endpoint: URL?
    ) -> StalkerPage<StalkerChannel> {
        let object = js.objectValue
        let rawChannels = object?["data"]?.arrayValue ?? js.arrayValue ?? []
        let channels = rawChannels.compactMap { channel(from: $0, endpoint: endpoint) }
        let total = object?.firstInt("total_items") ?? object?.firstInt("total") ?? channels.count
        let maxPageItems = object?.firstInt("max_page_items") ?? max(channels.count, 1)

        return StalkerPage(
            items: channels,
            page: page,
            totalItems: max(total, channels.count),
            maxPageItems: max(maxPageItems, 1)
        )
    }

    static func channel(from value: JSONValue, endpoint: URL?) -> StalkerChannel? {
        guard let object = value.objectValue else { return nil }
        let id = object.firstString("id", "ch_id", "channel_id")
        let name = object.firstString("name", "title")
        guard let id, let name else { return nil }

        let command = object.firstString("cmd", "command", "url") ?? ""
        let number = object.firstString("number", "chnum", "channel_number")
        let logo = assetURL(object.firstString("logo", "tv_logo", "icon"), endpoint: endpoint)
        let genreID = object.firstString("tv_genre_id", "genre_id", "category_id")
        let xmltvID = object.firstString("xmltv_id", "epg_id")
        let isHD = object.firstBool("hd", "is_hd") ?? name.localizedCaseInsensitiveContains("HD")
        let isArchive = object.firstBool("tv_archive", "archive", "is_archive") ?? false
        let archiveDuration = object.firstInt("tv_archive_duration")
        let censored = object.firstBool("censored") ?? false

        return StalkerChannel(
            id: id,
            name: name,
            number: number,
            command: command,
            logoURL: logo,
            genreID: genreID,
            xmltvID: xmltvID,
            isHD: isHD,
            isArchive: isArchive,
            archiveDurationHours: archiveDuration,
            censored: censored
        )
    }

    // MARK: VOD / series

    static func mediaPage(
        from js: JSONValue,
        page: Int,
        endpoint: URL?,
        context: StalkerMediaContext,
        parentMovieID: String? = nil,
        parentSeasonID: String? = nil
    ) -> StalkerPage<StalkerMediaItem> {
        let object = js.objectValue
        let rawItems = object?["data"]?.arrayValue ?? js.arrayValue ?? []
        let items = rawItems.compactMap {
            mediaItem(
                from: $0,
                endpoint: endpoint,
                context: context,
                parentMovieID: parentMovieID,
                parentSeasonID: parentSeasonID
            )
        }
        let total = object?.firstInt("total_items") ?? object?.firstInt("total") ?? items.count
        let maxPageItems = object?.firstInt("max_page_items") ?? max(items.count, 1)

        return StalkerPage(
            items: items,
            page: page,
            totalItems: max(total, items.count),
            maxPageItems: max(maxPageItems, 1)
        )
    }

    static func mediaItem(
        from value: JSONValue,
        endpoint: URL?,
        context: StalkerMediaContext,
        parentMovieID: String? = nil,
        parentSeasonID: String? = nil
    ) -> StalkerMediaItem? {
        guard let object = value.objectValue else { return nil }

        let rawID = object.firstString("id", "video_id", "movie_id", "episode_id", "season_id")
        let kind: StalkerMediaKind
        switch context {
        case .vod:
            kind = (object.firstBool("is_series") ?? false) ? .series : .movie
        case .season:
            kind = .season
        case .episode:
            kind = .episode
        }

        let resolvedID: String?
        if kind == .season {
            resolvedID = object.firstString("season_id", "id") ?? rawID
        } else if kind == .episode {
            resolvedID = object.firstString("episode_id", "id") ?? rawID
        } else {
            resolvedID = rawID
        }
        guard let id = resolvedID else { return nil }

        let name = object.firstString("name", "title") ?? {
            switch kind {
            case .season: return "Season \(object.firstString("season_number") ?? id)"
            case .episode: return "Episode \(object.firstString("episode_number") ?? id)"
            default: return "Untitled"
            }
        }()

        let poster = assetURL(
            object.firstString(
                "screenshot_uri", "screenshot", "cover", "cover_big", "poster",
                "poster_path", "pic", "logo", "image", "original_poster"
            ),
            endpoint: endpoint
        )
        let movieID = object.firstString("movie_id", "video_id") ?? parentMovieID
        let seasonID = object.firstString("season_id") ?? parentSeasonID
        let episodeID = kind == .episode ? object.firstString("episode_id", "id") ?? id : object.firstString("episode_id")

        return StalkerMediaItem(
            id: id,
            name: name,
            description: object.firstString("description", "descr", "short_description") ?? "",
            command: object.firstString("cmd", "command") ?? "",
            posterURL: poster,
            year: object.first("year")?.stringValue,
            categoryID: object.firstString("category_id", "tv_genre_id"),
            kind: kind,
            movieID: movieID,
            seasonID: seasonID,
            episodeID: episodeID,
            duration: duration(from: object),
            rating: object.firstString("rating_imdb", "rating_kinopoisk", "rating"),
            director: object.firstString("director"),
            cast: object.firstString("actors", "cast"),
            genre: object.firstString("genre", "genres_str"),
            addedAt: dateString(object.firstString("added", "added_at", "created_at"), timezone: "UTC")
        )
    }

    private static func duration(from object: [String: JSONValue]) -> TimeInterval? {
        if let seconds = object.firstInt("duration"), seconds > 0 {
            return TimeInterval(seconds)
        }
        if let rawTime = object.first("time") {
            if let seconds = rawTime.intValue, seconds > 0 {
                return TimeInterval(seconds)
            }
            if let string = rawTime.stringValue {
                let components = string.split(separator: ":").compactMap { Int($0) }
                if components.count == 3 {
                    return TimeInterval(components[0] * 3600 + components[1] * 60 + components[2])
                }
                if components.count == 2 {
                    return TimeInterval(components[0] * 60 + components[1])
                }
            }
        }
        return nil
    }

    // MARK: EPG

    static func epgPrograms(
        from js: JSONValue,
        fallbackChannelID: String?,
        timezone: String
    ) -> [String: [StalkerEPGProgram]] {
        var grouped: [String: [StalkerEPGProgram]] = [:]

        func append(_ values: [JSONValue], channelHint: String?) {
            for value in values {
                guard let object = value.objectValue else { continue }
                let channelID = object.firstString("ch_id", "channel_id") ?? channelHint ?? fallbackChannelID ?? ""
                guard !channelID.isEmpty,
                      let program = epgProgram(from: object, channelID: channelID, timezone: timezone) else {
                    continue
                }
                grouped[channelID, default: []].append(program)
            }
        }

        if let data = js["data"] {
            if let object = data.objectValue {
                // Bulk get_epg_info shape: { "<channel id>": [ { ... } ] }
                for (channelID, value) in object {
                    if let values = value.arrayValue {
                        append(values, channelHint: channelID)
                    } else if value.objectValue != nil {
                        append([value], channelHint: channelID)
                    }
                }
            } else if let values = data.arrayValue {
                // Array shape: programs carry their own ch_id.
                append(values, channelHint: fallbackChannelID)
            }
        } else if let values = js.arrayValue {
            append(values, channelHint: fallbackChannelID)
        } else if js.objectValue != nil {
            append([js], channelHint: fallbackChannelID)
        }

        for key in grouped.keys {
            grouped[key]?.sort { $0.start < $1.start }
        }
        return grouped
    }

    static func epgProgram(from object: [String: JSONValue], channelID: String, timezone: String) -> StalkerEPGProgram? {
        let title = object.firstString("name", "title")
        let start = timestamp(object.firstInt("start_timestamp")) ?? dateString(object.firstString("time"), timezone: timezone)
        guard let start else { return nil }

        let duration = TimeInterval(object.firstInt("duration") ?? 0)
        let stop = timestamp(object.firstInt("stop_timestamp"))
            ?? dateString(object.firstString("time_to"), timezone: timezone)
            ?? start.addingTimeInterval(duration > 0 ? duration : 1800)

        let id = object.firstString("id") ?? "\(channelID)-\(Int(start.timeIntervalSince1970))"
        let description = object.firstString("descr", "description", "short_description") ?? ""
        let category = object.firstString("category", "genre", "category_name")
        let archive = object.firstBool("tv_archive", "archive") ?? false
        let recording = object.firstBool("rec", "has_recording") ?? false

        return StalkerEPGProgram(
            id: id,
            channelID: channelID,
            title: title ?? "Program",
            description: description,
            start: start,
            end: max(stop, start.addingTimeInterval(60)),
            category: category,
            isArchive: archive,
            hasRecording: recording
        )
    }

    // MARK: Account

    static func userProfile(from object: [String: JSONValue]) -> StalkerUserProfile {
        let status = object.first("status")?.stringValue
        let expiration = dateString(
            object.firstString("expire_billing_date", "subscribed_till", "expiration", "expire_date"),
            timezone: TimeZone.current.identifier
        )
        let normalizedStatus = status?.lowercased() ?? ""
        let blocked = ["blocked", "disabled", "expired", "inactive", "suspended"].contains { normalizedStatus.contains($0) }
        let expired = expiration.map { $0 < Date() } ?? false

        return StalkerUserProfile(
            id: object.firstString("id"),
            name: object.firstString("name", "full_name"),
            login: object.firstString("login"),
            mac: object.firstString("mac"),
            status: status,
            expirationDate: expiration,
            timezone: object.firstString("timezone"),
            locale: object.firstString("locale"),
            playToken: object.firstString("play_token"),
            tariffPlan: object.firstString("tariff_plan", "tariff"),
            isSubscribed: !blocked && !expired
        )
    }

    // MARK: create_link

    static func streamCommand(from js: JSONValue) -> String? {
        if let command = js.stringValue, !command.isEmpty {
            return command.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let object = js.objectValue {
            if let command = object.firstString("cmd", "url", "stream", "link") {
                return command.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    // MARK: Helpers

    static func assetURL(_ raw: String?, endpoint: URL?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let direct = URL(string: raw), direct.scheme != nil {
            return direct
        }
        guard let endpoint,
              var base = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return URL(string: raw)
        }
        base.path = "/"
        base.query = nil
        base.fragment = nil
        guard let root = base.url else { return nil }
        let escaped = raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
        return URL(string: escaped, relativeTo: root)?.absoluteURL
    }

    private static func timestamp(_ value: Int?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value))
    }

    static func dateString(_ value: String?, timezone: String) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if let seconds = TimeInterval(value), seconds > 100_000_000 {
            return Date(timeIntervalSince1970: seconds)
        }

        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "dd.MM.yyyy HH:mm",
            "MM/dd/yyyy HH:mm:ss",
            "yyyy-MM-dd"
        ]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timezone) ?? TimeZone(secondsFromGMT: 0)

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }

        let iso = ISO8601DateFormatter()
        return iso.date(from: value)
    }
}
