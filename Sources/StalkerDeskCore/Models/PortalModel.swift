//
//  PortalModel.swift
//  StalkerDeskCore
//
//  Domain models and validation for Stalker/Ministra portal profiles.
//
//  Persistence is Core Data (see PersistenceController.swift); credentials and
//  the resumable portal session are stored in the macOS Keychain. Keeping the
//  domain model free of NSManagedObject makes it safe to pass to the networking
//  actor and to previews/tests.
//

import CryptoKit
import Foundation

// MARK: - MAC address

/// A validated six-octet MAC address.
///
/// Stalker portals identify a "device" by MAC address. MAG devices normally use
/// the 00:1A:79 OUI, but other OUIs are seen in the wild, so this type only
/// enforces the structural rules and exposes isMAGVirtual as a warning.
public struct MACAddress: Hashable, Sendable, CustomStringConvertible {
    public static let magOUI = "00:1A:79"

    public let octets: [UInt8]

    public init?(_ raw: String) {
        let stripped = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "0x", with: "", options: [.caseInsensitive])
            .filter { $0.isHexDigit }

        guard stripped.count == 12 else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(6)
        var index = stripped.startIndex
        for _ in 0..<6 {
            let end = stripped.index(index, offsetBy: 2)
            guard let byte = UInt8(stripped[index..<end], radix: 16) else { return nil }
            bytes.append(byte)
            index = end
        }

        // A broadcast/multicast MAC is never a valid STB identity.
        guard bytes != [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
              bytes[0] & 0x01 == 0 else { return nil }

        self.octets = bytes
    }

    public var formatted: String {
        octets.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    public var compact: String {
        octets.map { String(format: "%02X", $0) }.joined()
    }

    /// Percent-encoded representation used in the Stalker mac= cookie.
    public var cookieValue: String {
        formatted.replacingOccurrences(of: ":", with: "%3A")
    }

    public var isMAGVirtual: Bool {
        formatted.hasPrefix(Self.magOUI)
    }

    public var description: String { formatted }

    public static func isValid(_ raw: String) -> Bool {
        MACAddress(raw) != nil
    }

    /// Turns arbitrary user input into canonical AA:BB:CC:DD:EE:FF text.
    public static func format(_ raw: String) -> String {
        guard let address = MACAddress(raw) else { return raw.uppercased() }
        return address.formatted
    }

    /// Formats while the user types: strips non-hex characters, uppercases and
    /// inserts a colon every two hex digits. Partial input is allowed.
    public static func formatInput(_ raw: String) -> String {
        let hex = raw
            .uppercased()
            .filter { $0.isHexDigit }
            .prefix(12)
        var groups: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            groups.append(String(hex[index..<end]))
            index = end
        }
        return groups.joined(separator: ":")
    }

    /// A random MAC in the MAG OUI range. Portals still need to provision it --
    /// this only helps avoid duplicate placeholder values when creating a profile.
    public static func randomMAGAddress() -> MACAddress {
        var generator = SystemRandomNumberGenerator()
        let bytes: [UInt8] = [0x00, 0x1A, 0x79,
                              UInt8.random(in: 0...255, using: &generator),
                              UInt8.random(in: 0...255, using: &generator),
                              UInt8.random(in: 0...255, using: &generator)]
        return MACAddress(bytes.map { String(format: "%02X", $0) }.joined(separator: ":"))!
    }
}

// MARK: - Device identity

/// MAG-style device identity. Values are deterministic from the MAC unless the
/// user overrides the device ID / serial, which some portals bind to an account.
public struct DeviceIdentity: Hashable, Sendable {
    public let mac: MACAddress
    public let serialNumber: String
    public let deviceID: String
    public let deviceID2: String
    public let signature: String
    public let hwVersion2: String
    public let random: String

    public init(mac: MACAddress, serialNumber: String? = nil, deviceID: String? = nil) {
        self.mac = mac

        let resolvedSerial = Self.sanitized(serialNumber, fallback: Self.defaultSerial(for: mac))
        let resolvedDeviceID = Self.sanitized(deviceID, fallback: Self.defaultDeviceID(for: mac))
        self.serialNumber = resolvedSerial
        self.deviceID = resolvedDeviceID
        self.deviceID2 = resolvedDeviceID

        let signatureInput = mac.formatted + resolvedSerial + resolvedDeviceID + resolvedDeviceID
        self.signature = Self.hexDigest(SHA256.hash(data: Data(signatureInput.utf8)))
        self.hwVersion2 = Self.hexDigest(Insecure.SHA1.hash(data: Data(mac.formatted.utf8)))
        self.random = Self.randomHex(byteCount: 20)
    }

    public static func defaultSerial(for mac: MACAddress) -> String {
        String(hexDigest(Insecure.MD5.hash(data: Data(mac.formatted.utf8))).prefix(13))
    }

    public static func defaultDeviceID(for mac: MACAddress) -> String {
        hexDigest(SHA256.hash(data: Data(mac.formatted.utf8)))
    }

    public static func isValidDeviceID(_ value: String) -> Bool {
        guard (16...128).contains(value.count) else { return false }
        return value.allSatisfy { $0.isHexDigit || $0.isLetter || $0.isNumber }
    }

    public static func isValidSerial(_ value: String) -> Bool {
        guard (6...64).contains(value.count) else { return false }
        return value.allSatisfy { !$0.isWhitespace }
    }

    /// JSON blob sent as the metrics query parameter on get_profile.
    public var metricsJSON: String {
        let payload: [String: String] = [
            "mac": mac.formatted,
            "sn": serialNumber,
            "type": "STB",
            "model": "MAG250",
            "uid": "",
            "random": random
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func sanitized(_ value: String?, fallback: String) -> String {
        guard let value else { return fallback }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func hexDigest<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    private static func randomHex(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<byteCount)
            .map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }
            .joined()
    }
}

// MARK: - Credentials

/// Optional login credentials. Most MAC-provisioned portals do not use these;
/// they are stored in the Keychain and only sent when explicitly configured.
public struct PortalCredentials: Hashable, Sendable {
    public var username: String
    public var password: String

    public init(username: String = "", password: String = "") {
        self.username = username
        self.password = password
    }

    public var isEmpty: Bool {
        username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Portal profile

public struct PortalProfile: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var portalURL: String
    public var macAddress: String
    public var deviceID: String
    public var serialNumber: String
    public var timezone: String
    public var username: String?
    public var isDefault: Bool
    public var createdAt: Date
    public var lastConnectedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        portalURL: String,
        macAddress: String,
        deviceID: String = "",
        serialNumber: String = "",
        timezone: String = TimeZone.current.identifier,
        username: String? = nil,
        isDefault: Bool = false,
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.portalURL = portalURL
        self.macAddress = macAddress
        self.deviceID = deviceID
        self.serialNumber = serialNumber
        self.timezone = timezone
        self.username = username
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    public var mac: MACAddress? { MACAddress(macAddress) }

    public var identity: DeviceIdentity? {
        guard let mac else { return nil }
        return DeviceIdentity(mac: mac, serialNumber: serialNumber, deviceID: deviceID)
    }

    public var normalizedMAC: String {
        mac?.formatted ?? macAddress
    }

    public var hasUsername: Bool {
        !(username ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Draft / validation

public enum PortalValidationError: LocalizedError, Equatable {
    case missingName
    case invalidPortalURL
    case invalidMAC
    case invalidDeviceID
    case invalidSerialNumber
    case invalidTimezone

    public var errorDescription: String? {
        switch self {
        case .missingName:
            return "Give the portal a name."
        case .invalidPortalURL:
            return "Enter a valid HTTP or HTTPS portal URL."
        case .invalidMAC:
            return "The MAC address must contain exactly six octets (for example 00:1A:79:12:34:56)."
        case .invalidDeviceID:
            return "Device ID must be 16-128 alphanumeric or hexadecimal characters."
        case .invalidSerialNumber:
            return "Serial number must be 6-64 characters and contain no spaces."
        case .invalidTimezone:
            return "Choose a valid IANA timezone (for example Europe/London)."
        }
    }
}

/// Editable form state. Converted into a persisted PortalProfile only after
/// validation succeeds.
public struct PortalDraft: Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var portalURL: String
    public var macAddress: String
    public var deviceID: String
    public var serialNumber: String
    public var timezone: String
    public var username: String
    public var password: String
    public var isDefault: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        portalURL: String = "",
        macAddress: String = "",
        deviceID: String = "",
        serialNumber: String = "",
        timezone: String = TimeZone.current.identifier,
        username: String = "",
        password: String = "",
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.portalURL = portalURL
        self.macAddress = macAddress
        self.deviceID = deviceID
        self.serialNumber = serialNumber
        self.timezone = timezone
        self.username = username
        self.password = password
        self.isDefault = isDefault
    }

    public init(profile: PortalProfile, password: String = "") {
        self.init(
            id: profile.id,
            name: profile.name,
            portalURL: profile.portalURL,
            macAddress: profile.macAddress,
            deviceID: profile.deviceID,
            serialNumber: profile.serialNumber,
            timezone: profile.timezone,
            username: profile.username ?? "",
            password: password,
            isDefault: profile.isDefault
        )
    }

    public static func newProfile() -> PortalDraft {
        let mac = MACAddress.randomMAGAddress()
        return PortalDraft(
            name: "",
            portalURL: "",
            macAddress: mac.formatted,
            deviceID: DeviceIdentity.defaultDeviceID(for: mac),
            serialNumber: DeviceIdentity.defaultSerial(for: mac)
        )
    }

    public mutating func regenerateIdentity() {
        guard let mac = MACAddress(macAddress) else { return }
        deviceID = DeviceIdentity.defaultDeviceID(for: mac)
        serialNumber = DeviceIdentity.defaultSerial(for: mac)
    }

    public mutating func normalize() {
        macAddress = MACAddress.formatInput(macAddress)
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        portalURL = portalURL.trimmingCharacters(in: .whitespacesAndNewlines)
        deviceID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        serialNumber = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        username = username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func validate() throws -> ValidatedPortal {
        var copy = self
        copy.normalize()

        guard !copy.name.isEmpty else { throw PortalValidationError.missingName }
        guard let mac = MACAddress(copy.macAddress) else { throw PortalValidationError.invalidMAC }
        guard !PortalURLResolver.candidates(from: copy.portalURL).isEmpty else {
            throw PortalValidationError.invalidPortalURL
        }
        guard TimeZone(identifier: copy.timezone) != nil else {
            throw PortalValidationError.invalidTimezone
        }
        if !copy.deviceID.isEmpty, !DeviceIdentity.isValidDeviceID(copy.deviceID) {
            throw PortalValidationError.invalidDeviceID
        }
        if !copy.serialNumber.isEmpty, !DeviceIdentity.isValidSerial(copy.serialNumber) {
            throw PortalValidationError.invalidSerialNumber
        }

        let identity = DeviceIdentity(
            mac: mac,
            serialNumber: copy.serialNumber.isEmpty ? nil : copy.serialNumber,
            deviceID: copy.deviceID.isEmpty ? nil : copy.deviceID
        )

        let profile = PortalProfile(
            id: copy.id,
            name: copy.name,
            portalURL: PortalURLResolver.normalizedPortalURL(copy.portalURL) ?? copy.portalURL,
            macAddress: mac.formatted,
            deviceID: identity.deviceID,
            serialNumber: identity.serialNumber,
            timezone: copy.timezone,
            username: copy.username.isEmpty ? nil : copy.username,
            isDefault: copy.isDefault
        )

        return ValidatedPortal(
            profile: profile,
            credentials: PortalCredentials(username: copy.username, password: copy.password)
        )
    }
}

public struct ValidatedPortal: Sendable {
    public let profile: PortalProfile
    public let credentials: PortalCredentials

    public init(profile: PortalProfile, credentials: PortalCredentials) {
        self.profile = profile
        self.credentials = credentials
    }
}

// MARK: - Portal URL resolution

/// Resolves the many portal URL conventions used by Stalker installations to a
/// list of candidate load.php / portal.php endpoints.
///
/// Examples handled:
/// - http://host/stalker_portal/server/load.php (explicit)
/// - http://host/c/ -> /server/load.php, /stalker_portal/server/load.php, /c/portal.php
/// - http://host/stalker_portal/ -> /stalker_portal/server/load.php
/// - http://host -> conventional paths under the host
public enum PortalURLResolver {
    private static let explicitFileNames = ["load.php", "portal.php"]

    public static func normalizedPortalURL(_ raw: String) -> String? {
        guard let url = normalizedURL(from: raw) else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.query = nil
        components.fragment = nil
        if !components.path.hasSuffix("/"), !isExplicitEndpoint(components.path) {
            components.path += "/"
        }
        return components.url?.absoluteString
    }

    public static func candidates(from raw: String) -> [URL] {
        guard let input = normalizedURL(from: raw),
              let components = URLComponents(url: input, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty else {
            return []
        }

        // Explicit API endpoint: use it as-is.
        if isExplicitEndpoint(components.path) {
            var cleaned = components
            cleaned.query = nil
            cleaned.fragment = nil
            return cleaned.url.map { [$0] } ?? []
        }

        let rootComponents = baseComponents(from: components)
        let path = components.path
        let directoryPath = path.hasSuffix("/") ? path : path + "/"

        var rawCandidates: [String] = []

        if let range = path.range(of: "/c", options: [.backwards]) {
            let rootPrefix = String(path[..<range.lowerBound])
            let root = originString(components: components, path: rootPrefix)
            add("\(root)/server/load.php", to: &rawCandidates)
            add("\(root)/stalker_portal/server/load.php", to: &rawCandidates)
            add("\(originString(components: components, path: directoryPath))portal.php", to: &rawCandidates)
            add("\(originString(components: components, path: directoryPath))server/load.php", to: &rawCandidates)
            add("\(root)/portal.php", to: &rawCandidates)
        } else if path.contains("/stalker_portal") {
            add("\(originString(components: components, path: directoryPath))server/load.php", to: &rawCandidates)
            add("\(originString(components: components, path: rootComponents.path))server/load.php", to: &rawCandidates)
            add("\(originString(components: components, path: directoryPath))portal.php", to: &rawCandidates)
        } else {
            add("\(originString(components: components, path: directoryPath))server/load.php", to: &rawCandidates)
            add("\(originString(components: components, path: rootComponents.path))server/load.php", to: &rawCandidates)
            add("\(originString(components: components, path: rootComponents.path))stalker_portal/server/load.php", to: &rawCandidates)
            add("\(originString(components: components, path: directoryPath))portal.php", to: &rawCandidates)
            add("\(originString(components: components, path: rootComponents.path))portal.php", to: &rawCandidates)
            add("\(originString(components: components, path: rootComponents.path))c/portal.php", to: &rawCandidates)
        }

        var seen = Set<String>()
        return rawCandidates.compactMap { string -> URL? in
            guard seen.insert(string).inserted,
                  let url = URL(string: string),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil else { return nil }
            return url
        }
    }

    /// Best-effort referer used for API requests and stream playback.
    public static func referer(for endpoint: URL) -> URL? {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.path

        if path.hasSuffix("/server/load.php") {
            components.path = String(path.dropLast("/server/load.php".count)) + "/c/"
        } else if path.hasSuffix("/portal.php") {
            components.path = String(path.dropLast("portal.php".count))
        } else {
            components.path = "/c/"
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    public static func origin(for endpoint: URL) -> URL? {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    // MARK: Helpers

    private static func normalizedURL(from raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") {
            value = "http://" + value
        }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return nil
        }
        components.scheme = scheme
        return components.url
    }

    private static func baseComponents(from components: URLComponents) -> URLComponents {
        var copy = components
        // Keep the root slash. Callers append "server/load.php" without a
        // leading slash, so an empty path would produce "hostserver/...".
        copy.path = "/"
        return copy
    }

    private static func isExplicitEndpoint(_ path: String) -> Bool {
        let lower = path.lowercased()
        return explicitFileNames.contains { lower.hasSuffix("/" + $0) }
    }

    private static func originString(components: URLComponents, path: String) -> String {
        var copy = components
        copy.path = path
        copy.query = nil
        copy.fragment = nil
        return copy.string ?? ""
    }

    private static func add(_ candidate: String, to list: inout [String]) {
        // URLComponents.string already produces clean schemes; only guard
        // against accidental duplicates.
        if !list.contains(candidate) {
            list.append(candidate)
        }
    }
}
