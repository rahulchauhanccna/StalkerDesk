//
//  StalkerHTTPTransport.swift
//  StalkerDeskCore
//
//  Thin URLSession abstraction. Keeping transport behind a protocol lets the
//  Stalker actor be exercised with a deterministic mock transport in tests and
//  prevents cookie storage from leaking between portals.
//

import Foundation

public protocol StalkerHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public final class URLSessionStalkerTransport: StalkerHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 25, resourceTimeout: TimeInterval = 60) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = false
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StalkerError.invalidResponse("The server returned a non-HTTP response.")
        }
        return (data, http)
    }

    deinit {
        session.invalidateAndCancel()
    }
}
