//
//  VideoContentScannerTests.swift
//  MyTubeTests
//
//  Created by Assistant on 02/18/26.
//

import AVFoundation
import XCTest
@testable import MyTube

final class VideoContentScannerTests: XCTestCase {
    func testScanHandlesMissingTrackGracefully() async {
        let scanner = VideoContentScanner()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("missing-video-\(UUID().uuidString).mp4")
        try? "junk".data(using: .utf8)?.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let result = await scanner.scan(url: tempURL)

        XCTAssertTrue(result.isSafe)
        XCTAssertEqual(result.scannedFrameCount, 0)
        XCTAssertTrue(result.flaggedReasons.contains("no_video_track"))
    }

    func testScanReportsProgressForTinyVideo() async throws {
        let scanner = VideoContentScanner()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("scanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let videoURL = tempDir.appendingPathComponent("tiny.mp4")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try makeTinyVideo(at: videoURL, frames: 4)

        var progressMessages: [String] = []
        let result = await scanner.scan(url: videoURL) { message in
            progressMessages.append(message)
        }

        XCTAssertFalse(progressMessages.isEmpty, "Expected progress updates during scan")
        XCTAssertGreaterThan(result.scannedFrameCount, 0)
        XCTAssertFalse(result.flaggedReasons.isEmpty)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.0)
        XCTAssertLessThanOrEqual(result.confidence, 1.0)
    }

    private func makeTinyVideo(at url: URL, frames: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 160
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: 160,
                kCVPixelBufferHeightKey as String: 160
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(value: 1, timescale: 5)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard let buffer = makePixelBuffer(width: 160, height: 160, gray: UInt8(40 + index * 10)) else { continue }
            adaptor.append(buffer, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(index)))
        }

        input.markAsFinished()
        let expectation = expectation(description: "finish writing")
        writer.finishWriting {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
        XCTAssertEqual(writer.status, .completed)
    }

    private func makePixelBuffer(width: Int, height: Int, gray: UInt8) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferBytesPerRowAlignmentKey as String: width * 4
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            var rowPointer = base.assumingMemoryBound(to: UInt8.self)
            for _ in 0..<height {
                for offset in stride(from: 0, to: bytesPerRow, by: 4) {
                    rowPointer[offset + 0] = 255 // A
                    rowPointer[offset + 1] = gray // R
                    rowPointer[offset + 2] = gray // G
                    rowPointer[offset + 3] = gray // B
                }
                rowPointer = rowPointer.advanced(by: bytesPerRow)
            }
        }
        return buffer
    }
}
