//
//  CaptureViewModel.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import AVFoundation
import CoreMedia
import Foundation
import UIKit

@MainActor
final class CaptureViewModel: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordDuration: TimeInterval = 0
    @Published var showSavedBanner = false
    @Published var errorMessage: String?
    @Published private(set) var isSessionReady = false
    @Published private(set) var isTorchAvailable = false
    @Published private(set) var isTorchEnabled = false
    @Published private(set) var currentZoomFactor: CGFloat = 1.0
    @Published private(set) var currentCameraPosition: AVCaptureDevice.Position = .back

    let session = AVCaptureSession()

    private let environment: AppEnvironment
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.mytube.capture.session")
    private var durationTimer: Timer?
    private var tempRecordingURL: URL?
    private var currentVideoDevice: AVCaptureDevice?
    private var zoomBaseline: CGFloat = 1.0
    private var minZoomFactor: CGFloat = 1.0
    private var maxZoomFactor: CGFloat = 6.0
    private var orientationObserver: NSObjectProtocol?

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init()

        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateVideoOrientation()
        }
    }

    deinit {
        if let observer = orientationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    func startSession() {
        isSessionReady = false
        showSavedBanner = false
        errorMessage = nil

        Task {
            guard await requestPermissions() else {
                errorMessage = "Camera or microphone access denied."
                return
            }

            sessionQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.configureSession(for: self.currentCameraPosition)
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    self.updateVideoOrientation()
                    DispatchQueue.main.async { [weak self] in
                        self?.isSessionReady = true
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.errorMessage = error.localizedDescription
                        self?.isSessionReady = false
                    }
                }
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
        stopTimer()
        isRecording = false
        isTorchEnabled = false
        isSessionReady = false
    }

    func toggleRecording() {
        guard isSessionReady else {
            errorMessage = "Camera is still preparing."
            return
        }

        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func switchCamera() {
        guard !isRecording else { return }
        isSessionReady = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let nextPosition: AVCaptureDevice.Position = self.currentCameraPosition == .back ? .front : .back
            do {
                try self.configureSession(for: nextPosition)
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                self.updateVideoOrientation()
                DispatchQueue.main.async { [weak self] in
                    self?.isSessionReady = true
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = error.localizedDescription
                    self?.isSessionReady = false
                }
            }
        }
    }

    func toggleTorch() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentVideoDevice, device.hasTorch, self.currentCameraPosition == .back else {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = "Torch not available on this camera."
                }
                return
            }

            do {
                try device.lockForConfiguration()
                let newState: Bool
                if device.torchMode == .on {
                    device.torchMode = .off
                    newState = false
                } else {
                    let level = min(AVCaptureDevice.maxAvailableTorchLevel, 1.0)
                    try device.setTorchModeOn(level: level)
                    newState = true
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { [weak self] in
                    self?.isTorchEnabled = newState
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func beginZoomGesture() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentVideoDevice else { return }
            self.zoomBaseline = device.videoZoomFactor
        }
    }

    func updateZoomGesture(scale: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentVideoDevice else { return }
            let target = min(self.maxZoomFactor, max(self.minZoomFactor, self.zoomBaseline * scale))
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = target
                device.unlockForConfiguration()
                DispatchQueue.main.async { [weak self] in
                    self?.currentZoomFactor = target
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func endZoomGesture() {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentVideoDevice else { return }
            self.zoomBaseline = device.videoZoomFactor
        }
    }

    func focus(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentVideoDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
                device.unlockForConfiguration()
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func startRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = "Camera session has not started yet."
                }
                return
            }

            guard let connection = self.movieOutput.connection(with: .video), connection.isEnabled else {
                DispatchQueue.main.async { [weak self] in
                    self?.errorMessage = "Video connection is unavailable."
                }
                return
            }

            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            try? FileManager.default.removeItem(at: tempURL)
            self.tempRecordingURL = tempURL
            self.movieOutput.startRecording(to: tempURL, recordingDelegate: self)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isRecording = true
                self.recordDuration = 0
                self.startTimer()
            }
        }
    }

    private func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
        }
        stopTimer()
        isRecording = false
    }

    private func requestPermissions() async -> Bool {
        let videoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        let videoGranted: Bool
        switch videoStatus {
        case .authorized:
            videoGranted = true
        case .notDetermined:
            videoGranted = await AVCaptureDevice.requestAccess(for: .video)
        default:
            videoGranted = false
        }

        let audioGranted: Bool
        switch audioStatus {
        case .authorized:
            audioGranted = true
        case .notDetermined:
            audioGranted = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            audioGranted = false
        }

        return videoGranted && audioGranted
    }

    private func configureSession(for position: AVCaptureDevice.Position) throws {
        guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw CaptureError.cameraUnavailable
        }

        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        for input in session.inputs {
            session.removeInput(input)
        }

        let videoInput = try AVCaptureDeviceInput(device: videoDevice)
        if session.canAddInput(videoInput) {
            session.addInput(videoInput)
        }

        if let audioDevice = AVCaptureDevice.default(for: .audio) {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            if session.canAddInput(audioInput) {
                session.addInput(audioInput)
            }
        }

        if !session.outputs.contains(movieOutput), session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }

        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
            connection.videoOrientation = currentVideoOrientation()
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = position == .front
            }
        }

        session.commitConfiguration()

        currentVideoDevice = videoDevice
        currentCameraPosition = position
        minZoomFactor = max(videoDevice.minAvailableVideoZoomFactor, 1.0)
        maxZoomFactor = min(videoDevice.maxAvailableVideoZoomFactor, videoDevice.activeFormat.videoMaxZoomFactor, 8.0)
        zoomBaseline = videoDevice.videoZoomFactor

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentZoomFactor = videoDevice.videoZoomFactor
            self.isTorchAvailable = videoDevice.hasTorch && position == .back
            if position == .front {
                self.isTorchEnabled = false
            }
        }
    }

    private func updateVideoOrientation() {
        sessionQueue.async { [weak self] in
            guard let self, let connection = self.movieOutput.connection(with: .video) else { return }
            let orientation = self.currentVideoOrientation()
            if connection.videoOrientation != orientation {
                connection.videoOrientation = orientation
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = self.currentCameraPosition == .front
            }
        }
    }

    private func currentVideoOrientation() -> AVCaptureVideoOrientation {
        switch UIDevice.current.orientation {
        case .landscapeRight:
            return .landscapeLeft
        case .landscapeLeft:
            return .landscapeRight
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .portrait:
            return .portrait
        default:
            return .portrait
        }
    }

    private func startTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.recordDuration += 1
        }
    }

    private func stopTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }
}

extension CaptureViewModel: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            if let error {
                self.errorMessage = error.localizedDescription
                return
            }

            self.isRecording = false
            self.stopTimer()
            self.handleRecordingCompletion(at: outputFileURL)
        }
    }

    private func handleRecordingCompletion(at outputURL: URL) {
        Task {
            let profile = environment.activeProfile
            let asset = AVAsset(url: outputURL)
            let duration = asset.duration.seconds
            let title = DateFormatter.captureFormatter.string(from: Date())

            do {
                let thumbnailURL = try await environment.thumbnailer.generateThumbnail(for: outputURL, profileId: profile.id)
                let request = VideoCreationRequest(
                    profileId: profile.id,
                    sourceURL: outputURL,
                    thumbnailURL: thumbnailURL,
                    title: title,
                    duration: duration,
                    tags: [],
                    cvLabels: [],
                    faceCount: 0,
                    loudness: estimateLoudness(for: asset)
                )
                _ = try await environment.videoLibrary.createVideo(request: request)
                try? FileManager.default.removeItem(at: outputURL)
                try? FileManager.default.removeItem(at: thumbnailURL)
                showSavedBanner = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private extension CaptureViewModel {
    func estimateLoudness(for asset: AVAsset) -> Double {
        guard let track = asset.tracks(withMediaType: .audio).first else { return 0.5 }
        let timeRange = CMTimeRange(start: .zero, duration: min(asset.duration, CMTime(seconds: 10, preferredTimescale: 600)))
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            return 0.5
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        if reader.canAdd(output) {
            reader.add(output)
        }
        reader.timeRange = timeRange
        reader.startReading()

        var rmsAccumulator: Double = 0
        var sampleCount: Double = 0

        while reader.status == .reading {
            guard let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) else { break }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            data.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: baseAddress)
            }
            let floatCount = length / MemoryLayout<Float>.size
            data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                let floats = ptr.bindMemory(to: Float.self)
                for i in 0..<floatCount {
                    let sample = Double(floats[i])
                    rmsAccumulator += sample * sample
                }
            }
            sampleCount += Double(floatCount)
        }

        guard sampleCount > 0 else { return 0.5 }
        let rms = sqrt(rmsAccumulator / sampleCount)
        return min(max(rms, 0), 1)
    }
}

private enum CaptureError: LocalizedError {
    case cameraUnavailable

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "Unable to access the camera."
        }
    }
}

private extension DateFormatter {
    static let captureFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
