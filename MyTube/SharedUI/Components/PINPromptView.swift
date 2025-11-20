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



    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text(title)
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                PinDots(pinLength: pin.count)

                PinKeypad(onInput: handleInput, isEnabled: !isSubmitting)

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
            .padding(32)
            .presentationDetents([.medium])
        }
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
