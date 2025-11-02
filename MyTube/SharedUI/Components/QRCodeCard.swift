//
//  QRCodeCard.swift
//  MyTube
//
//  Created by Codex on 11/27/25.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct QRCodeCard: View {
    enum Content {
        case text(label: String, value: String)
        case secure(label: String, value: String, revealed: Bool)
    }

    let title: String
    let content: Content
    let footer: String?
    let copyAction: (() -> Void)?
    let toggleSecure: (() -> Void)?
    let qrValue: String?
    let showsShareButton: Bool
    let shareAction: (() -> Void)?

    @State private var qrImage: UIImage?

    private let qrGenerator = QRCodeGenerator()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.headline)

                    switch content {
                    case let .text(label, value):
                        LabelRow(label: label, value: value, copyAction: copyAction)

                    case let .secure(label, value, revealed):
                        SecureRow(
                            label: label,
                            value: value,
                            revealed: revealed,
                            toggleSecure: toggleSecure,
                            copyAction: copyAction
                        )
                    }

                    if let footer {
                        Text(footer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let qrValue {
                    QRPreview(image: qrImage)
                        .onAppear {
                            generateQRCode(for: qrValue)
                        }
                        .onChange(of: qrValue) { newValue in
                            generateQRCode(for: newValue)
                        }
                }
            }

            if showsShareButton, let shareAction {
                Button {
                    shareAction()
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .kidCardBackground()
    }

    private func generateQRCode(for string: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let image = qrGenerator.image(for: string, size: CGSize(width: 140, height: 140))
            DispatchQueue.main.async {
                qrImage = image
            }
        }
    }
}

private struct LabelRow: View {
    let label: String
    let value: String
    let copyAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline)
            HStack(alignment: .top, spacing: 8) {
                Text(value)
                    .font(.system(.footnote).monospaced())
                    .textSelection(.enabled)
                Spacer()
                if let copyAction {
                    Button(action: copyAction) {
                        Label("Copy", systemImage: "doc.on.doc")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}

private struct SecureRow: View {
    let label: String
    let value: String
    let revealed: Bool
    let toggleSecure: (() -> Void)?
    let copyAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline)
            HStack(alignment: .center, spacing: 8) {
                Group {
                    if revealed {
                        Text(value)
                            .font(.system(.footnote).monospaced())
                            .textSelection(.enabled)
                    } else {
                        Text("••••••••••••")
                            .font(.system(.title3).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let toggleSecure {
                    Button(revealed ? "Hide" : "Reveal", action: toggleSecure)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if let copyAction {
                    Button("Copy", action: copyAction)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }
}

private struct QRPreview: View {
    let image: UIImage?

    var body: some View {
        VStack(spacing: 4) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 140, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 140, height: 140)
                    .overlay {
                        ProgressView()
                    }
            }
            Text("Scan to share")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct QRCodeGenerator {
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    func image(for string: String, size: CGSize) -> UIImage? {
        guard let data = string.data(using: .utf8) else {
            return nil
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputImage = filter.outputImage else {
            return nil
        }
        let scaleX = size.width / outputImage.extent.size.width
        let scaleY = size.height / outputImage.extent.size.height
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
