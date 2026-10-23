//
//  IPTVModels.swift
//  StalkerDeskCore
//
//  Typed, Sendable representations of the Stalker live-TV payloads. All values
//  crossing the actor boundary are immutable value types.
//

import Foundation

// MARK: - Genres

public struct StalkerGenre: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let alias: String?
    public let censored: Bool
    public let isSynthetic: Bool

    public init(id: String, title: String, alias: String? = nil, censored: Bool = false, isSynthetic: Bool = false) {
        self.id = id
        self.title = title
        self.alias = alias
        self.censored = censored
        self.isSynthetic = isSynthetic
    }

    /// The portal's get_ordered_list may omit a genre filter to mean all
    /// channels. This sentinel never goes over the wire.
    public static let all = StalkerGenre(id: "*", title: "All Channels", alias: "all", isSynthetic: true)

    public var queryGenreID: String? {
        id == "*" ? nil : id
    }
}

// MARK: - Channels

public struct StalkerChannel: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let number: String?
    public let command: String
    public let logoURL: URL?
    public let genreID: String?
    public let xmltvID: String?
    public let isHD: Bool
    public let isArchive: Bool
    public let archiveDurationHours: Int?
    public let censored: Bool

    public init(
        id: String,
        name: String,
        number: String? = nil,
        command: String,
        logoURL: URL? = nil,
        genreID: String? = nil,
        xmltvID: String? = nil,
        isHD: Bool = false,
        isArchive: Bool = false,
        archiveDurationHours: Int? = nil,
        censored: Bool = false
    ) {
        self.id = id
        self.name = name
        self.number = number
        self.command = command
        self.logoURL = logoURL
        self.genreID = genreID
        self.xmltvID = xmltvID
        self.isHD = isHD
        self.isArchive = isArchive
        self.archiveDurationHours = archiveDurationHours
        self.censored = censored
    }

    public var displayNumber: String {
        number?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

public struct StalkerPage<Item: Sendable>: Sendable {
    public let items: [Item]
    public let page: Int
    public let totalItems: Int
    public let maxPageItems: Int

    public init(items: [Item], page: Int, totalItems: Int, maxPageItems: Int) {
        self.items = items
        self.page = page
        self.totalItems = totalItems
        self.maxPageItems = maxPageItems
    }

    public var totalPages: Int {
        guard maxPageItems > 0, totalItems > 0 else { return 1 }
        return Int(ceil(Double(totalItems) / Double(maxPageItems)))
    }
}

// MARK: - Video catalog

public enum StalkerContentMode: String, CaseIterable, Identifiable, Sendable {
    case live
    case movies
    case series

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .live: return "Live TV"
        case .movies: return "Movies"
        case .series: return "Web Series"
        }
    }

    public var shortTitle: String {
        switch self {
        case .live: return "Live"
        case .movies: return "Movies"
        case .series: return "Series"
        }
    }

    public var symbolName: String {
        switch self {
        case .live: return "tv"
        case .movies: return "film"
        case .series: return "rectangle.stack.badge.play"
        }
    }

    public var isLive: Bool { self == .live }
}

public enum StalkerMediaKind: String, Sendable {
    case movie
    case series
    case season
    case episode
}

public struct StalkerMediaItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let command: String
    public let posterURL: URL?
    public let year: String?
    public let categoryID: String?
    public let kind: StalkerMediaKind
    public let movieID: String?
    public let seasonID: String?
    public let episodeID: String?
    public let duration: TimeInterval?
    public let rating: String?
    public let director: String?
    public let cast: String?
    public let genre: String?
    public let addedAt: Date?

    public init(
        id: String,
        name: String,
        description: String = "",
        command: String = "",
        posterURL: URL? = nil,
        year: String? = nil,
        categoryID: String? = nil,
        kind: StalkerMediaKind,
        movieID: String? = nil,
        seasonID: String? = nil,
        episodeID: String? = nil,
        duration: TimeInterval? = nil,
        rating: String? = nil,
        director: String? = nil,
        cast: String? = nil,
        genre: String? = nil,
        addedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.command = command
        self.posterURL = posterURL
        self.year = year
        self.categoryID = categoryID
        self.kind = kind
        self.movieID = movieID
        self.seasonID = seasonID
        self.episodeID = episodeID
        self.duration = duration
        self.rating = rating
        self.director = director
        self.cast = cast
        self.genre = genre
        self.addedAt = addedAt
    }

    public var isSeries: Bool { kind == .series }
    public var isSeason: Bool { kind == .season }
    public var isEpisode: Bool { kind == .episode }
    public var isMovie: Bool { kind == .movie }

    public var yearLabel: String? {
        guard let year, !year.isEmpty else { return nil }
        return year
    }

    public var ratingLabel: String? {
        guard let rating, !rating.isEmpty,
              let value = Double(rating), value > 0 else { return nil }
        return "★ \(rating)"
    }

    public var addedLabel: String? {
        guard let addedAt else { return nil }
        return "Added " + addedAt.formatted(.dateTime.month(.abbreviated).day())
    }

    public var addedSortValue: Date {
        addedAt ?? .distantPast
    }

    public var durationLabel: String? {
        guard let duration, duration > 0 else { return nil }
        let minutes = Int(duration / 60)
        guard minutes > 0 else { return nil }
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }

    public var episodeNumberLabel: String? {
        guard kind == .episode else { return nil }
        if let episodeID, let number = Int(episodeID) {
            return "Episode \(number)"
        }
        return nil
    }
}

public enum StalkerMediaContext: Sendable {
    case vod
    case season
    case episode
}

// MARK: - EPG

public struct StalkerEPGProgram: Identifiable, Hashable, Sendable {
    public let id: String
    public let channelID: String
    public let title: String
    public let description: String
    public let start: Date
    public let end: Date
    public let category: String?
    public let isArchive: Bool
    public let hasRecording: Bool

    public init(
        id: String,
        channelID: String,
        title: String,
        description: String,
        start: Date,
        end: Date,
        category: String? = nil,
        isArchive: Bool = false,
        hasRecording: Bool = false
    ) {
        self.id = id
        self.channelID = channelID
        self.title = title
        self.description = description
        self.start = start
        self.end = end
        self.category = category
        self.isArchive = isArchive
        self.hasRecording = hasRecording
    }

    public var duration: TimeInterval {
        max(0, end.timeIntervalSince(start))
    }

    public func isLive(at date: Date = Date()) -> Bool {
        date >= start && date < end
    }

    public func progress(at date: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(date.timeIntervalSince(start) / duration, 0), 1)
    }

    public var timeRangeLabel: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
    }
}

// MARK: - Account

public struct StalkerUserProfile: Hashable, Sendable {
    public let id: String?
    public let name: String?
    public let login: String?
    public let mac: String?
    public let status: String?
    public let expirationDate: Date?
    public let timezone: String?
    public let locale: String?
    public let playToken: String?
    public let tariffPlan: String?
    public let isSubscribed: Bool

    public init(
        id: String? = nil,
        name: String? = nil,
        login: String? = nil,
        mac: String? = nil,
        status: String? = nil,
        expirationDate: Date? = nil,
        timezone: String? = nil,
        locale: String? = nil,
        playToken: String? = nil,
        tariffPlan: String? = nil,
        isSubscribed: Bool = true
    ) {
        self.id = id
        self.name = name
        self.login = login
        self.mac = mac
        self.status = status
        self.expirationDate = expirationDate
        self.timezone = timezone
        self.locale = locale
        self.playToken = playToken
        self.tariffPlan = tariffPlan
        self.isSubscribed = isSubscribed
    }

    public var displayName: String {
        name ?? login ?? "Stalker account"
    }
}

// MARK: - Session

/// Immutable authorization snapshot. The player receives this indirectly via
/// ResolvedStream headers, so token refresh in the API actor does not interrupt
/// current playback.
public struct PortalSession: Sendable {
    public let portalID: UUID
    public let endpoint: URL
    public let token: String
    public let cookies: [String: String]
    public let userProfile: StalkerUserProfile
    public let issuedAt: Date

    public init(
        portalID: UUID,
        endpoint: URL,
        token: String,
        cookies: [String: String],
        userProfile: StalkerUserProfile,
        issuedAt: Date
    ) {
        self.portalID = portalID
        self.endpoint = endpoint
        self.token = token
        self.cookies = cookies
        self.userProfile = userProfile
        self.issuedAt = issuedAt
    }

    public var referer: URL? {
        PortalURLResolver.referer(for: endpoint)
    }
}

// MARK: - Streams

public struct ResolvedStream: Sendable, Hashable {
    public let channelID: String
    public let url: URL
    public let headers: [String: String]
    public let resolvedAt: Date
    public let rawCommand: String

    public init(channelID: String, url: URL, headers: [String: String], resolvedAt: Date = Date(), rawCommand: String = "") {
        self.channelID = channelID
        self.url = url
        self.headers = headers
        self.resolvedAt = resolvedAt
        self.rawCommand = rawCommand
    }
}

public enum PlaybackEnginePreference: String, CaseIterable, Codable, Sendable, Identifiable {
    case automatic
    case avPlayer
    case vlcKit

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .avPlayer: return "AVPlayer"
        case .vlcKit: return "VLCKit"
        }
    }
}

public enum PlaybackEngineKind: String, Sendable {
    case avPlayer = "AVPlayer"
    case vlcKit = "VLCKit"
}

public struct PlaybackRequest: Hashable, Sendable {
    public let url: URL
    public let headers: [String: String]
    public let title: String
    public let subtitle: String
    public let channelID: String?
    public let isLive: Bool
    public let preferredEngine: PlaybackEnginePreference

    public init(
        url: URL,
        headers: [String: String] = [:],
        title: String,
        subtitle: String = "",
        channelID: String? = nil,
        isLive: Bool = true,
        preferredEngine: PlaybackEnginePreference = .automatic
    ) {
        self.url = url
        self.headers = headers
        self.title = title
        self.subtitle = subtitle
        self.channelID = channelID
        self.isLive = isLive
        self.preferredEngine = preferredEngine
    }

    /// The player layer and VLCKit should never receive credentials accidentally
    /// in logs. This returns a redacted URL suitable for diagnostics.
    public var diagnosticURL: String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<invalid-url>"
        }
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? "<invalid-url>"
    }
}

// MARK: - Stream command parsing

/// Parses the value returned by action=create_link. Portals return commands such
/// as "ffmpeg http://10.0.0.5/live/123.ts?token=..." or percent-encoded URLs,
/// occasionally with localhost as the host.
public enum StreamCommandParser {
    public static func extractURL(from rawCommand: String, portalEndpoint: URL?) -> URL? {
        var command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }

        // Percent-decoding twice handles both encoded query values and fully
        // encoded command strings without touching already valid URL syntax.
        if let decoded = command.removingPercentEncoding, decoded != command {
            command = decoded
        }

        // Strip common prefixes emitted by middleware.
        for prefix in ["ffmpeg ", "auto ", "proxy ", "ffmpeg%20"] where command.lowercased().hasPrefix(prefix) {
            command.removeFirst(prefix.count)
            command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Some portals wrap the URL in quotes.
        command = command.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if let space = command.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "\r" }) {
            command = String(command[..<space])
        }

        if let parsed = URL(string: command),
           let scheme = parsed.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return rewriteLocalhost(parsed, portalEndpoint: portalEndpoint)
        }

        // VOD create_link may return a server-relative media path such as
        // /media/file_123.mpg. Resolve it against the portal origin.
        if command.hasPrefix("/"), let portalEndpoint,
           var components = URLComponents(url: portalEndpoint, resolvingAgainstBaseURL: false) {
            components.path = command
            components.query = nil
            components.fragment = nil
            return components.url
        }

        // Last resort: percent-escape spaces and ask Foundation again.
        let escaped = command.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? command
        guard let parsed = URL(string: escaped),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return rewriteLocalhost(parsed, portalEndpoint: portalEndpoint)
    }

    private static func rewriteLocalhost(_ url: URL, portalEndpoint: URL?) -> URL {
        guard let portalEndpoint,
              let host = url.host?.lowercased(),
              host == "localhost" || host == "127.0.0.1" || host == "::1",
              let portalComponents = URLComponents(url: portalEndpoint, resolvingAgainstBaseURL: false),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        components.scheme = components.scheme ?? portalComponents.scheme
        components.host = portalComponents.host
        // Only inherit the portal port when the stream used the default port,
        // otherwise preserve an explicit stream port.
        if let port = components.port, port != 80, port != 443 {
            // keep it
        } else {
            components.port = portalComponents.port
        }
        return components.url ?? url
    }
}
