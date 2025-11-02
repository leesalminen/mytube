//
//  QRCodeScannerView.swift
//  MyTube
//
//  Created by Codex on 11/06/25.
//

import AVFoundation
import SwiftUI
import UIKit

struct QRCodeScannerView: UIViewControllerRepresentable {
    typealias UIViewControllerType = ScannerViewController

    private let onCode: (String) -> Void

    init(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
    }

    func makeUIViewController(context: Context) -> ScannerViewController {
        ScannerViewController(onCode: onCode)
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: ScannerViewController, coordinator: ()) {
        uiViewController.stopSession()
    }

    final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private let onCode: (String) -> Void
        private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
        private var hasConfiguredSession = false
        private var isHandlingCode = false
        private let statusLabel = UILabel()
        private var metadataOutput: AVCaptureMetadataOutput?

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            statusLabel.textColor = .white
            statusLabel.textAlignment = .center
            statusLabel.numberOfLines = 0
            statusLabel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(statusLabel)
            NSLayoutConstraint.activate([
                statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
                statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
                statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            statusLabel.isHidden = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleOrientationChange),
                name: UIDevice.orientationDidChangeNotification,
                object: nil
            )
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            configureCameraAccess()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.layer.bounds
            updateVideoOrientation()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            updateVideoOrientation()
            startSession()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            stopSession()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }

        func configureCameraAccess() {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configureSession()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        if granted {
                            self.configureSession()
                            self.startSession()
                        } else {
                            self.showPermissionDenied()
                        }
                    }
                }
            default:
                showPermissionDenied()
            }
        }

        func configureSession() {
            guard !hasConfiguredSession else { return }

            guard let device = AVCaptureDevice.default(for: .video) else {
                showPermissionDenied()
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) {
                    session.addInput(input)
                }

                let output = AVCaptureMetadataOutput()
                if session.canAddOutput(output) {
                    session.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                    output.metadataObjectTypes = [.qr]
                    metadataOutput = output
                }

                let preview = AVCaptureVideoPreviewLayer(session: session)
                preview.videoGravity = .resizeAspectFill
                preview.frame = view.layer.bounds
                view.layer.insertSublayer(preview, at: 0)
                previewLayer = preview
                hasConfiguredSession = true
                updateVideoOrientation()
            } catch {
                showPermissionDenied()
            }
        }

        func startSession() {
            guard hasConfiguredSession, !session.isRunning else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                self.session.startRunning()
            }
        }

        func stopSession() {
            guard session.isRunning else { return }
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !isHandlingCode else { return }
            guard
                let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                let value = object.stringValue
            else { return }

            isHandlingCode = true
            stopSession()
            feedbackGenerator.impactOccurred()
            onCode(value)
        }

        @objc
        private func handleOrientationChange() {
            updateVideoOrientation()
        }

        private func updateVideoOrientation() {
            let interfaceOrientation = resolveInterfaceOrientation()
            guard let videoOrientation = AVCaptureVideoOrientation(interfaceOrientation: interfaceOrientation) else {
                return
            }

            if let connection = previewLayer?.connection, connection.isVideoOrientationSupported {
                connection.videoOrientation = videoOrientation
            }

            if let metadataConnection = metadataOutput?.connection(with: .video),
               metadataConnection.isVideoOrientationSupported {
                metadataConnection.videoOrientation = videoOrientation
            }
        }

        private func resolveInterfaceOrientation() -> UIInterfaceOrientation {
            if let windowScene = view.window?.windowScene {
                return windowScene.interfaceOrientation
            }
            let orientations = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }
            return orientations.first ?? .portrait
        }

        private func showPermissionDenied() {
            statusLabel.isHidden = false
            statusLabel.text = "Camera access is required to scan QR codes. Enable camera permissions in Settings."
        }
    }
}

private extension AVCaptureVideoOrientation {
    init?(interfaceOrientation: UIInterfaceOrientation) {
        switch interfaceOrientation {
        case .portrait:
            self = .portrait
        case .portraitUpsideDown:
            self = .portraitUpsideDown
        case .landscapeLeft:
            self = .landscapeLeft
        case .landscapeRight:
            self = .landscapeRight
        default:
            return nil
        }
    }
}
