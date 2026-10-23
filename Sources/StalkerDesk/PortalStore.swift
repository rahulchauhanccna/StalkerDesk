//
//  PortalStore.swift
//  StalkerDesk
//
//  Main-actor facade over Core Data and the Keychain. Views work with the
//  Sendable PortalProfile domain model, never NSManagedObject.
//

import Combine
import Foundation
import StalkerDeskCore

@MainActor
final class PortalStore: ObservableObject {
    @Published private(set) var profiles: [PortalProfile] = []
    @Published private(set) var isReady = false
    @Published var errorMessage: String?

    private let persistence: PersistenceController
    private var loadTask: Task<Void, Never>?

    init(inMemory: Bool = false) {
        persistence = PersistenceController(inMemory: inMemory)
        loadTask = Task { @MainActor [weak self] in
            await self?.loadPersistentStore()
        }
    }

    func waitUntilReady() async {
        await loadTask?.value
    }

    func reload() async {
        do {
            profiles = try persistence.fetchProfiles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func save(_ draft: PortalDraft) throws -> PortalProfile {
        let validated = try draft.validate()
        var profile = validated.profile

        if let existing = profiles.first(where: { $0.id == profile.id }) {
            profile.createdAt = existing.createdAt
            profile.lastConnectedAt = existing.lastConnectedAt
        }
        if profiles.isEmpty || profile.isDefault {
            profile.isDefault = true
        }

        let saved = try persistence.upsert(profile)
        try PortalCredentialStore.savePassword(validated.credentials.password, portalID: saved.id)
        profiles = try persistence.fetchProfiles()
        return saved
    }

    func delete(_ profile: PortalProfile) {
        do {
            try persistence.delete(id: profile.id)
            try PortalCredentialStore.deletePassword(portalID: profile.id)
            profiles = try persistence.fetchProfiles()
            if let first = profiles.first, !profiles.contains(where: \.isDefault) {
                var promoted = first
                promoted.isDefault = true
                _ = try persistence.upsert(promoted)
                profiles = try persistence.fetchProfiles()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setDefault(_ profile: PortalProfile) {
        do {
            try persistence.setDefault(id: profile.id)
            profiles = try persistence.fetchProfiles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func updateDeviceIdentity(profileID: UUID, deviceID: String, serialNumber: String) -> PortalProfile? {
        guard var profile = profiles.first(where: { $0.id == profileID }) else { return nil }
        profile.deviceID = deviceID
        profile.serialNumber = serialNumber
        do {
            let saved = try persistence.upsert(profile)
            profiles = try persistence.fetchProfiles()
            return saved
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func markConnected(_ profile: PortalProfile) {
        do {
            try persistence.updateLastConnected(id: profile.id)
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index].lastConnectedAt = Date()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func credentials(for profile: PortalProfile) -> PortalCredentials {
        PortalCredentials(
            username: profile.username ?? "",
            password: PortalCredentialStore.password(for: profile.id) ?? ""
        )
    }

    var defaultProfile: PortalProfile? {
        profiles.first(where: \.isDefault) ?? profiles.first
    }

    func clearError() {
        errorMessage = nil
    }

    private func loadPersistentStore() async {
        do {
            try await persistence.load()
            profiles = try persistence.fetchProfiles()
            isReady = true
        } catch {
            errorMessage = "Could not open the portal database: \(error.localizedDescription)"
            isReady = true
        }
    }
}
