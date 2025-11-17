//
//  StoragePaths.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import Foundation

/// Centralized helper for resolving sandboxed file system paths used across the app.
/// Ensures directories exist beneath Application Support and are protected with `.completeFileProtection`.
final class StoragePaths {
    enum Directory: String, CaseIterable {
        case media = "Media"
        case thumbs = "Thumbs"
        case edits = "Edits"
    }

    private let fileManager: FileManager
    private let baseURL: URL

    var rootURL: URL { baseURL }

    init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager

        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        baseURL = appSupport.appendingPathComponent("MyTube", isDirectory: true)

        try ensureBaseDirectories()
    }

    init(baseURL: URL, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        self.baseURL = baseURL
        try ensureBaseDirectories()
    }

    func url(
        for directory: Directory,
        profileId: UUID? = nil,
        fileName: String? = nil
    ) -> URL {
        var url = baseURL.appendingPathComponent(directory.rawValue, isDirectory: true)
        if let profileId {
            url = url.appendingPathComponent(profileId.uuidString, isDirectory: true)
        }
        if let fileName {
            url = url.appendingPathComponent(fileName, isDirectory: false)
        }
        return url
    }

    func ensureProfileContainers(profileId: UUID) throws {
        for directory in Directory.allCases {
            let dirURL = baseURL
                .appendingPathComponent(directory.rawValue, isDirectory: true)
                .appendingPathComponent(profileId.uuidString, isDirectory: true)
            try ensureDirectoryExists(at: dirURL)
        }
    }

    func clearAllContents() throws {
        let contents = try fileManager.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil, options: [])
        for item in contents {
            try fileManager.removeItem(at: item)
        }
        try ensureBaseDirectories()
    }

    /// Returns the filesystem URL used by MDK for its SQLite backing store.
    /// The file lives directly under the protected Application Support/MyTube directory.
    func mdkDatabaseURL() -> URL {
        baseURL.appendingPathComponent("mdk.sqlite", isDirectory: false)
    }

    /// Stores inbound parent key packages that still need approval.
    func parentKeyPackageCacheURL() -> URL {
        baseURL.appendingPathComponent("parent-key-packages.json", isDirectory: false)
    }

    private func ensureBaseDirectories() throws {
        try ensureDirectoryExists(at: baseURL)

        for directory in Directory.allCases {
            let dirURL = baseURL.appendingPathComponent(directory.rawValue, isDirectory: true)
            try ensureDirectoryExists(at: dirURL)
        }
    }

    private func ensureDirectoryExists(at url: URL) throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                throw CocoaError(.fileWriteUnknown)
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }

        #if os(iOS)
        try? fileManager.setAttributes(
            [FileAttributeKey.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        #endif
    }
}
