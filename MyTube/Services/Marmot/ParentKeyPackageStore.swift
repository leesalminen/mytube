//
//  ParentKeyPackageStore.swift
//  MyTube
//
//  Created by Codex on 03/05/26.
//

import Foundation
import OSLog

/// Persists remote parent key packages so pending invites survive app restarts.
final class ParentKeyPackageStore {
    private struct Entry: Codable {
        let keyPackages: [String]
        let updatedAt: Date
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let queue = DispatchQueue(label: "com.mytube.parentKeyPackageStore", qos: .utility)
    private var entries: [String: Entry]
    private let logger = Logger(subsystem: "com.mytube", category: "ParentKeyPackageStore")

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager

        var encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder

        var decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder

        let existingEntries: [String: Entry]
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode([String: Entry].self, from: data) {
            existingEntries = decoded
        } else {
            existingEntries = [:]
        }
        entries = existingEntries
    }

    func allPackages() -> [String: [String]] {
        queue.sync {
            entries.mapValues(\.keyPackages)
        }
    }

    func packages(forParentKey key: String) -> [String] {
        queue.sync {
            let normalized = normalize(key)
            return entries[normalized]?.keyPackages ?? []
        }
    }

    func save(packages: [String], forParentKey key: String) {
        queue.sync {
            guard !packages.isEmpty else {
                entries.removeValue(forKey: normalize(key))
                persistLocked()
                return
            }
            entries[normalize(key)] = Entry(keyPackages: packages, updatedAt: Date())
            persistLocked()
        }
    }

    func removePackages(forParentKey key: String) {
        queue.sync {
            entries.removeValue(forKey: normalize(key))
            persistLocked()
        }
    }

    func removeAll() {
        queue.sync {
            entries.removeAll()
            persistLocked()
        }
    }

    private func normalize(_ key: String) -> String {
        ParentIdentityKey(string: key)?.hex.lowercased() ?? key.lowercased()
    }

    private func persistLocked() {
        do {
            try ensureDirectory()
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
            #if os(iOS)
            try fileManager.setAttributes(
                [FileAttributeKey.protectionKey: FileProtectionType.complete],
                ofItemAtPath: fileURL.path
            )
            #endif
        } catch {
            logger.error("Failed to persist parent key packages: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureDirectory() throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            return
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
}
