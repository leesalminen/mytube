//
//  NostrDiagnosticsView.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import SwiftUI

struct NostrDiagnosticsView: View {
    @StateObject private var viewModel: ViewModel

    init(environment: AppEnvironment) {
        _viewModel = StateObject(wrappedValue: ViewModel(environment: environment))
    }

    var body: some View {
        Form {
            Section("Relay Health") {
                if viewModel.relayStatuses.isEmpty {
                    Text("No relays configured.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.relayStatuses) { status in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(status.url.absoluteString)
                                .font(.subheadline)
                                .textSelection(.enabled)
                            Text(viewModel.statusDescription(for: status))
                                .font(.caption)
                                .foregroundStyle(viewModel.statusColor(for: status.status))
                        }
                        .padding(.vertical, 2)
                    }
                }
                Button("Refresh Status") {
                    viewModel.refreshStatuses()
                }
                .disabled(viewModel.isRefreshing)
            }

            Section("Subscribe") {
                TextField("Kinds (comma separated)", text: $viewModel.kindsText)
                    .keyboardType(.numbersAndPunctuation)
                TextField("Lookback minutes", text: $viewModel.sinceMinutesText)
                    .keyboardType(.numberPad)

                HStack {
                    Button(viewModel.isSubscribing ? "Stop" : "Start") {
                        viewModel.toggleSubscription()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isTogglingSubscription)

                    Button("Clear Log") {
                        viewModel.clearLog()
                    }
                }
            }

            Section("Recent Events") {
                if viewModel.logEntries.isEmpty {
                    Text("No events captured yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(viewModel.logEntries.enumerated()), id: \.offset) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.element.summary)
                                .font(.footnote.monospacedDigit())
                            if let content = entry.element.contentPreview {
                                Text(content)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if let error = viewModel.errorMessage {
                Section("Errors") {
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Nostr Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.refreshStatuses()
        }
        .onDisappear {
            viewModel.teardown()
        }
    }
}

extension NostrDiagnosticsView {
    struct LogEntry {
        let timestamp: Date
        let kind: Int
        let id: String
        let pubkey: String
        let createdAt: Date
        let content: String

        var summary: String {
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            formatter.dateStyle = .none
            let time = formatter.string(from: timestamp)
            return "[\(time)] kind \(kind) • \(id.prefix(8))… by \(pubkey.prefix(8))…"
        }

        var contentPreview: String? {
            content.isEmpty ? nil : content
        }
    }

    @MainActor
    final class ViewModel: ObservableObject {
        @Published var relayStatuses: [RelayHealth] = []
        @Published var kindsText: String = "1,14,30300"
        @Published var sinceMinutesText: String = "10"
        @Published var logEntries: [LogEntry] = []
        @Published var errorMessage: String?
        @Published var isSubscribing = false
        @Published var isRefreshing = false
        @Published var isTogglingSubscription = false

        private let environment: AppEnvironment
        private var subscriptionId: String?
        private var eventTask: Task<Void, Never>?
        private var streamTask: Task<Void, Never>?

        init(environment: AppEnvironment) {
            self.environment = environment
        }

        func refreshStatuses() {
            guard !isRefreshing else { return }
            isRefreshing = true
            Task {
                let statuses = await environment.syncCoordinator.relayStatuses()
                await MainActor.run {
                    self.relayStatuses = statuses
                    self.isRefreshing = false
                }
            }
        }

        func toggleSubscription() {
            guard !isTogglingSubscription else { return }
            isTogglingSubscription = true

            if isSubscribing {
                stopSubscription()
                isTogglingSubscription = false
            } else {
                startSubscription()
            }
        }

        private func startSubscription() {
            let kinds = kindsText
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

            guard !kinds.isEmpty else {
                errorMessage = "Enter at least one Nostr kind."
                isTogglingSubscription = false
                return
            }

            let minutes = Int(sinceMinutesText) ?? 10
            let since = Int(Date().addingTimeInterval(Double(-minutes * 60)).timeIntervalSince1970)
            let subscription = NostrSubscription(
                filters: [
                    NostrFilter(kinds: kinds, since: since, limit: 25)
                ]
            )
            subscriptionId = subscription.id

            eventTask = Task {
                do {
                    try await environment.nostrClient.subscribe(subscription, on: nil)
                    await MainActor.run {
                        self.isSubscribing = true
                        self.isTogglingSubscription = false
                        self.errorMessage = nil
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = "Subscribe failed: \(error.localizedDescription)"
                        self.isTogglingSubscription = false
                        self.subscriptionId = nil
                    }
                }
            }

            streamTask = Task {
                for await event in environment.nostrClient.events() {
                    if subscription.filters.contains(where: { $0.kinds.isEmpty || $0.kinds.contains(event.kind) }) {
                        await MainActor.run {
                            self.appendLog(event: event)
                        }
                    }
                }
            }
        }

        private func stopSubscription() {
            eventTask?.cancel()
            streamTask?.cancel()
            if let subscriptionId {
                Task {
                    await environment.nostrClient.unsubscribe(id: subscriptionId, on: nil)
                }
            }
            subscriptionId = nil
            isSubscribing = false
            isTogglingSubscription = false
        }

        func clearLog() {
            logEntries.removeAll()
        }

        func teardown() {
            stopSubscription()
        }

        private func appendLog(event: NostrEvent) {
            if logEntries.count >= 50 {
                logEntries.removeFirst(logEntries.count - 49)
            }
            let entry = LogEntry(
                timestamp: Date(),
                kind: event.kind,
                id: event.id,
                pubkey: event.pubkey,
                createdAt: event.createdDate,
                content: event.content
            )
            logEntries.append(entry)
        }

        func statusDescription(for status: RelayHealth) -> String {
            switch status.status {
            case .connected:
                let suffix = status.activeSubscriptions > 0 ? " • \(status.activeSubscriptions) subs" : ""
                return "Connected\(suffix)"
            case .connecting:
                return "Connecting…"
            case .waitingRetry:
                if let next = status.nextRetry {
                    let formatter = RelativeDateTimeFormatter()
                    formatter.unitsStyle = .short
                    let delta = formatter.localizedString(for: next, relativeTo: Date())
                    return "Retry \(delta) (attempt \(status.retryAttempt))"
                }
                return "Retrying (attempt \(status.retryAttempt))"
            case .disconnected:
                return "Disconnected"
            }
        }

        func statusColor(for status: RelayHealth.Status) -> Color {
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
}
