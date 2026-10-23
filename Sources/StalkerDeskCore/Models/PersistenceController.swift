//
//  PersistenceController.swift
//  StalkerDeskCore
//
//  Programmatic Core Data stack (macOS 13 compatible; SwiftData requires
//  macOS 14). The model is defined in code so there is no compiled .momd
//  resource to keep in sync with the domain types.
//

import CoreData
import Foundation

@objc(PortalProfileEntity)
public final class PortalProfileEntity: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var portalURL: String
    @NSManaged public var macAddress: String
    @NSManaged public var deviceID: String
    @NSManaged public var serialNumber: String
    @NSManaged public var timezone: String
    @NSManaged public var username: String?
    @NSManaged public var isDefault: Bool
    @NSManaged public var sortIndex: Int64
    @NSManaged public var createdAt: Date
    @NSManaged public var lastConnectedAt: Date?
}

public final class PersistenceController {
    public let container: NSPersistentContainer

    public init(inMemory: Bool = false) {
        let model = Self.makeModel()
        container = NSPersistentContainer(name: "StalkerDesk", managedObjectModel: model)

        if inMemory {
            let description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [description]
        } else {
            let storeURL = Self.persistentStoreURL()
            let description = NSPersistentStoreDescription(url: storeURL)
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            container.persistentStoreDescriptions = [description]
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.name = "portal-view-context"
    }

    /// Migrates the pre-rename StalkerDesk store to the Arya IPTV Portal
    /// application-support directory so existing portal profiles survive the
    /// rebrand.
    private static func persistentStoreURL() -> URL {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = applicationSupport.appendingPathComponent("AryaIPTVPortal", isDirectory: true)
        let legacyDirectory = applicationSupport.appendingPathComponent("StalkerDesk", isDirectory: true)

        if !fileManager.fileExists(atPath: directory.path),
           fileManager.fileExists(atPath: legacyDirectory.path) {
            try? fileManager.moveItem(at: legacyDirectory, to: directory)
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let storeURL = directory.appendingPathComponent("AryaIPTVPortal.sqlite")
        let legacyStore = directory.appendingPathComponent("StalkerDesk.sqlite")
        if !fileManager.fileExists(atPath: storeURL.path),
           fileManager.fileExists(atPath: legacyStore.path) {
            for suffix in ["", "-wal", "-shm"] {
                let source = directory.appendingPathComponent("StalkerDesk.sqlite\(suffix)")
                let destination = directory.appendingPathComponent("AryaIPTVPortal.sqlite\(suffix)")
                if fileManager.fileExists(atPath: source.path) {
                    try? fileManager.moveItem(at: source, to: destination)
                }
            }
        }

        return storeURL
    }

    public func load() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    @MainActor
    public func fetchProfiles() throws -> [PortalProfile] {
        let request = NSFetchRequest<PortalProfileEntity>(entityName: "PortalProfileEntity")
        request.sortDescriptors = [
            NSSortDescriptor(key: "sortIndex", ascending: true),
            NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
        ]
        let entities = try container.viewContext.fetch(request)
        return entities.map(Self.profile(from:))
    }

    @MainActor
    @discardableResult
    public func upsert(_ profile: PortalProfile) throws -> PortalProfile {
        let context = container.viewContext
        let entity = try fetchEntity(id: profile.id, context: context) ?? PortalProfileEntity(context: context)

        if entity.isInserted {
            entity.id = profile.id
            entity.createdAt = profile.createdAt
            entity.sortIndex = (try maximumSortIndex(context: context)) + 1
        }

        entity.name = profile.name
        entity.portalURL = profile.portalURL
        entity.macAddress = profile.macAddress
        entity.deviceID = profile.deviceID
        entity.serialNumber = profile.serialNumber
        entity.timezone = profile.timezone
        entity.username = profile.username
        entity.isDefault = profile.isDefault
        entity.lastConnectedAt = profile.lastConnectedAt

        if profile.isDefault {
            let request = NSFetchRequest<PortalProfileEntity>(entityName: "PortalProfileEntity")
            request.predicate = NSPredicate(format: "id != %@", profile.id as CVarArg)
            for other in try context.fetch(request) {
                other.isDefault = false
            }
        }

        try context.save()
        return Self.profile(from: entity)
    }

    @MainActor
    public func delete(id: UUID) throws {
        let context = container.viewContext
        guard let entity = try fetchEntity(id: id, context: context) else { return }
        context.delete(entity)
        try context.save()
    }

    @MainActor
    public func updateLastConnected(id: UUID, date: Date = Date()) throws {
        let context = container.viewContext
        guard let entity = try fetchEntity(id: id, context: context) else { return }
        entity.lastConnectedAt = date
        try context.save()
    }

    @MainActor
    public func setDefault(id: UUID) throws {
        let context = container.viewContext
        let request = NSFetchRequest<PortalProfileEntity>(entityName: "PortalProfileEntity")
        for entity in try context.fetch(request) {
            entity.isDefault = entity.id == id
        }
        try context.save()
    }

    // MARK: - Mapping

    private static func profile(from entity: PortalProfileEntity) -> PortalProfile {
        PortalProfile(
            id: entity.id,
            name: entity.name,
            portalURL: entity.portalURL,
            macAddress: entity.macAddress,
            deviceID: entity.deviceID,
            serialNumber: entity.serialNumber,
            timezone: entity.timezone,
            username: entity.username,
            isDefault: entity.isDefault,
            createdAt: entity.createdAt,
            lastConnectedAt: entity.lastConnectedAt
        )
    }

    @MainActor
    private func fetchEntity(id: UUID, context: NSManagedObjectContext) throws -> PortalProfileEntity? {
        let request = NSFetchRequest<PortalProfileEntity>(entityName: "PortalProfileEntity")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try context.fetch(request).first
    }

    @MainActor
    private func maximumSortIndex(context: NSManagedObjectContext) throws -> Int64 {
        let request = NSFetchRequest<NSDictionary>(entityName: "PortalProfileEntity")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["sortIndex"]
        let results = try context.fetch(request)
        return results.compactMap { ($0["sortIndex"] as? NSNumber)?.int64Value }.max() ?? 0
    }

    // MARK: - Model

    private static func makeModel() -> NSManagedObjectModel {
        let entity = NSEntityDescription()
        entity.name = "PortalProfileEntity"
        entity.managedObjectClassName = NSStringFromClass(PortalProfileEntity.self)

        entity.properties = [
            attribute("id", type: .UUIDAttributeType),
            attribute("name", type: .stringAttributeType),
            attribute("portalURL", type: .stringAttributeType),
            attribute("macAddress", type: .stringAttributeType),
            attribute("deviceID", type: .stringAttributeType),
            attribute("serialNumber", type: .stringAttributeType),
            attribute("timezone", type: .stringAttributeType),
            attribute("username", type: .stringAttributeType, optional: true),
            attribute("isDefault", type: .booleanAttributeType, defaultValue: false),
            attribute("sortIndex", type: .integer64AttributeType, defaultValue: Int64(0)),
            attribute("createdAt", type: .dateAttributeType),
            attribute("lastConnectedAt", type: .dateAttributeType, optional: true)
        ]

        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }

    private static func attribute(
        _ name: String,
        type: NSAttributeType,
        optional: Bool = false,
        defaultValue: Any? = nil
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        attribute.defaultValue = defaultValue
        return attribute
    }
}
