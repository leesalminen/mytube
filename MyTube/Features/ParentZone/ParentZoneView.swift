//
//  ParentZoneView.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import SwiftUI
import UIKit

struct ParentZoneView: View {
    private let environment: AppEnvironment
    @StateObject private var viewModel: ParentZoneViewModel
    @State private var shareURL: URL?

    init(environment: AppEnvironment) {
        self.environment = environment
        _viewModel = StateObject(wrappedValue: ParentZoneViewModel(environment: environment))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isUnlocked {
                    unlockedView
                } else {
                    lockView
                }
            }
            .navigationTitle("Parent Zone")
        }
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let shareURL {
                ShareSheet(activityItems: [shareURL])
            }
        }
    }

    private var unlockedView: some View {
        List {
            Section("Calm Mode") {
                Toggle(isOn: Binding(
                    get: { viewModel.calmModeEnabled },
                    set: { viewModel.toggleCalmMode($0) }
                )) {
                    Text("Filter feed to quiet videos")
                }
            }

            Section("Storage") {
                StorageMeterView(usage: viewModel.storageUsage)
                    .padding(.vertical, 8)
                Button("Refresh Storage") {
                    viewModel.storageBreakdown()
                }
            }

            Section("Relays") {
                if viewModel.relayEndpoints.isEmpty {
                    Text("Using default public relays.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.relayEndpoints) { endpoint in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle(isOn: Binding(
                                get: {
                                    viewModel.relayEndpoints.first(where: { $0.id == endpoint.id })?.isEnabled ?? false
                                },
                                set: { viewModel.setRelay(id: endpoint.id, enabled: $0) }
                            )) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(endpoint.urlString)
                                        .font(.subheadline)
                                        .textSelection(.enabled)
                                    relayStatusView(for: viewModel.status(for: endpoint))
                                }
                            }
                            .toggleStyle(.switch)

                            Button(role: .destructive) {
                                viewModel.removeRelay(id: endpoint.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Remove relay")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    TextField("wss://relay.example.com", text: $viewModel.newRelayURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    HStack {
                        Button("Add Relay") {
                            viewModel.addRelay()
                        }
                        Button("Reconnect") {
                            viewModel.refreshRelays()
                        }
                    }
                    .font(.footnote)
                }
                .padding(.vertical, 4)
            }

            Section("Library") {
                if viewModel.videos.isEmpty {
                    Text("No videos yet.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(viewModel.videos, id: \.id) { video in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(video.title)
                                .font(.headline)
                            Text(video.createdAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 16) {
                                Button(video.hidden ? "Unhide" : "Hide") {
                                    viewModel.toggleVisibility(for: video)
                                }
                                Button("Share") {
                                    shareURL = viewModel.shareURL(for: video)
                                }
                                Button(role: .destructive) {
                                    viewModel.delete(video: video)
                                } label: {
                                    Text("Delete")
                                }
                            }
                            .font(.footnote)
                        }
                        .padding(.vertical, 4)
                    }
                }
                Button("Refresh Videos") {
                    viewModel.refreshVideos()
                }
            }

            Section("Diagnostics") {
                NavigationLink {
                    NostrDiagnosticsView(environment: environment)
                } label: {
                    Label("Nostr Relay Smoke Test", systemImage: "waveform.circle")
                }
            }

            if let error = viewModel.errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var lockView: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                if viewModel.needsSetup {
                    PinCard(icon: "key.fill", title: "Create Parent PIN", subtitle: "Choose a four-digit code only you know.") {
                        PinSecureField(title: "New PIN", placeholder: "Enter 4 digits", text: $viewModel.newPin)
                        PinSecureField(title: "Confirm PIN", placeholder: "Re-enter PIN", text: $viewModel.confirmPin)
                        Button {
                            viewModel.authenticate()
                        } label: {
                            Text("Save PIN")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Text("You can enable Face ID after your PIN is saved.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    PinCard(icon: "lock.fill", title: "Unlock Parent Tools", subtitle: "Enter your PIN or authenticate with Face ID.") {
                        PinSecureField(title: "Parent PIN", placeholder: "Enter PIN", text: $viewModel.pinEntry)
                        VStack(spacing: 12) {
                            Button {
                                viewModel.authenticate()
                            } label: {
                                Text("Unlock")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)

                            Button {
                                viewModel.unlockWithBiometrics()
                            } label: {
                                Label("Unlock with Face ID", systemImage: "faceid")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

private extension ParentZoneView {
    @ViewBuilder
    func relayStatusView(for status: RelayHealth?) -> some View {
        if let status {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(color(for: status.status))
                        .frame(width: 8, height: 8)
                    Text(statusText(for: status))
                        .font(.caption)
                        .foregroundStyle(color(for: status.status))
                }
                if let error = status.errorDescription,
                   !error.isEmpty,
                   status.status == .waitingRetry {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } else {
            Text("Awaiting status…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    func statusText(for status: RelayHealth) -> String {
        switch status.status {
        case .connected:
            let count = status.activeSubscriptions
            return count > 0 ? "Connected • \(count) subs" : "Connected"
        case .connecting:
            return "Connecting…"
        case .waitingRetry:
            let attempt = status.retryAttempt
            if let next = status.nextRetry {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                let delta = formatter.localizedString(for: next, relativeTo: Date())
                return "Retrying \(delta) • attempt \(attempt)"
            } else {
                return "Retrying • attempt \(attempt)"
            }
        case .disconnected:
            return "Disconnected"
        }
    }

    func color(for status: RelayHealth.Status) -> Color {
        switch status {
        case .connected:
            return .green
        case .connecting:
            return .blue
        case .waitingRetry:
            return .orange
        case .disconnected:
            return .secondary
        }
    }
}

private struct PinCard<Content: View>: View {
    let icon: String?
    let title: String
    let subtitle: String?
    let content: Content

    init(icon: String? = nil, title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let icon {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.bold())
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color(uiColor: .separator), lineWidth: 1)
        )
    }
}

private struct PinSecureField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)

            SecureField(placeholder, text: $text)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(uiColor: .separator), lineWidth: 1)
                )
        }
    }
}

private struct StorageMeterView: View {
    let usage: ParentZoneViewModel.StorageUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView(value: usage.totalDouble, total: 1)
                .tint(.accentColor)
            HStack {
                storageRow(label: "Media", value: usage.media)
                Spacer()
                storageRow(label: "Thumbs", value: usage.thumbs)
                Spacer()
                storageRow(label: "Edits", value: usage.edits)
            }
        }
    }

    private func storageRow(label: String, value: Int64) -> some View {
        VStack(alignment: .leading) {
            Text(label)
                .font(.caption)
            Text(ByteCountFormatter.string(fromByteCount: value, countStyle: .file))
                .font(.footnote)
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private extension ParentZoneViewModel.StorageUsage {
    var totalDouble: Double {
        let capacity = 5.0 * 1024 * 1024 * 1024 // 5 GB notional capacity
        guard capacity > 0 else { return 0 }
        return min(Double(total) / capacity, 1)
    }
}
