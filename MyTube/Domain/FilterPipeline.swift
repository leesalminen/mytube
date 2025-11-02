//
//  FilterPipeline.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

struct FilterDescriptor: Identifiable {
    let id: String
    let displayName: String
    let configuration: (CIFilter) -> Void
}

struct FilterPipeline {
    private let context: CIContext

    init(context: CIContext = CIContext(options: nil)) {
        self.context = context
    }

    func render(sampleBuffer: CVPixelBuffer, filterName: String?) -> CVPixelBuffer? {
        guard let filterName, !filterName.isEmpty else { return sampleBuffer }

        let ciImage = CIImage(cvPixelBuffer: sampleBuffer)

        guard let outputImage = FilterPipeline.apply(filterName: filterName, to: ciImage) else {
            return sampleBuffer
        }

        return render(image: outputImage)
    }

    private func render(image: CIImage) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        CVPixelBufferCreate(
            nil,
            Int(image.extent.width),
            Int(image.extent.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard let targetBuffer = pixelBuffer else { return nil }
        context.render(image, to: targetBuffer)
        return targetBuffer
    }

    static func presets() -> [FilterDescriptor] {
        [
            FilterDescriptor(id: "CIPhotoEffectNoir", displayName: "Noir") { _ in },
            FilterDescriptor(id: "CIPhotoEffectChrome", displayName: "Chrome") { _ in },
            FilterDescriptor(id: "CIPhotoEffectTransfer", displayName: "Retro") { _ in },
            FilterDescriptor(id: "CIColorControls", displayName: "Vibrant") { filter in
                filter.setValue(1.2, forKey: kCIInputSaturationKey)
                filter.setValue(1.05, forKey: kCIInputContrastKey)
            }
        ]
    }

    static func lutPresets() -> [FilterDescriptor] {
        ResourceLibrary.luts().map { lut in
            FilterDescriptor(id: "lut://\(lut.id)", displayName: lut.displayName) { _ in }
        }
    }

    private static let presetConfiguration: [String: (CIFilter) -> Void] = {
        var map: [String: (CIFilter) -> Void] = [:]
        for descriptor in FilterPipeline.presets() {
            map[descriptor.id] = descriptor.configuration
        }
        return map
    }()

    static func apply(filterName: String, to image: CIImage) -> CIImage? {
        guard !filterName.isEmpty else { return nil }

        if let lutImage = applyLUT(filterName: filterName, to: image) {
            return lutImage
        }

        guard let filter = CIFilter(name: filterName) else { return nil }
        presetConfiguration[filterName]?(filter)
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage
    }

    private static func applyLUT(filterName: String, to image: CIImage) -> CIImage? {
        guard filterName.hasPrefix("lut://") else { return nil }
        let resourceName = String(filterName.dropFirst("lut://".count))
        guard let lut = LUTCache.shared.lutData(named: resourceName) else { return nil }

        guard let filter = CIFilter(name: "CIColorCube") else { return nil }
        filter.setValue(lut.dimension, forKey: "inputCubeDimension")
        filter.setValue(lut.data, forKey: "inputCubeData")
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage
    }
}

private final class LUTCache {
    struct LUTData {
        let data: NSData
        let dimension: NSNumber
    }

    static let shared = LUTCache()

    private var cache: [String: LUTData] = [:]
    private let lock = NSLock()

    func lutData(named resourceName: String) -> LUTData? {
        lock.lock()
        if let cached = cache[resourceName] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let url = ResourceLibrary.lutURL(for: resourceName) else { return nil }
        guard let result = parseCube(at: url) else { return nil }

        lock.lock()
        cache[resourceName] = result
        lock.unlock()
        return result
    }

    private func parseCube(at url: URL) -> LUTData? {
        guard let contents = try? String(contentsOf: url) else { return nil }
        var dimension: Int = 0
        var values: [Float] = []
        let whitespace = CharacterSet.whitespacesAndNewlines

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: whitespace)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let components = line.components(separatedBy: whitespace).filter { !$0.isEmpty }
            guard !components.isEmpty else { continue }

            if components[0].uppercased() == "LUT_3D_SIZE", components.count >= 2, let size = Int(components[1]) {
                dimension = size
            } else if components.count == 3 {
                if let r = Float(components[0]),
                   let g = Float(components[1]),
                   let b = Float(components[2]) {
                    values.append(contentsOf: [r, g, b])
                }
            }
        }

        guard dimension > 0 else { return nil }
        let expectedCount = dimension * dimension * dimension * 3
        guard values.count == expectedCount else { return nil }

        let data = values.withUnsafeBufferPointer { buffer in
            NSData(bytes: buffer.baseAddress!, length: buffer.count * MemoryLayout<Float>.size)
        }
        return LUTData(data: data, dimension: NSNumber(value: dimension))
    }
}
