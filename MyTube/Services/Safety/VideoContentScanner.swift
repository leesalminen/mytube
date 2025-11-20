//
//  VideoContentScanner.swift
//  MyTube
//
//  Created by Assistant on 02/17/26.
//

import AVFoundation
import CoreImage
import CoreMedia
import CoreML
import Foundation
import Vision

struct ContentScanResult: Codable, Sendable {
    let isSafe: Bool
    let confidence: Double
    let flaggedReasons: [String]
    let scannedFrameCount: Int
}

final class VideoContentScanner {
    private let profanityList: Set<String> = [
        "fuck", "shit", "bitch", "asshole", "bastard", "damn", "crap"
    ]

    private let processingQueue = DispatchQueue(label: "com.mytube.contentScanner", qos: .userInitiated)
    private var poseDetectionUsable = true

    func scan(url: URL, progress: (@Sendable (String) -> Void)? = nil) async -> ContentScanResult {
        await Task.detached(priority: .utility) {
            return self.performScan(url: url, progress: progress)
        }.value
    }

    private func performScan(url: URL, progress: (@Sendable (String) -> Void)?) -> ContentScanResult {
        let asset = AVAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            return ContentScanResult(isSafe: true, confidence: 1.0, flaggedReasons: ["no_video_track"], scannedFrameCount: 0)
        }

        let frameCount = min(10, max(1, Int(track.nominalFrameRate.rounded() / 3)))
        let frameTimes = sampleTimes(for: asset, count: frameCount)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = CMTime.zero
        generator.requestedTimeToleranceAfter = CMTime.zero
        generator.appliesPreferredTrackTransform = true

        var flaggedReasons: [String] = []
        var confidenceAccumulator: Double = 0
        var processedFrames = 0

        for (index, time) in frameTimes.enumerated() {
            report(progress, message: "Scanning frame \(index + 1)/\(frameTimes.count)…")
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
            processedFrames += 1

            let sceneResult = classifyScene(cgImage: cgImage)
            confidenceAccumulator += sceneResult.confidence
            flaggedReasons.append(contentsOf: sceneResult.reasons)

            if detectProfanity(cgImage: cgImage) {
                flaggedReasons.append("profanity_text")
                confidenceAccumulator += 0.2
            }

            if detectSuggestivePose(cgImage: cgImage) {
                flaggedReasons.append("human_pose_detected")
                confidenceAccumulator += 0.1
            }
        }

        let averageConfidence = processedFrames > 0 ? confidenceAccumulator / Double(processedFrames) : 0.5
        var isSafe = flaggedReasons.isEmpty
        var finalConfidence = min(max(averageConfidence, 0.0), 1.0)

        // Secondary pass if uncertain
        if finalConfidence < 0.6 || flaggedReasons.isEmpty {
            let nsfwFrames = selectFrames(frameTimes, limit: 5)
            for (index, time) in nsfwFrames.enumerated() {
                report(progress, message: "Deep scanning \(index + 1)/\(nsfwFrames.count)…")
                guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
                processedFrames += 1
                if let score = evaluateNSFWIfAvailable(cgImage: cgImage) {
                    finalConfidence = max(finalConfidence, score)
                    if score < 0.4 {
                        flaggedReasons.append("nsfw_low_confidence")
                        isSafe = false
                    } else if score < 0.65 {
                        flaggedReasons.append("nsfw_uncertain")
                    }
                }
            }
        }

        if flaggedReasons.isEmpty {
            flaggedReasons.append("none")
        }

        return ContentScanResult(
            isSafe: isSafe,
            confidence: min(max(finalConfidence, 0.0), 1.0),
            flaggedReasons: Array(Set(flaggedReasons)),
            scannedFrameCount: processedFrames
        )
    }

    private func sampleTimes(for asset: AVAsset, count: Int) -> [CMTime] {
        guard let duration = asset.tracks(withMediaType: .video).first?.timeRange.duration, duration.seconds > 0 else {
            return [CMTime.zero]
        }

        let total = duration.seconds
        let increment = total / Double(count)
        return (0..<count).map { index in
            CMTime(seconds: Double(index) * increment, preferredTimescale: duration.timescale)
        }
    }

    private func classifyScene(cgImage: CGImage) -> (confidence: Double, reasons: [String]) {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            if let results = request.results as? [VNClassificationObservation],
               let top = results.first {
                let label = top.identifier.lowercased()
                if label.contains("violence") || label.contains("weapon") || label.contains("blood") {
                    return (Double(top.confidence), ["unsafe_scene"])
                } else if label.contains("nsfw") || label.contains("nudity") {
                    return (Double(top.confidence), ["nsfw_scene"])
                }
                return (Double(top.confidence), [])
            }
        } catch {
            return (0.5, ["vision_error"])
        }
        return (0.5, [])
    }

    private func detectProfanity(cgImage: CGImage) -> Bool {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return false }
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let tokens = candidate.string.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                if tokens.contains(where: { profanityList.contains($0) }) {
                    return true
                }
            }
        } catch {
            return false
        }
        return false
    }

    private func detectSuggestivePose(cgImage: CGImage) -> Bool {
        #if targetEnvironment(simulator)
        return false
        #endif

        guard poseDetectionUsable else { return false }
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            return (request.results as? [VNHumanBodyPoseObservation])?.isEmpty == false
        } catch {
            poseDetectionUsable = false
            return false
        }
    }

    private func evaluateNSFWIfAvailable(cgImage: CGImage) -> Double? {
        guard let pixelBuffer = cgImage.pixelBuffer() else { return nil }
        guard let modelURL = Bundle.main.url(forResource: "NSFWDetector", withExtension: "mlmodelc"),
              let mlModel = try? MLModel(contentsOf: modelURL),
              let vnModel = try? VNCoreMLModel(for: mlModel) else {
            return nil
        }

        let request = VNCoreMLRequest(model: vnModel)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do {
            try handler.perform([request])
            if let results = request.results as? [VNClassificationObservation],
               let top = results.first {
                return Double(top.confidence)
            }
        } catch {
            return nil
        }
        return nil
    }

    private func selectFrames(_ times: [CMTime], limit: Int) -> [CMTime] {
        guard times.count > limit else { return times }
        let stride = Double(times.count - 1) / Double(limit - 1)
        return (0..<limit).compactMap { index in
            let position = Int(round(Double(index) * stride))
            guard times.indices.contains(position) else { return nil }
            return times[position]
        }
    }

    private func report(_ handler: (@Sendable (String) -> Void)?, message: String) {
        guard let handler else { return }
        DispatchQueue.main.async {
            handler(message)
        }
    }
}

private extension CGImage {
    func pixelBuffer() -> CVPixelBuffer? {
        let width = self.width
        let height = self.height
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
