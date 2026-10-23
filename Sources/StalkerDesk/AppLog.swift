//
//  AppLog.swift
//  StalkerDesk
//
//  Lightweight local diagnostics. Contains lifecycle counts and errors only;
//  never writes tokens, cookies, passwords, or stream query strings.
//

import Foundation

enum AppLog {
    private static let lock = NSLock()
    private static let maximumBytes: UInt64 = 512 * 1024

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("Logs/AryaIPTVPortal", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("AryaIPTVPortal.log")
    }

    static func info(_ message: String) {
        append(level: "INFO", message: message)
    }

    static func warning(_ message: String) {
        append(level: "WARN", message: message)
    }

    static func error(_ message: String) {
        append(level: "ERROR", message: message)
    }

    private static func append(level: String, message: String) {
        lock.lock()
        defer { lock.unlock() }

        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = fileURL

        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? UInt64, size > maximumBytes {
            try? FileManager.default.removeItem(at: url)
        }

        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
