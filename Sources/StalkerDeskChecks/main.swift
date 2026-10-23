//
//  main.swift
//  StalkerDeskChecks
//
//  Headless protocol checks for StalkerDeskCore. This target intentionally has
//  no XCTest dependency so it runs with the Command Line Tools alone:
//
//      swift run StalkerDeskChecks
//
//  It exercises handshake/profile authentication, endpoint discovery, genres,
//  paginated channels, EPG, create_link resolution, cookie forwarding and the
//  401 single-flight token refresh path against an in-process mock portal.
//

import Darwin
import Foundation
import StalkerDeskCore

// MARK: - Harness

struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw CheckFailure(message: message)
    }
}

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) throws {
    if lhs != rhs {
        throw CheckFailure(message: "\(message) (expected \(rhs), got \(lhs))")
    }
}

// MARK: - Raw VOD inspector

final class VODDumpTransport: StalkerHTTPTransport, @unchecked Sendable {
    private let inner = URLSessionStalkerTransport()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result = try await inner.send(request)
        let query = request.url?.query ?? ""
        if query.contains("type=vod"), query.contains("action=get_ordered_list") {
            inspect(result.0)
        }
        return result
    }

    private func inspect(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let js = root["js"] as? [String: Any],
              let rows = js["data"] as? [[String: Any]],
              let first = rows.first else {
            print("  [dump] unable to parse VOD rows")
            return
        }
        print("  [dump] row keys: \(first.keys.sorted().joined(separator: ", "))")
        let interesting = first.keys.filter {
            let lower = $0.lowercased()
            return lower.contains("image") || lower.contains("cover") || lower.contains("poster")
                || lower.contains("screen") || lower.contains("pic") || lower.contains("icon")
                || lower.contains("added") || lower.contains("date") || lower.contains("year")
                || lower.contains("rating") || lower.contains("time")
        }.sorted()
        for key in interesting {
            print("  [dump] \(key) = \(String(describing: first[key] ?? "nil"))")
        }
        print("  [dump] total_items=\(js["total_items"] ?? "?") max_page_items=\(js["max_page_items"] ?? "?")")
    }
}

// MARK: - Portal mock

struct MockResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    init(status: Int = 200, headers: [String: String] = [:], json: String) {
        self.status = status
        self.headers = headers.merging(["Content-Type": "application/json"]) { _, new in new }
        self.body = Data(json.utf8)
    }

    init(status: Int, headers: [String: String] = [:]) {
        self.status = status
        self.headers = headers
        self.body = Data("{}".utf8)
    }
}

actor MockTransport: StalkerHTTPTransport {
    typealias Handler = @Sendable (URLRequest) async throws -> MockResponse

    private let handler: Handler
    private var recordedRequests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        let response = try await handler(request)
        guard let url = request.url,
              let http = HTTPURLResponse(
                url: url,
                statusCode: response.status,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
              ) else {
            throw URLError(.badServerResponse)
        }
        return (response.body, http)
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}

actor MockBackend {
    private(set) var handshakeCount = 0
    private(set) var profileCount = 0
    private var acceptedHandshakePath = "/server/load.php"
    private var failNextGenresRequest = false
    private var tokenSequence = 0

    func setAcceptedHandshakePath(_ path: String) {
        acceptedHandshakePath = path
    }

    func setFailNextGenres() {
        failNextGenresRequest = true
    }

    func response(for request: URLRequest) throws -> MockResponse {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.queryItems else {
            return MockResponse(status: 400)
        }

        func value(_ name: String) -> String? {
            query.first(where: { $0.name == name })?.value
        }

        let action = value("action") ?? ""
        let path = components.path
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""

        if action == "handshake" {
            guard path == acceptedHandshakePath else {
                return MockResponse(status: 404, headers: ["Content-Type": "text/html"])
            }
            handshakeCount += 1
            tokenSequence += 1
            let token = "TESTTOKEN\(tokenSequence)"
            return MockResponse(
                headers: ["Set-Cookie": "PHPSESSID=session\(tokenSequence); Path=/"],
                json: "{\"js\":{\"token\":\"\(token)\",\"random\":\"abc\",\"not_valid\":0}}"
            )
        }

        guard path == acceptedHandshakePath, authorization.hasPrefix("Bearer TESTTOKEN") else {
            return MockResponse(status: 401, json: "{\"error\":\"Authorization failed.\"}")
        }

        switch action {
        case "get_profile":
            profileCount += 1
            return MockResponse(json: """
            {"js":{"id":"42","name":"Test Account","login":"viewer","mac":"00:1A:79:AB:CD:EF",
            "status":"0","expire_billing_date":"2099-01-01 00:00:00","timezone":"Europe/London",
            "locale":"en","play_token":"PLAYTOKEN"}}
            """)

        case "get_genres":
            if failNextGenresRequest {
                failNextGenresRequest = false
                return MockResponse(status: 401, json: "{\"error\":\"session expired\"}")
            }
            return MockResponse(json: """
            {"js":[{"id":"1","title":"News","alias":"news","censored":0},
                   {"id":"2","title":"Sports","alias":"sports","censored":0}]}
            """)

        case "get_categories":
            return MockResponse(json: """
            {"js":[{"id":"10","title":"Movies & Shows"},{"id":"11","title":"Series"}]}
            """)

        case "get_episode_stream":
            return MockResponse(json: """
            {"js":{"cmd":"ffmpeg http://portal.test/vod/episode1.mp4"}}
            """)

        case "get_ordered_list":
            if value("type") == "vod" {
                if let movieID = value("movie_id") {
                    let seasonID = value("season_id") ?? "0"
                    if seasonID == "0" {
                        return MockResponse(json: """
                        {"js":{"total_items":1,"max_page_items":10,"data":[
                          {"id":"season1","season_id":"season1","movie_id":"\(movieID)","name":"Season 1","is_season":1}
                        ]}}
                        """)
                    }
                    return MockResponse(json: """
                    {"js":{"total_items":1,"max_page_items":10,"data":[
                      {"id":"episode1","episode_id":"episode1","movie_id":"\(movieID)","season_id":"\(seasonID)","name":"Pilot","is_season":0}
                    ]}}
                    """)
                }
                return MockResponse(json: """
                {"js":{"total_items":2,"max_page_items":10,"data":[
                  {"id":"movie1","name":"Test Movie","is_series":"0","cmd":"ffmpeg http://portal.test/vod/movie1.mp4",
                   "screenshot":"/posters/movie1.jpg","year":"2024","duration":"5400","rating_imdb":"8.1",
                   "description":"A test movie."},
                  {"id":"series1","name":"Test Series","is_series":"1","screenshot":"/posters/series1.jpg",
                   "year":"2025","description":"A test series."}
                ]}}
                """)
            }

            let page = Int(value("p") ?? "1") ?? 1
            if page == 2 {
                return MockResponse(json: """
                {"js":{"total_items":2,"max_page_items":1,"data":[
                  {"id":"102","name":"News Two","number":"2","cmd":"ffmpeg http://portal.test/live/102.ts",
                   "logo":"/logos/102.png","tv_genre_id":"1","hd":1}
                ]}}
                """)
            }
            return MockResponse(json: """
            {"js":{"total_items":2,"max_page_items":1,"data":[
              {"id":"101","name":"News One","number":"1","cmd":"ffmpeg http://localhost/live/101.ts?token=streamtoken",
               "logo":"/logos/101.png","tv_genre_id":"1","xmltv_id":"news1","tv_archive":1,"tv_archive_duration":72}
            ]}}
            """)

        case "create_link":
            return MockResponse(json: """
            {"js":{"id":"link1","cmd":"ffmpeg http://localhost/live/101.ts?token=streamtoken&mac=00%3A1A%3A79%3AAB%3ACD%3AEF"}}
            """)

        case "get_epg_info":
            return MockResponse(json: """
            {"js":{"data":{"101":[
              {"id":"program1","ch_id":"101","name":"Evening News","descr":"Today's headlines",
               "start_timestamp":"1735689600","stop_timestamp":"1735693200","duration":"3600",
               "category":"News","tv_archive":1}
            ]}}}
            """)

        case "get_short_epg":
            return MockResponse(json: """
            {"js":{"data":[{"id":"short1","ch_id":"101","name":"Short Guide","descr":"fallback",
              "start_timestamp":"1735689600","stop_timestamp":"1735693200"}]}}
            """)

        default:
            return MockResponse(status: 400, json: "{\"error\":\"unknown action\"}")
        }
    }
}

// MARK: - Checks

func makeClient(backend: MockBackend) -> (StalkerClient, MockTransport) {
    let transport = MockTransport { request in
        try await backend.response(for: request)
    }
    let client = StalkerClient(
        configuration: StalkerClientConfiguration(enableSessionCache: false, enableLocalhostRewrite: true),
        transport: transport,
        sessionCache: nil
    )
    return (client, transport)
}

func testHandshakeProfileGenresChannelsEPGAndCreateLink() async throws {
    let backend = MockBackend()
    let (client, transport) = makeClient(backend: backend)
    let profile = PortalProfile(
        name: "Test",
        portalURL: "http://portal.test/c/",
        macAddress: "00:1A:79:AB:CD:EF",
        timezone: "Europe/London"
    )

    let session = try await client.connect(profile: profile, credentials: nil)
    try expectEqual(session.endpoint.absoluteString, "http://portal.test/server/load.php", "Endpoint discovery")
    try expectEqual(session.token, "TESTTOKEN1", "Handshake token")
    try expectEqual(session.userProfile.name, "Test Account", "Profile name")

    let genres = try await client.fetchGenres()
    try expectEqual(genres.map(\.title), ["News", "Sports"], "Genres")

    let channels = try await client.fetchAllChannels(genreID: "1")
    try expectEqual(channels.count, 2, "Paginated channel count")
    try expectEqual(channels.first?.name, "News One", "First channel")
    try expect(channels.first?.isArchive == true, "Archive flag")
    try expectEqual(channels.last?.name, "News Two", "Second page channel")

    let epg = try await client.fetchEPG(channelID: "101", hours: 6)
    try expectEqual(epg.count, 1, "EPG program count")
    try expectEqual(epg.first?.title, "Evening News", "EPG title")
    try expectEqual(epg.first?.category, "News", "EPG category")

    let stream = try await client.resolveStream(for: channels[0])
    try expectEqual(stream.url.host, "portal.test", "Localhost rewrite")
    try expectEqual(stream.url.path, "/live/101.ts", "Stream path")
    try expectEqual(stream.headers["Referer"], "http://portal.test/c/", "Stream referer")
    try expect(stream.headers["Cookie"]?.contains("PHPSESSID=session1") == true, "Stream cookie forwarding")
    try expectEqual(stream.headers["Authorization"], "Bearer TESTTOKEN1", "Stream authorization")

    let requests = await transport.requests()
    guard let profileRequest = requests.first(where: { $0.url?.query?.contains("get_profile") == true }) else {
        throw CheckFailure(message: "get_profile request was not sent")
    }
    try expect(profileRequest.value(forHTTPHeaderField: "User-Agent")?.contains("MAG200") == true, "MAG user agent")
    try expect(
        profileRequest.value(forHTTPHeaderField: "Cookie")?.contains("mac=00%3A1A%3A79%3AAB%3ACD%3AEF") == true,
        "MAC cookie"
    )
    try expect(
        profileRequest.value(forHTTPHeaderField: "Cookie")?.contains("PHPSESSID=session1") == true,
        "Cookie jar forwarding"
    )

    print("  PASS handshake, profile, genres, channels, EPG, create_link")
}

func testEndpointFallbackFindsPortalPHP() async throws {
    let backend = MockBackend()
    await backend.setAcceptedHandshakePath("/c/portal.php")
    let (client, _) = makeClient(backend: backend)
    let profile = PortalProfile(
        name: "Fallback",
        portalURL: "http://portal.test/c/",
        macAddress: "00:1A:79:AB:CD:EF",
        timezone: "UTC"
    )

    let session = try await client.connect(profile: profile, credentials: nil)
    try expectEqual(session.endpoint.absoluteString, "http://portal.test/c/portal.php", "Fallback endpoint")
    try expectEqual(session.userProfile.login, "viewer", "Fallback profile")
    print("  PASS endpoint fallback")
}

func testTokenRefreshOn401() async throws {
    let backend = MockBackend()
    let (client, transport) = makeClient(backend: backend)
    let profile = PortalProfile(
        name: "Refresh",
        portalURL: "http://portal.test/c/",
        macAddress: "00:1A:79:AB:CD:EF",
        timezone: "UTC"
    )

    _ = try await client.connect(profile: profile, credentials: nil)
    await backend.setFailNextGenres()
    let genres = try await client.fetchGenres()
    try expectEqual(genres.count, 2, "Genres after refresh")

    let handshakes = await backend.handshakeCount
    try expectEqual(handshakes, 2, "Single refresh handshake")

    let requests = await transport.requests()
    guard let lastGenres = requests.last(where: { $0.url?.query?.contains("get_genres") == true }) else {
        throw CheckFailure(message: "genres request was not sent")
    }
    try expectEqual(lastGenres.value(forHTTPHeaderField: "Authorization"), "Bearer TESTTOKEN2", "Retried with refreshed token")
    print("  PASS 401 single-flight token refresh")
}

func testMACAddress() throws {
    try expectEqual(MACAddress("00-1a-79-ab-cd-ef")?.formatted, "00:1A:79:AB:CD:EF", "MAC normalization")
    try expectEqual(MACAddress("001A79ABCDEF")?.compact, "001A79ABCDEF", "MAC compact form")
    try expectEqual(MACAddress("00:1A:79:AB:CD:EF")?.cookieValue, "00%3A1A%3A79%3AAB%3ACD%3AEF", "MAC cookie encoding")
    try expect(MACAddress("00:1A:79:AB:CD:EF")?.isMAGVirtual == true, "MAG OUI detection")
    try expect(MACAddress("00:1A:79:AB:CD") == nil, "Reject short MAC")
    try expect(MACAddress("ff:ff:ff:ff:ff:ff") == nil, "Reject broadcast MAC")
    try expectEqual(MACAddress.formatInput("001a79abcdef"), "00:1A:79:AB:CD:EF", "MAC input formatter")
    print("  PASS MAC validation and formatting")
}

func testPortalURLCandidates() throws {
    let candidates = PortalURLResolver.candidates(from: "portal.test/c/")
    try expect(candidates.contains(where: { $0.path == "/server/load.php" }), "Candidate /server/load.php")
    try expect(candidates.contains(where: { $0.path == "/stalker_portal/server/load.php" }), "Candidate /stalker_portal/server/load.php")
    try expect(candidates.contains(where: { $0.path == "/c/portal.php" }), "Candidate /c/portal.php")

    let explicit = PortalURLResolver.candidates(from: "http://portal.test/stalker_portal/server/load.php")
    try expectEqual(explicit.map(\.absoluteString), ["http://portal.test/stalker_portal/server/load.php"], "Explicit endpoint")

    let nested = PortalURLResolver.candidates(from: "http://portal.test/stalker_portal/")
    try expectEqual(nested.first?.path, "/stalker_portal/server/load.php", "Nested portal endpoint")

    // Regression: a bare host used to generate new.jiotv.beserver/... because
    // the root path was empty. Every candidate must keep the original host.
    let root = PortalURLResolver.candidates(from: "http://new.jiotv.be/")
    try expect(!root.isEmpty, "Root portal candidates")
    for candidate in root {
        try expectEqual(candidate.host, "new.jiotv.be", "Root candidate host \(candidate.absoluteString)")
    }
    try expect(
        root.contains(where: { $0.path == "/stalker_portal/server/load.php" }),
        "Root candidates include /stalker_portal/server/load.php"
    )
    try expect(
        !root.contains(where: { $0.host == "new.jiotv.beserver" || $0.host == "new.jiotv.bestalker_portal" }),
        "Root candidates must not corrupt the host"
    )
    print("  PASS portal URL candidate resolution")
}

func testStreamCommandParsing() throws {
    let endpoint = URL(string: "http://portal.test/server/load.php")!
    let url = StreamCommandParser.extractURL(
        from: "ffmpeg http://localhost:80/live/42.ts?token=abc",
        portalEndpoint: endpoint
    )
    try expectEqual(url?.host, "portal.test", "Stream localhost rewrite")
    try expectEqual(url?.path, "/live/42.ts", "Stream path")

    let encoded = StreamCommandParser.extractURL(
        from: "ffmpeg%20http%3A%2F%2Fportal.test%2Flive%2F42.ts",
        portalEndpoint: endpoint
    )
    try expectEqual(encoded?.absoluteString, "http://portal.test/live/42.ts", "Percent-encoded command")
    try expect(StreamCommandParser.extractURL(from: "not-a-url", portalEndpoint: endpoint) == nil, "Reject non-URL command")
    print("  PASS stream command parsing")
}

func testJSONSanitization() throws {
    let json = try StalkerJSONParser.parse(Data("{\"js\":{\"token\":\"abc\",},}".utf8))
    try expectEqual(json["js"]?["token"]?.stringValue, "abc", "Trailing comma sanitization")
    print("  PASS lenient JSON parsing")
}

func testKeychainCredentialStore() throws {
    let portalID = UUID()
    do {
        try PortalCredentialStore.savePassword("s3cret-value", portalID: portalID)
        let loaded = PortalCredentialStore.password(for: portalID)
        try expectEqual(loaded, "s3cret-value", "Keychain password round trip")
        try PortalCredentialStore.deletePassword(portalID: portalID)
        try expect(PortalCredentialStore.password(for: portalID) == nil, "Keychain delete")
        print("  PASS Keychain credential store")
    } catch let error as KeychainError {
        // Headless CI and some Command Line Tools sessions do not have a
        // user-keychain entitlement. The app itself runs as a bundled GUI app.
        try? PortalCredentialStore.deletePassword(portalID: portalID)
        print("  SKIP Keychain credential store (\(error.localizedDescription))")
    } catch {
        try? PortalCredentialStore.deletePassword(portalID: portalID)
        throw error
    }
}

@MainActor
func testVODCatalogAndSeries() async throws {
    let backend = MockBackend()
    let (client, _) = makeClient(backend: backend)
    let profile = PortalProfile(
        name: "VOD",
        portalURL: "http://portal.test/c/",
        macAddress: "00:1A:79:AB:CD:EF",
        timezone: "UTC"
    )

    _ = try await client.connect(profile: profile, credentials: nil)
    let categories = try await client.fetchVODCategories()
    try expectEqual(categories.map(\.title), ["Movies & Shows", "Series"], "VOD categories")

    let items = try await client.fetchAllVOD(categoryID: "10")
    try expectEqual(items.count, 2, "VOD item count")
    guard let movie = items.first(where: \.isMovie),
          let series = items.first(where: \.isSeries) else {
        throw CheckFailure(message: "Expected one movie and one series")
    }
    try expectEqual(movie.name, "Test Movie", "Movie mapping")
    try expectEqual(movie.posterURL?.absoluteString, "http://portal.test/posters/movie1.jpg", "Poster URL")
    try expectEqual(movie.year, "2024", "Movie year")
    try expectEqual(series.name, "Test Series", "Series mapping")

    let movieStream = try await client.resolveStream(for: movie)
    try expectEqual(movieStream.url.host, "portal.test", "Movie stream URL")

    let seasons = try await client.fetchSeasons(seriesID: series.id)
    try expectEqual(seasons.count, 1, "Season count")
    guard let season = seasons.first else { throw CheckFailure(message: "Missing season") }
    try expectEqual(season.name, "Season 1", "Season mapping")

    let episodes = try await client.fetchEpisodes(seriesID: series.id, seasonID: season.id)
    try expectEqual(episodes.count, 1, "Episode count")
    guard let episode = episodes.first else { throw CheckFailure(message: "Missing episode") }
    try expectEqual(episode.name, "Pilot", "Episode mapping")

    let episodeStream = try await client.resolveStream(for: episode)
    try expectEqual(episodeStream.url.absoluteString, "http://portal.test/vod/episode1.mp4", "Episode stream URL")

    print("  PASS VOD, series, seasons, episodes and episode playback")
}

@MainActor
func testCoreDataPersistence() async throws {
    let persistence = PersistenceController(inMemory: true)
    try await persistence.load()

    let profile = PortalProfile(
        name: "Persisted",
        portalURL: "http://portal.test/c/",
        macAddress: "00:1A:79:AB:CD:EF",
        deviceID: DeviceIdentity.defaultDeviceID(for: MACAddress("00:1A:79:AB:CD:EF")!),
        serialNumber: DeviceIdentity.defaultSerial(for: MACAddress("00:1A:79:AB:CD:EF")!),
        timezone: "Europe/London"
    )

    let saved = try persistence.upsert(profile)
    try expectEqual(saved.name, "Persisted", "Core Data save")

    var profiles = try persistence.fetchProfiles()
    try expectEqual(profiles.count, 1, "Core Data fetch count")
    try expectEqual(profiles.first?.id, profile.id, "Core Data id round trip")
    try expectEqual(profiles.first?.macAddress, "00:1A:79:AB:CD:EF", "Core Data MAC round trip")

    try persistence.updateLastConnected(id: profile.id)
    profiles = try persistence.fetchProfiles()
    try expect(profiles.first?.lastConnectedAt != nil, "Core Data lastConnectedAt update")

    try persistence.delete(id: profile.id)
    try expectEqual(try persistence.fetchProfiles().count, 0, "Core Data delete")
    print("  PASS Core Data profile store")
}

// MARK: - Optional live diagnostic

func runVODFieldDumpIfRequested() async {
    let environment = ProcessInfo.processInfo.environment
    guard environment["STALKERDESK_LIVE_DUMP_VOD"] == "1" else { return }
    guard let portalURL = environment["STALKERDESK_LIVE_PORTAL"],
          let macAddress = environment["STALKERDESK_LIVE_MAC"] else { return }

    let client = StalkerClient(
        configuration: StalkerClientConfiguration(enableSessionCache: false),
        transport: VODDumpTransport(),
        sessionCache: nil
    )
    let profile = PortalProfile(
        name: "VOD dump",
        portalURL: portalURL,
        macAddress: macAddress,
        timezone: environment["STALKERDESK_LIVE_TIMEZONE"] ?? TimeZone.current.identifier
    )

    do {
        _ = try await client.connect(profile: profile, credentials: nil)
        let categories = try await client.fetchVODCategories()
        let needle = environment["STALKERDESK_LIVE_VOD_CATEGORY"] ?? "MOVIES"
        guard let category = categories.first(where: { $0.title.localizedCaseInsensitiveContains(needle) }) else {
            print("No category matching \(needle)")
            return
        }
        _ = try await client.fetchVODPage(categoryID: category.id, page: 1)
    } catch {
        print("VOD dump failed: \(error.localizedDescription)")
    }
}

func runLivePortalDiagnosticIfRequested() async {
    let environment = ProcessInfo.processInfo.environment
    guard environment["STALKERDESK_LIVE_CHECK"] == "1" else { return }
    guard let portalURL = environment["STALKERDESK_LIVE_PORTAL"],
          let macAddress = environment["STALKERDESK_LIVE_MAC"] else {
        print("Live diagnostic skipped: set STALKERDESK_LIVE_PORTAL and STALKERDESK_LIVE_MAC.")
        return
    }

    let timezone = environment["STALKERDESK_LIVE_TIMEZONE"] ?? TimeZone.current.identifier
    let client = StalkerClient(
        configuration: StalkerClientConfiguration(enableSessionCache: false),
        transport: nil,
        sessionCache: nil
    )
    let profile = PortalProfile(
        name: "Live diagnostic",
        portalURL: portalURL,
        macAddress: macAddress,
        timezone: timezone
    )

    print("Live diagnostic for \(portalURL)")
    print("  endpoint candidates:")
    for candidate in PortalURLResolver.candidates(from: portalURL) {
        print("    \(candidate.absoluteString)")
    }
    do {
        let session = try await client.connect(profile: profile, credentials: nil)
        print("  connected endpoint: \(session.endpoint.absoluteString)")
        print("  token length: \(session.token.count)")
        print("  account: \(session.userProfile.displayName); subscribed: \(session.userProfile.isSubscribed)")
        let vodOnly = ProcessInfo.processInfo.environment["STALKERDESK_LIVE_VOD_ONLY"] == "1"

        if !vodOnly {
            let genres = try await client.fetchGenres()
            print("  genres: \(genres.count)")
            if let first = genres.first {
                let channels = try await client.fetchAllChannels(genreID: first.id)
                print("  channels in \(first.title): \(channels.count)")
            }
        }

        let vodCategories = try await client.fetchVODCategories()
        print("  VOD categories: \(vodCategories.count)")

        if ProcessInfo.processInfo.environment["STALKERDESK_LIVE_VOD_FIRST_PAGE"] == "1",
           let category = {
               if let needle = ProcessInfo.processInfo.environment["STALKERDESK_LIVE_VOD_CATEGORY"] {
                   return vodCategories.first(where: { $0.title.localizedCaseInsensitiveContains(needle) })
               }
               return vodCategories.first
           }() {
            let page = try await client.fetchVODPage(categoryID: category.id, page: 1)
            print("  first VOD page '\(category.title)': \(page.items.count) raw, totalPages=\(page.totalPages)")
            print("    movies=\(page.items.filter(\.isMovie).count), series=\(page.items.filter(\.isSeries).count)")
            for item in page.items.prefix(8) {
                print("    - [\(item.kind.rawValue)] \(item.name) poster=\(item.posterURL?.absoluteString ?? "nil")")
            }
            return
        }

        if let firstVOD = vodCategories.first {
            let media = try await client.fetchAllVOD(categoryID: firstVOD.id)
            let movies = media.filter(\.isMovie)
            let series = media.filter(\.isSeries)
            print("  VOD items in '\(firstVOD.title)': \(media.count) (\(movies.count) movies, \(series.count) series)")

            if let movie = movies.first {
                print("  sample movie: \(movie.name)")
                let stream = try await client.resolveStream(for: movie)
                print("  sample movie stream host: \(stream.url.host ?? "nil")")
            }

            if let show = series.first {
                print("  sample series: \(show.name)")
                let seasons = try await client.fetchSeasons(seriesID: show.movieID ?? show.id)
                print("  seasons: \(seasons.count)")
                if let season = seasons.first {
                    let episodes = try await client.fetchEpisodes(
                        seriesID: show.movieID ?? show.id,
                        seasonID: season.id
                    )
                    print("  episodes in '\(season.name)': \(episodes.count)")
                }
            }
        }
    } catch {
        print("  live connection failed: \(error.localizedDescription)")
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            print("  detail: \(description)")
        }
    }
}

// MARK: - Entry point

@main
struct CheckRunner {
    static func main() async {
        if ProcessInfo.processInfo.environment["STALKERDESK_LIVE_DUMP_VOD"] == "1" {
            await runVODFieldDumpIfRequested()
            exit(0)
        }
        if ProcessInfo.processInfo.environment["STALKERDESK_LIVE_CHECK"] == "1" {
            await runLivePortalDiagnosticIfRequested()
            exit(0)
        }

        let checks: [(String, () async throws -> Void)] = [
            ("protocol", testHandshakeProfileGenresChannelsEPGAndCreateLink),
            ("fallback", testEndpointFallbackFindsPortalPHP),
            ("refresh", testTokenRefreshOn401),
            ("vod", testVODCatalogAndSeries)
        ]
        let unitChecks: [(String, () throws -> Void)] = [
            ("mac", testMACAddress),
            ("entrypoints", testPortalURLCandidates),
            ("streams", testStreamCommandParsing),
            ("json", testJSONSanitization),
            ("keychain", testKeychainCredentialStore)
        ]

        var failures = 0
        print("StalkerDeskCore checks")

        for (name, check) in unitChecks {
            do {
                try check()
            } catch {
                failures += 1
                print("  FAIL \(name): \(error)")
            }
        }

        do {
            try await testCoreDataPersistence()
        } catch {
            failures += 1
            print("  FAIL persistence: \(error)")
        }

        for (name, check) in checks {
            do {
                try await check()
            } catch {
                failures += 1
                print("  FAIL \(name): \(error)")
            }
        }

        if failures == 0 {
            print("All checks passed.")
            exit(0)
        } else {
            print("\(failures) check(s) failed.")
            exit(1)
        }
    }
}
