//
//  PINPromptView.swift
//  MyTube
//
//  Created by Assistant on 02/17/26.
//

import SwiftUI

struct PINPromptView: View {
    let title: String
    let onSuccess: (String) async throws -> Void

    @EnvironmentObject private var appEnvironment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var pin: String = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    private let keypad: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["⌫", "0", "OK"]
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(title)
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                pinDots

                VStack(spacing: 12) {
                    ForEach(keypad, id: \.self) { row in
                        HStack(spacing: 12) {
                            ForEach(row, id: \.self) { value in
                                Button {
                                    handleInput(value)
                                } label: {
                                    Text(label(for: value))
                                        .font(.headline)
                                        .frame(maxWidth: .infinity, minHeight: 54)
                                        .background(buttonBackground(for: value))
                                        .foregroundStyle(.primary)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .disabled(isSubmitting)
                            }
                        }
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Confirm PIN")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(KidPrimaryButtonStyle())
                .disabled(isSubmitting || pin.count < 4)

                Spacer()
            }
            .padding(24)
            .presentationDetents([.medium])
        }
    }

    private var pinDots: some View {
        HStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                    .background(
                        Circle()
                            .fill(index < pin.count ? Color.primary : Color.clear)
                            .opacity(index < pin.count ? 0.8 : 0)
                    )
                    .frame(width: 18, height: 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func handleInput(_ value: String) {
        switch value {
        case "⌫":
            if !pin.isEmpty {
                pin.removeLast()
            }
        case "OK":
            Task { await submit() }
        default:
            guard pin.count < 4, value.allSatisfy(\.isNumber) else { return }
            pin.append(contentsOf: value)
        }
    }

    private func label(for value: String) -> String {
        value == "OK" ? "OK" : value
    }

    private func buttonBackground(for value: String) -> some ShapeStyle {
        if value == "OK" {
            return Color.accentColor.opacity(0.15)
        } else if value == "⌫" {
            return Color.secondary.opacity(0.12)
        } else {
            return Color(.secondarySystemBackground)
        }
    }

    private func reset() {
        pin = ""
        errorMessage = nil
    }

    private func submit() async {
        guard pin.count == 4 else {
            await MainActor.run {
                errorMessage = "Enter your 4-digit PIN."
            }
            return
        }

        await MainActor.run {
            isSubmitting = true
            errorMessage = nil
        }

        do {
            guard try appEnvironment.parentAuth.validate(pin: pin) else {
                await MainActor.run {
                    errorMessage = "Incorrect PIN. Try again."
                    isSubmitting = false
                    reset()
                }
                return
            }

            try await onSuccess(pin)

            await MainActor.run {
                isSubmitting = false
                reset()
                dismiss()
            }
        } catch {
            await MainActor.run {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
