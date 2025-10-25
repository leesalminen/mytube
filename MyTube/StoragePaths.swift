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
