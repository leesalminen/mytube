//
//  EditModels.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import Foundation
import CoreGraphics
import CoreMedia
import SwiftUI

struct ClipSegment: Identifiable, Hashable {
    let id: UUID
    var sourceURL: URL
    var start: CMTime
    var end: CMTime

    init(id: UUID = UUID(), sourceURL: URL, start: CMTime, end: CMTime) {
        self.id = id
        self.sourceURL = sourceURL
        self.start = start
        self.end = end
    }
}

enum OverlayContent: Hashable {
    case sticker(name: String)
    case text(String, fontName: String, color: Color)
}

struct OverlayItem: Identifiable, Hashable {
    let id: UUID
    var content: OverlayContent
    var frame: CGRect
    var start: CMTime
    var end: CMTime

    init(
        id: UUID = UUID(),
        content: OverlayContent,
        frame: CGRect,
        start: CMTime,
        end: CMTime
    ) {
        self.id = id
        self.content = content
        self.frame = frame
        self.start = start
        self.end = end
    }
}

struct AudioTrack: Identifiable, Hashable {
    let id: UUID
    var resourceName: String
    var startOffset: CMTime
    var volume: Float

    init(id: UUID = UUID(), resourceName: String, startOffset: CMTime, volume: Float) {
        self.id = id
        self.resourceName = resourceName
        self.startOffset = startOffset
        self.volume = volume
    }
}

struct EditComposition: Hashable {
    var clip: ClipSegment
    var overlays: [OverlayItem]
    var audioTracks: [AudioTrack]
    var filterName: String?

    init(
        clip: ClipSegment,
        overlays: [OverlayItem] = [],
        audioTracks: [AudioTrack] = [],
        filterName: String? = nil
    ) {
        self.clip = clip
        self.overlays = overlays
        self.audioTracks = audioTracks
        self.filterName = filterName
    }
}
