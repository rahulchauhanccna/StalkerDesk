//
//  StalkerClient.swift
//  StalkerDeskCore
//
//  A complete, actor-isolated Stalker/Ministra portal client.
//
//  Responsibilities:
//  - Discover a working load.php endpoint from the various portal URL forms.
//  - Perform the MAG handshake, persist cookies, refresh expired tokens.
//  - Send device-identifying headers for every request.
//  - Fetch genres, paginated channels, EPG and create_link stream URLs.
//
//  All mutable session state is isolated by the actor. The player only receives
//  an immutable ResolvedStream with headers, so refreshing the API token never
//  interrupts current playback.
//

import CryptoKit
import Foundation
import OSLog

// MARK: - Errors

public enum StalkerError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case endpointNotFound(String)
    case portalUnreachable(String)
    case handshakeFailed(String)
    case notAuthenticated
    case sessionExpired
    case unauthorized(String)
    case httpStatus(Int, String)
    case invalidResponse(String)
    case invalidJSON(String)
    case rateLimited
    case createLinkFailed(String)
    case unsupportedStream(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .endpointNotFound(let message):
            return "No Stalker API endpoint was found. \(message)"
        case .portalUnreachable(let message):
            return "The portal could not be reached. \(message)"
        case .handshakeFailed(let message):
            return "The Stalker handshake failed. \(message)"
        case .notAuthenticated:
            return "No active portal session. Connect to a portal first."
        case .sessionExpired:
            return "The portal session expired. Reconnect to the portal."
        case .unauthorized(let message):
            return "The portal rejected this device: \(message)"
        case .httpStatus(let status, let body):
            let suffix = body.isEmpty ? "" : " \(body)"
            return "The portal returned HTTP \(status).\(suffix)"
        case .invalidResponse(let message):
            return "Unexpected portal response. \(message)"
        case .invalidJSON(let message):
            return "The portal returned unreadable data. \(message)"
        case .rateLimited:
            return "The portal is rate limiting requests (HTTP 429). Wait a minute, then try again."
        case .createLinkFailed(let message):
            return "Could not resolve the channel stream. \(message)"
        case .unsupportedStream(let message):
            return "The stream URL is not supported. \(message)"
        case .cancelled:
            return "The request was cancelled."
        }
    }

    var isEndpointFailure: Bool {
        switch self {
        case .endpointNotFound, .invalidResponse, .invalidJSON, .httpStatus, .handshakeFailed:
            return true
        default:
            return false
        }
    }

    var isAuthenticationFailure: Bool {
        switch self {
        case .unauthorized, .sessionExpired, .notAuthenticated:
            return true
        default:
            return false
        }
    }

    var isNetworkFailure: Bool {
        switch self {
        case .portalUnreachable, .rateLimited:
            return true
        default:
            return false
        }
    }
}

// MARK: - Configuration

public struct StalkerClientConfiguration: Sendable {
    public var requestTimeout: TimeInterval
    public var resourceTimeout: TimeInterval
    public var maxRetries: Int
    public var tokenLifetime: TimeInterval
    public var cachedSessionLifetime: TimeInterval
    public var maxChannelPages: Int
    public var maxConcurrentPageRequests: Int
    public var enableSessionCache: Bool
    public var enableLocalhostRewrite: Bool
    public var userAgent: String
    public var xUserAgent: String
    public var acceptLanguage: String

    public init(
        requestTimeout: TimeInterval = 25,
        resourceTimeout: TimeInterval = 60,
        maxRetries: Int = 2,
        tokenLifetime: TimeInterval = 55 * 60,
        cachedSessionLifetime: TimeInterval = 50 * 60,
        maxChannelPages: Int = 60,
        maxConcurrentPageRequests: Int = 3,
        enableSessionCache: Bool = true,
        enableLocalhostRewrite: Bool = true,
        userAgent: String = "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 safari/533.3",
        xUserAgent: String = "Model: MAG250; Link: WiFi",
        acceptLanguage: String = "en-US,en;q=0.5"
    ) {
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.maxRetries = maxRetries
        self.tokenLifetime = tokenLifetime
        self.cachedSessionLifetime = cachedSessionLifetime
        self.maxChannelPages = maxChannelPages
        self.maxConcurrentPageRequests = max(1, maxConcurrentPageRequests)
        self.enableSessionCache = enableSessionCache
        self.enableLocalhostRewrite = enableLocalhostRewrite
        self.userAgent = userAgent
        self.xUserAgent = xUserAgent
        self.acceptLanguage = acceptLanguage
    }
}

// MARK: - Client

public actor StalkerClient {
    public let configuration: StalkerClientConfiguration

    let transport: any StalkerHTTPTransport
    let sessionCache: (any StalkerSessionCaching)?
    let logger = Logger(subsystem: "com.stalkerdesk", category: "StalkerClient")

    var activeProfile: PortalProfile?
    var credentials: PortalCredentials?
    var endpoint: URL?
    var token: String?
    var tokenIssuedAt: Date?
    var cookieJar: [String: String] = [:]
    var account: StalkerUserProfile?
    var refreshInFlight: Task<Void, Error>?
    var isRefreshing = false
    var epgCache: [String: CachedEPG] = [:]

    struct CachedEPG {
        let programs: [String: [StalkerEPGProgram]]
        let fetchedAt: Date
    }

    public init(
        configuration: StalkerClientConfiguration = StalkerClientConfiguration(),
        transport: (any StalkerHTTPTransport)? = nil,
        sessionCache: (any StalkerSessionCaching)? = nil
    ) {
        self.configuration = configuration
        self.transport = transport ?? URLSessionStalkerTransport(
            timeout: configuration.requestTimeout,
            resourceTimeout: configuration.resourceTimeout
        )
        self.sessionCache = sessionCache
    }

    // MARK: Connection lifecycle

    /// Resolves the portal endpoint, performs the handshake and fetches the
    /// profile. Cached tokens are tried first when they are still fresh.
    public func connect(
        profile: PortalProfile,
        credentials: PortalCredentials?,
        force: Bool = false
    ) async throws -> PortalSession {
        if !force, activeProfile?.id == profile.id, let existing = makeSessionIfPossible() {
            return existing
        }

        guard let mac = MACAddress(profile.macAddress) else {
            throw StalkerError.invalidConfiguration("The profile MAC address is invalid.")
        }

        let candidates = PortalURLResolver.candidates(from: profile.portalURL)
        guard !candidates.isEmpty else {
            throw StalkerError.invalidConfiguration("The profile portal URL is invalid.")
        }

        resetState()
        activeProfile = profile
        self.credentials = credentials
        logger.info("Connecting to portal \(profile.name, privacy: .public) as \(mac.formatted, privacy: .public)")

        // 1. Try a cached session. A profile edit invalidates the cache because
        //    the cached endpoint will no longer be in the candidate list.
        if !force,
           configuration.enableSessionCache,
           let cached = sessionCache?.load(portalID: profile.id),
           let cachedEndpoint = URL(string: cached.endpoint),
           candidates.contains(where: { sameEndpoint($0, cachedEndpoint) }),
           Date().timeIntervalSince(cached.issuedAt) < configuration.cachedSessionLifetime {
            endpoint = cachedEndpoint
            token = cached.token
            cookieJar = cached.cookies
            tokenIssuedAt = cached.issuedAt

            do {
                account = try await fetchProfile(allowAuthRetry: false)
                tokenIssuedAt = Date()
                persistSession()
                if let session = makeSessionIfPossible() {
                    logger.info("Restored cached Stalker session")
                    return session
                }
            } catch {
                logger.info("Cached session was rejected; performing a fresh handshake")
                sessionCache?.clear(portalID: profile.id)
                resetAuthState()
            }
        }

        // 2. For a bare host, follow the portal page redirect first. This both
        //    discovers the real portal path (for example /stalker_portal/c/)
        //    and captures any Cloudflare/PHP cookies the API expects, without
        //    brute-forcing several dead endpoints and tripping rate limits.
        var resolvedCandidates = candidates
        if shouldProbeLandingPage(profile: profile) {
            let landed = await landingPageCandidates(profile: profile)
            if !landed.isEmpty {
                resolvedCandidates = deduplicate(landed + resolvedCandidates)
            }
        }

        // 3. Probe candidate endpoints with a handshake. A valid endpoint is the
        //    first one that returns both a token and a profile.
        var authFailure: StalkerError?
        var lastFailure: StalkerError?

        for candidate in resolvedCandidates {
            endpoint = candidate
            resetAuthState()
            logger.debug("Probing Stalker endpoint \(candidate.absoluteString, privacy: .public)")

            do {
                try await performHandshake()
                try await performDoAuthIfNeeded()
                account = try await fetchProfile(allowAuthRetry: false)
                tokenIssuedAt = Date()
                persistSession()

                guard let session = makeSessionIfPossible() else {
                    throw StalkerError.notAuthenticated
                }
                logger.info("Connected to Stalker endpoint \(candidate.absoluteString, privacy: .public)")
                return session
            } catch let error as StalkerError {
                lastFailure = error
                if error.isAuthenticationFailure {
                    authFailure = error
                }
                if error.isNetworkFailure {
                    throw error
                }
                // Wrong endpoint or an endpoint that rejects this MAC: continue
                // probing so a valid sibling endpoint can still be discovered.
                continue
            } catch {
                lastFailure = .portalUnreachable(error.localizedDescription)
                continue
            }
        }

        throw authFailure ?? lastFailure ?? StalkerError.portalUnreachable("No usable endpoint responded.")
    }

    public func disconnect(clearCachedSession: Bool = false) {
        if clearCachedSession, let id = activeProfile?.id {
            sessionCache?.clear(portalID: id)
        }
        resetState()
        logger.info("Disconnected from portal")
    }

    public func currentSession() -> PortalSession? {
        makeSessionIfPossible()
    }

    /// Exposed for diagnostics and tests.
    public func currentEndpoint() -> URL? {
        endpoint
    }

    public func currentToken() -> String? {
        token
    }

    // MARK: Landing page discovery

    private func shouldProbeLandingPage(profile: PortalProfile) -> Bool {
        guard let url = URL(string: profile.portalURL) else { return false }
        let path = url.path.lowercased()
        if path.hasSuffix("/load.php") || path.hasSuffix("/portal.php") {
            return false
        }
        // Only needed for bare hosts or unknown roots. Known /c/ and
        // /stalker_portal/ URLs already produce well-ordered candidates.
        return path.isEmpty || path == "/"
    }

    private func landingPageCandidates(profile: PortalProfile) async -> [URL] {
        guard let startURL = URL(string: profile.portalURL) else { return [] }

        var request = URLRequest(url: startURL)
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.requestTimeout
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(configuration.xUserAgent, forHTTPHeaderField: "X-User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue(configuration.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue(cookieHeader(includeToken: false), forHTTPHeaderField: "Cookie")

        do {
            let (data, response) = try await dataWithRetries(for: request)
            absorbCookies(from: response)
            guard (200...399).contains(response.statusCode),
                  let finalURL = response.url else { return [] }

            var discovered = PortalURLResolver.candidates(from: finalURL.absoluteString)
            if let hinted = portalEndpointHint(in: data, finalURL: finalURL) {
                discovered.insert(hinted, at: 0)
            }
            logger.debug("Portal landing page resolved to \(finalURL.absoluteString, privacy: .public)")
            return discovered
        } catch {
            logger.debug("Portal landing page probe failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func portalEndpointHint(in data: Data, finalURL: URL) -> URL? {
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        // Stalker pages commonly reference ../server/api/load_js.php. Derive
        // the sibling server/load.php URL from the final portal path.
        guard html.range(of: "server/api/load_js.php", options: .caseInsensitive) != nil,
              var components = URLComponents(url: finalURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var path = components.path
        if let range = path.range(of: "/c/", options: .backwards) {
            path = String(path[..<range.lowerBound])
        } else if path.hasSuffix("/c") {
            path.removeLast(2)
        } else {
            path = ""
        }
        components.path = path + "/server/load.php"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func deduplicate(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    // MARK: Authentication

    private func performHandshake() async throws {
        let first = try await handshakeAttempt(token: "", prehash: nil)
        if let extracted = Self.extractToken(from: first.json) {
            applyToken(extracted)
            return
        }

        if first.status == 429 {
            throw StalkerError.rateLimited
        }
        if first.status == 404 {
            throw StalkerError.endpointNotFound("The handshake returned HTTP 404.")
        }
        if first.status == 401 || first.status == 403 {
            throw StalkerError.unauthorized("The portal rejected this MAC address or device identity.")
        }

        // Some Ministra builds answer the first handshake with a challenge.
        let challengeToken = Self.randomToken()
        let prehash = Self.sha1Hex(challengeToken)
        let second = try await handshakeAttempt(token: challengeToken, prehash: prehash)
        if let extracted = Self.extractToken(from: second.json) {
            applyToken(extracted)
            return
        }

        if second.status == 429 {
            throw StalkerError.rateLimited
        }
        if second.status == 401 || second.status == 403 {
            throw StalkerError.unauthorized("The portal rejected this MAC address or device identity.")
        }
        if second.status == 404 {
            throw StalkerError.endpointNotFound("The handshake returned HTTP 404.")
        }

        let message = Self.serverMessage(from: second.json, fallback: second.bodyPrefix)
        throw StalkerError.handshakeFailed(message.isEmpty ? "No token was returned." : message)
    }

    private func handshakeAttempt(token challengeToken: String, prehash: String?) async throws -> RawPortalResponse {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "type", value: "stb"),
            URLQueryItem(name: "action", value: "handshake"),
            URLQueryItem(name: "token", value: challengeToken)
        ]
        if let prehash {
            items.append(URLQueryItem(name: "prehash", value: prehash))
        }

        let result = try await performRequest(queryItems: items, authenticated: false)
        absorbCookies(from: result.response)
        return RawPortalResponse(
            status: result.response.statusCode,
            json: (try? StalkerJSONParser.parse(result.data)) ?? .null,
            bodyPrefix: Self.bodyPreview(result.data)
        )
    }

    private func applyToken(_ value: String) {
        token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        tokenIssuedAt = Date()
    }

    private func performDoAuthIfNeeded() async throws {
        guard let credentials, !credentials.isEmpty,
              let identity = activeProfile?.identity else { return }

        let items: [URLQueryItem] = [
            URLQueryItem(name: "type", value: "stb"),
            URLQueryItem(name: "action", value: "do_auth"),
            URLQueryItem(name: "login", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password),
            URLQueryItem(name: "device_id", value: identity.deviceID),
            URLQueryItem(name: "device_id2", value: identity.deviceID2)
        ]
        let json = try await requestJSON(items: items, authenticated: true, allowAuthRetry: false)
        if let js = json["js"], js.boolValue == false {
            throw StalkerError.unauthorized("The portal rejected the account username and password.")
        }
    }

    private func fetchProfile(allowAuthRetry: Bool) async throws -> StalkerUserProfile {
        guard let profile = activeProfile, let identity = profile.identity else {
            throw StalkerError.invalidConfiguration("The portal profile is missing a valid MAC address.")
        }

        let timestamp = String(Int(Date().timeIntervalSince1970))
        let version = "ImageDescription: 0.2.18-r23-250; ImageDate: Thu Sep 13 11:31:16 EEST 2018; PORTAL version: 5.6.2; API Version: JS API version: 343; STB API version: 146; Player Engine version: 0x58c"

        let items: [URLQueryItem] = [
            URLQueryItem(name: "type", value: "stb"),
            URLQueryItem(name: "action", value: "get_profile"),
            URLQueryItem(name: "hd", value: "1"),
            URLQueryItem(name: "num_banks", value: "2"),
            URLQueryItem(name: "stb_type", value: "MAG250"),
            URLQueryItem(name: "client_type", value: "STB"),
            URLQueryItem(name: "image_version", value: "218"),
            URLQueryItem(name: "video_out", value: "hdmi"),
            URLQueryItem(name: "auth_second_step", value: "1"),
            URLQueryItem(name: "hw_version", value: "1.7-BD-00"),
            URLQueryItem(name: "not_valid_token", value: "0"),
            URLQueryItem(name: "api_signature", value: "262"),
            URLQueryItem(name: "prehash", value: ""),
            URLQueryItem(name: "sn", value: identity.serialNumber),
            URLQueryItem(name: "device_id", value: identity.deviceID),
            URLQueryItem(name: "device_id2", value: identity.deviceID2),
            URLQueryItem(name: "signature", value: identity.signature),
            URLQueryItem(name: "metrics", value: identity.metricsJSON),
            URLQueryItem(name: "hw_version_2", value: identity.hwVersion2),
            URLQueryItem(name: "timestamp", value: timestamp),
            URLQueryItem(name: "ver", value: version)
        ]

        let json = try await requestJSON(items: items, authenticated: true, allowAuthRetry: allowAuthRetry)
        let js = try Self.jsPayload(json)

        guard let object = js.objectValue else {
            throw StalkerError.invalidResponse("get_profile did not return an object.")
        }

        if let newToken = object.firstString("token"), !newToken.isEmpty {
            token = newToken
            tokenIssuedAt = Date()
        }

        let user = StalkerPayloadParser.userProfile(from: object)
        // Some portals answer an unauthorized device with HTTP 200 and an
        // empty js object. Treating that as a valid profile leaves the UI
        // "Connected" while every subsequent call fails with Authorization
        // failed. Require at least one identity field from get_profile.
        let hasIdentity = user.id != nil
            || user.name != nil
            || user.login != nil
            || object.firstString("mac") != nil
        guard hasIdentity else {
            throw StalkerError.unauthorized(
                "The portal returned an empty profile. The saved device ID/serial may not match this MAC address."
            )
        }

        return user
    }

    // MARK: Token refresh

    /// Refreshes if the local token lifetime has elapsed. Called before every
    /// authenticated request.
    func ensureTokenValid() async throws {
        guard token != nil, tokenIssuedAt != nil else {
            throw StalkerError.notAuthenticated
        }
        guard let issuedAt = tokenIssuedAt,
              Date().timeIntervalSince(issuedAt) >= configuration.tokenLifetime else {
            return
        }
        try await refreshSession()
    }

    /// Single-flight token refresh. The actor can be re-entered while waiting on
    /// the network, so concurrent callers all await the same Task.
    private func refreshSession() async throws {
        guard !isRefreshing else {
            throw StalkerError.sessionExpired
        }
        if let inFlight = refreshInFlight {
            try await inFlight.value
            return
        }

        let task = Task { try await self.performRefresh() }
        refreshInFlight = task
        do {
            try await task.value
            refreshInFlight = nil
        } catch {
            refreshInFlight = nil
            if let portalID = activeProfile?.id {
                sessionCache?.clear(portalID: portalID)
            }
            throw error
        }
    }

    private func performRefresh() async throws {
        isRefreshing = true
        defer { isRefreshing = false }

        guard endpoint != nil, activeProfile != nil else {
            throw StalkerError.notAuthenticated
        }

        logger.info("Refreshing Stalker token")
        resetAuthState()
        try await performHandshake()
        try await performDoAuthIfNeeded()
        account = try await fetchProfile(allowAuthRetry: false)
        tokenIssuedAt = Date()
        persistSession()
    }

    // MARK: HTTP

    struct RawPortalResponse {
        let status: Int
        let json: JSONValue
        let bodyPrefix: String
    }

    func requestJSON(
        items: [URLQueryItem],
        authenticated: Bool,
        allowAuthRetry: Bool = true
    ) async throws -> JSONValue {
        if authenticated {
            try await ensureTokenValid()
        }

        let (data, response) = try await performRequest(queryItems: items, authenticated: authenticated)
        absorbCookies(from: response)
        let status = response.statusCode

        if status == 401 || status == 403 {
            if authenticated, allowAuthRetry, !isRefreshing {
                try await refreshSession()
                return try await requestJSON(items: items, authenticated: authenticated, allowAuthRetry: false)
            }
            throw StalkerError.sessionExpired
        }

        if status == 429 {
            throw StalkerError.rateLimited
        }

        if status == 404 {
            throw StalkerError.endpointNotFound("The API endpoint returned HTTP 404.")
        }

        if status >= 400 {
            throw StalkerError.httpStatus(status, Self.bodyPreview(data))
        }

        let json: JSONValue
        do {
            json = try StalkerJSONParser.parse(data)
        } catch let error as StalkerError {
            if case .invalidJSON = error {
                let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "unknown content type"
                let snippet = Self.bodyPreview(data).prefix(140)
                throw StalkerError.invalidJSON("HTTP \(status) [\(contentType)]: \(snippet)")
            }
            throw error
        } catch {
            throw StalkerError.invalidJSON(error.localizedDescription)
        }

        if authenticated, allowAuthRetry, !isRefreshing, Self.isAuthorizationError(json) {
            try await refreshSession()
            return try await requestJSON(items: items, authenticated: authenticated, allowAuthRetry: false)
        }

        return json
    }

    private func performRequest(
        queryItems: [URLQueryItem],
        authenticated: Bool
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        guard let endpoint else {
            throw StalkerError.notAuthenticated
        }

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw StalkerError.invalidConfiguration("The resolved endpoint URL is invalid.")
        }

        var allItems = components.queryItems ?? []
        allItems.append(contentsOf: queryItems)
        allItems.append(URLQueryItem(name: "JsHttpRequest", value: "1-xml"))
        components.queryItems = allItems

        guard let url = components.url else {
            throw StalkerError.invalidConfiguration("Could not build a portal request URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = configuration.requestTimeout
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(configuration.xUserAgent, forHTTPHeaderField: "X-User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(configuration.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue(cookieHeader(includeToken: authenticated), forHTTPHeaderField: "Cookie")

        if let referer = PortalURLResolver.referer(for: endpoint) {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }

        if authenticated, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return try await dataWithRetries(for: request)
    }

    private func dataWithRetries(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?

        for attempt in 0...max(0, configuration.maxRetries) {
            try Task.checkCancellation()
            do {
                let (data, response) = try await transport.send(request)
                if response.statusCode >= 500, attempt < configuration.maxRetries {
                    lastError = StalkerError.httpStatus(response.statusCode, "")
                    try await sleepBeforeRetry(attempt: attempt)
                    continue
                }
                return (data, response)
            } catch is CancellationError {
                throw StalkerError.cancelled
            } catch let error as URLError {
                if error.code == .cancelled {
                    throw StalkerError.cancelled
                }
                lastError = StalkerError.portalUnreachable(error.localizedDescription)
                let retryable: Set<URLError.Code> = [
                    .timedOut, .cannotFindHost, .cannotConnectToHost,
                    .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet
                ]
                guard retryable.contains(error.code), attempt < configuration.maxRetries else {
                    throw lastError ?? StalkerError.portalUnreachable(error.localizedDescription)
                }
                try await sleepBeforeRetry(attempt: attempt)
            } catch {
                throw StalkerError.portalUnreachable(error.localizedDescription)
            }
        }

        throw lastError ?? StalkerError.portalUnreachable("The request did not complete.")
    }

    private func sleepBeforeRetry(attempt: Int) async throws {
        let nanoseconds = UInt64(250_000_000 * (attempt + 1))
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            throw StalkerError.cancelled
        }
    }

    private func absorbCookies(from response: HTTPURLResponse) {
        guard let url = response.url else { return }
        var fields: [String: String] = [:]
        for (rawKey, rawValue) in response.allHeaderFields {
            if let key = rawKey as? String, let value = rawValue as? String {
                fields[key] = value
            }
        }
        guard !fields.isEmpty else { return }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            cookieJar[cookie.name] = cookie.value
        }
    }

    private func cookieHeader(includeToken: Bool) -> String {
        var values: [String: String] = [:]
        if let mac = activeProfile?.mac {
            values["mac"] = mac.cookieValue
        }
        values["stb_lang"] = "en"
        if let timezone = activeProfile?.timezone, !timezone.isEmpty {
            values["timezone"] = Self.percentEncodeCookie(timezone)
        }
        for (name, value) in cookieJar {
            values[name] = value
        }
        if includeToken, let token, !token.isEmpty {
            values["token"] = token
        }
        return values
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    // MARK: Stream headers

    func streamHeaders(for url: URL) -> [String: String] {
        var headers: [String: String] = [
            "User-Agent": configuration.userAgent,
            "X-User-Agent": configuration.xUserAgent,
            "Accept": "*/*",
            "Accept-Language": configuration.acceptLanguage,
            "Connection": "keep-alive"
        ]

        if let referer = PortalURLResolver.referer(for: endpoint ?? url) {
            headers["Referer"] = referer.absoluteString
        }
        if let origin = PortalURLResolver.origin(for: endpoint ?? url) {
            headers["Origin"] = origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        headers["Cookie"] = cookieHeader(includeToken: true)
        if let token {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }

    // MARK: Session helpers

    private func makeSessionIfPossible() -> PortalSession? {
        guard let activeProfile,
              let endpoint,
              let token,
              let account else { return nil }

        return PortalSession(
            portalID: activeProfile.id,
            endpoint: endpoint,
            token: token,
            cookies: cookieJar,
            userProfile: account,
            issuedAt: tokenIssuedAt ?? Date()
        )
    }

    private func persistSession() {
        guard configuration.enableSessionCache,
              let sessionCache,
              let profile = activeProfile,
              let endpoint,
              let token else { return }
        let cached = CachedStalkerSession(
            endpoint: endpoint.absoluteString,
            token: token,
            cookies: cookieJar,
            issuedAt: tokenIssuedAt ?? Date()
        )
        sessionCache.save(cached, portalID: profile.id)
    }

    private func resetState() {
        activeProfile = nil
        credentials = nil
        endpoint = nil
        token = nil
        tokenIssuedAt = nil
        cookieJar.removeAll()
        account = nil
        epgCache.removeAll()
        refreshInFlight?.cancel()
        refreshInFlight = nil
        isRefreshing = false
    }

    private func resetAuthState() {
        token = nil
        tokenIssuedAt = nil
        account = nil
        cookieJar.removeAll()
    }

    private func sameEndpoint(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            == rhs.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: Static helpers

    static func jsPayload(_ json: JSONValue) throws -> JSONValue {
        guard let js = json["js"] else {
            if let error = json.firstString("error") {
                throw StalkerError.invalidResponse(error)
            }
            throw StalkerError.invalidResponse("The response did not contain a js payload.")
        }
        if let bool = js.boolValue, js.objectValue == nil, js.arrayValue == nil, bool == false {
            throw StalkerError.unauthorized(json.firstString("error") ?? "The portal rejected the request.")
        }
        return js
    }

    static func extractToken(from json: JSONValue) -> String? {
        if let token = json["js"]?.objectValue?["token"]?.stringValue,
           !token.isEmpty {
            return token
        }
        if let token = json["token"]?.stringValue, !token.isEmpty {
            return token
        }
        if let token = json["js"]?.stringValue,
           token.count >= 16,
           token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            return token
        }
        return nil
    }

    static func isAuthorizationError(_ json: JSONValue) -> Bool {
        guard let error = json.firstString("error")?.lowercased() else { return false }
        return error.contains("authorization")
            || error.contains("authorisation")
            || error.contains("token")
            || error.contains("session")
            || error.contains("access denied")
            || error.contains("not authorized")
    }

    static func serverMessage(from json: JSONValue, fallback: String) -> String {
        if let error = json.firstString("error"), !error.isEmpty {
            return error
        }
        if let message = json["js"]?["error"]?.stringValue, !message.isEmpty {
            return message
        }
        return fallback
    }

    static func bodyPreview(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(180))
    }

    static func percentEncodeCookie(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func randomToken() -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<32).map { _ in characters[Int.random(in: 0..<characters.count, using: &generator)] })
    }

    static func sha1Hex(_ value: String) -> String {
        Insecure.SHA1.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
