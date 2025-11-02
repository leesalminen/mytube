//
//  ReportAbuseSheet.swift
//  MyTube
//
//  Created by Assistant on 02/15/26.
//

import SwiftUI

struct ReportAbuseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedReason: ReportReason = .inappropriate
    @State private var note: String = ""
    @State private var shouldBlock = false
    @State private var shouldUnfollow = false
    @FocusState private var noteFocused: Bool

    var allowsRelationshipActions: Bool = true
    let isSubmitting: Bool
    @Binding var errorMessage: String?
    let onSubmit: (ReportReason, String?, ReportAction) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Reason") {
                    Picker("Why are you reporting?", selection: $selectedReason) {
                        ForEach(ReportReason.allCases, id: \.self) { reason in
                            Text(reason.displayName).tag(reason)
                        }
                    }
                    .pickerStyle(.inline)
                }

                if allowsRelationshipActions {
                    Section("Actions") {
                        Toggle("Unfollow this family", isOn: $shouldUnfollow)
                            .disabled(shouldBlock || isSubmitting)

                        Toggle("Block this family", isOn: $shouldBlock)
                            .disabled(isSubmitting)
                            .onChange(of: shouldBlock) { newValue in
                                if newValue {
                                    shouldUnfollow = true
                                }
                            }
                    }
                }

                Section("Notes (optional)") {
                    TextEditor(text: $note)
                        .frame(minHeight: 120)
                        .focused($noteFocused)
                        .disabled(isSubmitting)
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Report Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        noteFocused = false
                        onCancel()
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        noteFocused = false
                        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        let finalNote = trimmedNote.isEmpty ? nil : trimmedNote
                        onSubmit(selectedReason, finalNote, selectedAction())
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Submit")
                        }
                    }
                    .disabled(isSubmitting)
                }
            }
        }
    }

    private func selectedAction() -> ReportAction {
        if shouldBlock {
            return .block
        } else if shouldUnfollow {
            return .unfollow
        } else {
            return .reportOnly
        }
    }
}

struct ReportButtonChip: View {
    var title: String = "Report"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.12), in: Capsule())
                .foregroundStyle(.red)
        }
        .accessibilityLabel(title)
    }
}
