//
//  PlaybackProgressStore.swift
//  Arya IPTV Portal
//
//  Persists movie/episode resume positions. VOD progress is stored in
//  UserDefaults as a small JSON dictionary keyed by portal + media id.
//

import Foundation

struct PlaybackProgress: Codable, Sendable, Identifiable {
    let portalID: UUID
    let mediaID: String
    let movieID: String?
    let seasonID: String?
    let episodeID: String?
    let title: String
    let parentTitle: String
    let position: Double
    let duration: Double
    let updatedAt: Date

    var id: String { "\(portalID.uuidString):\(mediaID)" }

    var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    var timeLabel: String {
        let total = Int(position)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

@MainActor
enum PlaybackProgressStore {
    private static let defaultsKey = "AryaIPTVPortal.playbackProgress.v1"
    private static let maximumEntries = 250

    static func entry(portalID: UUID, mediaID: String) -> PlaybackProgress? {
        all["(portalID.uuidString):(mediaID)"]
    }

    static func latest(portalID: UUID, movieID: String) -> PlaybackProgress? {
        all.values
            .filter { $0.portalID == portalID && $0.movieID == movieID }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    static func save(_ progress: PlaybackProgress) {
        var entries = all
        entries[progress.id] = progress

        if entries.count > maximumEntries {
            let keep = entries.values
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(maximumEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.id, $0) })
        }

        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func remove(portalID: UUID, mediaID: String) {
        var entries = all
        entries.removeValue(forKey: "(portalID.uuidString):(mediaID)")
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static var all: [String: PlaybackProgress] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([String: PlaybackProgress].self, from: data) else {
            return [:]
        }
        return entries
    }
}
