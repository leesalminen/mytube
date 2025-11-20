//
//  CaptureView.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import AVFoundation
import SwiftUI

struct CaptureView: View {
    @StateObject private var viewModel: CaptureViewModel

    init(environment: AppEnvironment) {
        _viewModel = StateObject(wrappedValue: CaptureViewModel(environment: environment))
    }

    var body: some View {
        ZStack {
            CameraPreview(viewModel: viewModel)
                .ignoresSafeArea()

            VStack {
                headerOverlay
                Spacer()
                recordControls
            }

            if viewModel.showSavedBanner {
                SavedBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            withAnimation {
                                viewModel.showSavedBanner = false
                            }
                        }
                    }
            }

            if let error = viewModel.errorMessage {
                ErrorBanner(message: error)
                    .onTapGesture { viewModel.errorMessage = nil }
            }

            if viewModel.isScanning {
                scanningOverlay
            }

            if !viewModel.isSessionReady {
                PreparingOverlay()
            }
        }
        .onAppear { viewModel.startSession() }
        .onDisappear { viewModel.stopSession() }
    }

    private var headerOverlay: some View {
        HStack(alignment: .top) {
            ZoomBadge(factor: viewModel.currentZoomFactor)

            Spacer()

            VStack(spacing: 12) {
                if viewModel.isTorchAvailable {
                    CaptureUtilityButton(
                        systemName: viewModel.isTorchEnabled ? "bolt.circle.fill" : "bolt.circle",
                        label: viewModel.isTorchEnabled ? "Disable torch" : "Enable torch",
                        isActive: viewModel.isTorchEnabled,
                        isEnabled: viewModel.isSessionReady
                    ) {
                        viewModel.toggleTorch()
                    }
                }

                CaptureUtilityButton(
                    systemName: "arrow.triangle.2.circlepath.camera",
                    label: "Switch camera",
                    isEnabled: viewModel.isSessionReady && !viewModel.isRecording
                ) {
                    viewModel.switchCamera()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }

    private var recordControls: some View {
        VStack(spacing: 24) {
            if viewModel.isRecording {
                RecordingIndicator(elapsed: viewModel.recordDuration)
            }

            RecordButton(isRecording: viewModel.isRecording) {
                viewModel.toggleRecording()
            }
            .disabled(!viewModel.isSessionReady)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity)
    }

    private var scanningOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                Text(viewModel.scanProgress ?? "Scanning for safety…")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .padding(.bottom, 32)
        }
        .transition(.opacity)
    }
}

private struct RecordingIndicator: View {
    let elapsed: TimeInterval

    var body: some View {
        Label(timeString(elapsed), systemImage: "dot.circle.fill")
            .font(.headline.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().stroke(Color.red.opacity(0.6), lineWidth: 1)
            )
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: seconds) ?? "00:00"
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .strokeBorder(.white.opacity(0.85), lineWidth: 4)
                .frame(width: 86, height: 86)
                .overlay(
                    RoundedRectangle(cornerRadius: isRecording ? 12 : 43, style: .continuous)
                        .fill(isRecording ? Color.red : Color.red.opacity(0.92))
                        .frame(width: isRecording ? 42 : 70, height: isRecording ? 42 : 70)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Stop Recording" : "Start Recording")
    }
}

private struct SavedBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Saved to library")
                .font(.headline)
        }
        .padding()
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.top, 40)
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        VStack {
            Text(message)
                .font(.body)
                .foregroundStyle(.white)
                .padding()
                .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer()
        }
        .padding()
    }
}

private struct PreparingOverlay: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)
            Text("Preparing camera…")
                .font(.footnote)
                .foregroundStyle(.white)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ZoomBadge: View {
    let factor: CGFloat

    var body: some View {
        Text(String(format: "%.1fx", factor))
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct CaptureUtilityButton: View {
    let systemName: String
    var label: String
    var isActive: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    init(systemName: String, label: String, isActive: Bool = false, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.isActive = isActive
        self.isEnabled = isEnabled
        self.action = action
    }

    func buttonFill() -> Color {
        isActive ? Color.white : Color.black.opacity(0.35)
    }

    func foregroundColor() -> Color {
        isActive ? .black : .white
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(foregroundColor())
                .frame(width: 44, height: 44)
                .background(buttonFill(), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

private struct CameraPreview: UIViewRepresentable {
    @ObservedObject var viewModel: CaptureViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = viewModel.session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        context.coordinator.previewView = view

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = viewModel.session
        if let connection = uiView.videoPreviewLayer.connection {
            let orientation = videoOrientation(for: UIDevice.current.orientation)
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = viewModel.currentCameraPosition == .front
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var previewView: PreviewView?
        private let viewModel: CaptureViewModel

        init(viewModel: CaptureViewModel) {
            self.viewModel = viewModel
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                viewModel.beginZoomGesture()
            case .changed:
                viewModel.updateZoomGesture(scale: gesture.scale)
            case .ended, .cancelled, .failed:
                viewModel.endZoomGesture()
            default:
                break
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = previewView else { return }
            let location = gesture.location(in: view)
            let devicePoint = view.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: location)
            viewModel.focus(at: devicePoint)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }

    private func videoOrientation(for deviceOrientation: UIDeviceOrientation) -> AVCaptureVideoOrientation {
        switch deviceOrientation {
        case .landscapeRight:
            return .landscapeLeft
        case .landscapeLeft:
            return .landscapeRight
        case .portraitUpsideDown:
            return .portraitUpsideDown
        default:
            return .portrait
        }
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
