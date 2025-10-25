//
//  ResourceLibrary.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import Foundation
import UIKit

struct StickerAsset: Identifiable, Hashable {
    let id: String         // base resource name without extension
    let filename: String   // e.g. sticker_01.png

    var displayName: String {
        id.components(separatedBy: CharacterSet(charactersIn: "_-"))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .capitalized
    }
}

struct MusicAsset: Identifiable, Hashable {
    let id: String         // base resource name without extension
    let filename: String   // e.g. track_01.mp3

    var displayName: String {
        id.replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

struct LUTAsset: Identifiable, Hashable {
    let id: String         // base resource name without extension
    let filename: String   // e.g. dusty_light.cube

    var displayName: String {
        id.replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

enum ResourceLibrary {
    static func stickers(in bundle: Bundle = .main) -> [StickerAsset] {
        resourceFiles(extension: "png", bundle: bundle)
            .filter { $0.filename.hasPrefix("sticker_") }
            .map { StickerAsset(id: $0.nameWithoutExtension, filename: $0.filename) }
    }

    static func musicTracks(in bundle: Bundle = .main) -> [MusicAsset] {
        resourceFiles(extension: "mp3", bundle: bundle)
            .filter { $0.filename.hasPrefix("track_") }
            .map { MusicAsset(id: $0.nameWithoutExtension, filename: $0.filename) }
    }

    static func luts(in bundle: Bundle = .main) -> [LUTAsset] {
        resourceFiles(extension: "cube", bundle: bundle)
            .map { LUTAsset(id: $0.nameWithoutExtension, filename: $0.filename) }
    }

    static func stickerImage(named resourceName: String, in bundle: Bundle = .main) -> UIImage? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "png") else {
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }

    static func musicURL(for resourceName: String, in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: resourceName, withExtension: "mp3")
    }

    static func lutURL(for resourceName: String, in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: resourceName, withExtension: "cube")
    }

    private static func resourceFiles(extension fileExtension: String, bundle: Bundle) -> [ResourceFile] {
        guard let resourcePath = bundle.resourcePath else { return [] }
        let resourceURL = URL(fileURLWithPath: resourcePath)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: resourceURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { $0.pathExtension.lowercased() == fileExtension.lowercased() }
            .map { ResourceFile(url: $0) }
            .sorted { $0.filename < $1.filename }
    }

    private struct ResourceFile {
        let url: URL

        var filename: String {
            url.lastPathComponent
        }

        var nameWithoutExtension: String {
            url.deletingPathExtension().lastPathComponent
        }
    }
}
