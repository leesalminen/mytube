//
//  ParentZoneView.swift
//  MyTube
//
//  Created by Codex on 10/24/25.
//

import Combine
import Foundation
import SwiftUI
import UIKit

struct ParentZoneView: View {
    private let environment: AppEnvironment
    @StateObject private var viewModel: ParentZoneViewModel
    @State private var sharePayload: [Any]?
    @State private var showingResetAlert = false
    @State private var isAddingChild = false
    @State private var newChildName = ""
    @State private var newChildTheme: ThemeDescriptor = .ocean
    @State private var isImportingChild = false
    @State private var importChildName = ""
    @State private var importChildSecret = ""
    @State private var importChildTheme: ThemeDescriptor = .ocean
    @State private var qrIntent: QRIntent?
    @State private var sharePromptVideo: VideoModel?
    @State private var shareRecipient: String = ""
    @State private var shareStatusMessage: String?
    @State private var shareStatusIsError = false
    @State private var shareIsSending = false
    @State private var shareSelectedParentKey: String?
    @State private var shareParentOptions: [String] = []
    @State private var isRequestingFollow = false
    @State private var followChildSelection: UUID?
    @State private var followTargetChildKey = ""
    @State private var followTargetParentKey = ""
    @State private var followFormError: String?
    @State private var followIsSubmitting = false
    @State private var followSelectedParentKey: String?
    @State private var followParentOptions: [String] = []
    @State private var followInviteInput: String = ""
    @State private var approvingFollowID: String?
    @State private var parentProfileName: String = ""
    @State private var isPublishingParentProfile = false
    @State private var selectedSection: ParentZoneSection = .overview
    @State private var expandedChildIDs: Set<UUID> = []
    @State private var familyViewSelection: FamilyViewSelection = .parent
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    init(environment: AppEnvironment) {
        self.environment = environment
        _viewModel = StateObject(wrappedValue: ParentZoneViewModel(environment: environment))
    }

    @ViewBuilder
    private func relayStatusRow(for endpoint: RelayDirectory.Endpoint) -> some View {
        let isEnabledBinding = Binding(
            get: { viewModel.relayEndpoints.first(where: { $0.id == endpoint.id })?.isEnabled ?? false },
            set: { viewModel.setRelay(id: endpoint.id, enabled: $0) }
        )

        HStack(alignment: .top, spacing: 12) {
            Toggle(isOn: isEnabledBinding) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(endpoint.urlString)
                        .font(.subheadline)
                        .textSelection(.enabled)
                    relayStatusLabel(for: viewModel.status(for: endpoint))
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

    @ViewBuilder
    private func relayStatusLabel(for status: RelayHealth?) -> some View {
        if let status {
            let summary = relayStatusSummary(for: status)
            Text(summary.text)
                .font(.caption)
                .foregroundStyle(summary.color)
        } else {
            Text("Status unknown")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func relayStatusSummary(for status: RelayHealth) -> (text: String, color: Color) {
        switch status.status {
        case .connected:
            var parts: [String] = ["Connected"]
            if status.activeSubscriptions > 0 {
                parts.append("\(status.activeSubscriptions) subs")
            }
            if let latency = status.roundTripLatency {
                let ms = latency * 1000
                if ms >= 100 {
                    parts.append(String(format: "%.0f ms", ms))
                } else {
                    parts.append(String(format: "%.1f ms", ms))
                }
            }
            return (parts.joined(separator: " • "), .green)
        case .connecting:
            return ("Connecting…", .blue)
        case .waitingRetry:
            if let nextRetry = status.nextRetry {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                let delta = formatter.localizedString(for: nextRetry, relativeTo: Date())
                if status.consecutiveFailures > 0 {
                    return ("Retry \(delta) (attempt \(status.retryAttempt)) • failures \(status.consecutiveFailures)", .orange)
                }
                return ("Retry \(delta) (attempt \(status.retryAttempt))", .orange)
            }
            if status.consecutiveFailures > 0 {
                return ("Retrying (attempt \(status.retryAttempt)) • failures \(status.consecutiveFailures)", .orange)
            }
            return ("Retrying (attempt \(status.retryAttempt))", .orange)
        case .disconnected:
            if status.consecutiveFailures > 0 {
                return ("Disconnected • failures \(status.consecutiveFailures)", .secondary)
            }
            return ("Disconnected", .secondary)
        case .error:
            if let description = status.errorDescription, !description.isEmpty {
                return ("Error • \(description)", .red)
            }
            return ("Error", .red)
        }
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
            get: { sharePayload != nil },
            set: { if !$0 { sharePayload = nil } }
        )) {
            if let sharePayload {
                ShareSheet(activityItems: sharePayload)
            }
        }
        .sheet(item: $qrIntent) { intent in
            QRScannerSheet(
                title: intent.title,
                onResult: { value in
                    handleScanResult(value, for: intent)
                    qrIntent = nil
                },
                onCancel: { qrIntent = nil }
            )
        }
        .sheet(isPresented: $isAddingChild) {
            ChildProfileFormSheet(
                title: "Add Child Profile",
                name: $newChildName,
                theme: $newChildTheme,
                onCancel: resetChildCreationState,
                onSave: {
                    viewModel.addChildProfile(name: newChildName, theme: newChildTheme)
                    resetChildCreationState()
                }
            )
        }
        .sheet(isPresented: $isImportingChild) {
            ChildImportFormSheet(
                name: $importChildName,
                secret: $importChildSecret,
                theme: $importChildTheme,
                onScan: { qrIntent = .importChild },
                onCancel: resetChildImportState,
                onImport: {
                    viewModel.importChildProfile(
                        name: importChildName,
                        secret: importChildSecret,
                        theme: importChildTheme
                    )
                    resetChildImportState()
                }
            )
        }
        .sheet(isPresented: $isRequestingFollow) {
            NavigationStack {
                Form {
                    Section("Pick a Child") {
                        Picker("Local child", selection: $followChildSelection) {
                            ForEach(viewModel.childIdentities) { child in
                                Text(child.displayName)
                                    .tag(Optional(child.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(followIsSubmitting)
                        .onAppear {
                            if followChildSelection == nil {
                                followChildSelection = viewModel.childIdentities.first?.id
                            }
                        }
                    }

                    Section("Share this invite with the other parent") {
                        if let childId = followChildSelection,
                           let child = viewModel.childIdentities.first(where: { $0.id == childId }),
                           let invite = viewModel.followInvite(for: child) {
                            let summary = "Parent: \(shortKey(invite.parentPublicKey))\nChild: \(shortKey(invite.childPublicKey))"
                            Text("Copy or scan once so the other parent gets both keys and your Marmot key package.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            QRCodeCard(
                                title: "\(child.displayName) Marmot Invite",
                                content: .text(label: "Includes both keys", value: summary),
                                footer: "Share this exact invite so the group connects in one step.",
                                copyAction: { copyToPasteboard(invite.encodedURL ?? invite.shareText) },
                                toggleSecure: nil,
                                qrValue: invite.encodedURL,
                                showsShareButton: true,
                                shareAction: { presentShare(invite.shareItems) }
                            )
                        } else {
                            Text("Select a child to generate their Marmot invite. We package your key automatically so the other parent can't miss it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Connect using an invite") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Paste the Marmot invite link or scan the QR from the other parent. We auto-fill both keys and keep their Marmot key package so approval works in one step.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextField("Paste Marmot invite link or payload", text: $followInviteInput, axis: .vertical)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(.footnote).monospaced())
                                .lineLimit(2...4)
                                .disabled(followIsSubmitting)

                            HStack(spacing: 10) {
                                Button {
                                    pasteFollowInviteFromClipboard()
                                } label: {
                                    Label("Paste", systemImage: "doc.on.clipboard")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(followIsSubmitting)

                                Button {
                                    qrIntent = .followParent
                                } label: {
                                    Label("Scan invite", systemImage: "qrcode.viewfinder")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(followIsSubmitting)
                            }

                            if !followTargetChildKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               !followTargetParentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Label(
                                    "Ready to connect \(shortKey(followTargetParentKey)) ↔︎ \(shortKey(followTargetChildKey))",
                                    systemImage: "checkmark.circle.fill"
                                )
                                .foregroundStyle(.green)
                                .font(.footnote)
                            }

                            DisclosureGroup("Enter keys manually (fallback)") {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        TextField("Friend's child npub or hex", text: $followTargetChildKey)
                                            .textInputAutocapitalization(.never)
                                            .autocorrectionDisabled()
                                            .font(.system(.footnote).monospaced())
                                            .disabled(followIsSubmitting)
                                        Button {
                                            qrIntent = .followChild
                                        } label: {
                                            Label("Scan child key", systemImage: "qrcode.viewfinder")
                                                .labelStyle(.iconOnly)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .disabled(followIsSubmitting)
                                        .accessibilityLabel("Scan friend child key QR")
                                    }

                                    HStack {
                                        TextField("Friend's parent npub or hex", text: $followTargetParentKey)
                                            .textInputAutocapitalization(.never)
                                            .autocorrectionDisabled()
                                            .font(.system(.footnote).monospaced())
                                            .disabled(followIsSubmitting)
                                        Button {
                                            qrIntent = .followParent
                                        } label: {
                                            Label("Scan parent key", systemImage: "qrcode.viewfinder")
                                                .labelStyle(.iconOnly)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .disabled(followIsSubmitting)
                                        .accessibilityLabel("Scan friend parent key QR")
                                    }

                                    Text("Use manual entry only if the invite link is unavailable. Sharing the invite is the most reliable path because it includes the Marmot key package.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !followParentOptions.isEmpty {
                        Section("Families you've approved") {
                            Picker("Linked parent", selection: Binding(
                                get: { followSelectedParentKey },
                                set: { newValue in
                                    followSelectedParentKey = newValue
                                    if let newValue {
                                        followTargetParentKey = newValue
                                    }
                                }
                            )) {
                                Text("Custom…").tag(String?.none)
                                ForEach(followParentOptions, id: \.self) { key in
                                    Text(shortKey(key))
                                        .tag(Optional(key))
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(followIsSubmitting)
                            Text("Approved parents appear after a Marmot invite is accepted, so you can autofill the other family's key.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Section {
                            Text("Approve a Marmot invite to remember trusted families for quick reuse.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if followIsSubmitting {
                        Section {
                            ProgressView("Sending…")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }

                    if let followFormError {
                        Section {
                            Text(followFormError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                .navigationTitle("Marmot Invite")
                .onChange(of: followInviteInput) { _ in
                    parseFollowInviteInput()
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismissFollowRequest()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Connect") {
                            guard let childId = followChildSelection else {
                                followFormError = "Select which child is sending the invite."
                                return
                            }
                            parseFollowInviteInput()
                            guard
                                !followTargetChildKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                !followTargetParentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            else {
                                followFormError = "Paste or scan the Marmot invite so we can include both keys."
                                return
                            }
                            followFormError = nil
                            followIsSubmitting = true
                            Task {
                                let error = await viewModel.submitFollowRequest(
                                    childId: childId,
                                    targetChildKey: followTargetChildKey,
                                    targetParentKey: followTargetParentKey
                                )
                                followIsSubmitting = false
                                if let error {
                                    followFormError = error
                                } else {
                                    dismissFollowRequest()
                                }
                            }
                        }
                        .disabled(
                            followIsSubmitting
                                || followChildSelection == nil
                                || followTargetChildKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || followTargetParentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Reset Tubestr?", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                viewModel.resetApp()
            }
        } message: {
            Text("This clears all local videos, profiles, keys, and settings. You cannot undo this action.")
        }
        .sheet(item: $sharePromptVideo, onDismiss: {
            dismissSharePrompt()
        }) { video in
            NavigationStack {
                Form {
                    Section("Recipient") {
                        HStack {
                            TextField("npub1… or hex", text: $shareRecipient)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(.footnote).monospaced())
                                .disabled(shareIsSending)
                            Button {
                                qrIntent = .shareParent
                            } label: {
                                Label("Scan parent key", systemImage: "qrcode.viewfinder")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(shareIsSending)
                            .accessibilityLabel("Scan recipient parent key QR")
                        }
                        Text("The other parent must accept your Marmot invite before their kids can watch new shares.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }

                    if !shareParentOptions.isEmpty {
                        Section("Approved Parents") {
                            Picker("Linked parent", selection: Binding(
                                get: { shareSelectedParentKey },
                                set: { newValue in
                                    shareSelectedParentKey = newValue
                                    if let newValue {
                                        shareRecipient = newValue
                                    }
                                }
                            )) {
                                Text("Custom…").tag(String?.none)
                                ForEach(shareParentOptions, id: \.self) { key in
                                    Text(shortKey(key))
                                        .tag(Optional(key))
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(shareIsSending)
                            Text("Approved parents appear here after a Marmot invite is accepted, so you can autofill the other family's key.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Section {
                            Text("No approved families yet. Approve a Marmot invite so you know who you're sharing with.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Video") {
                        Text(video.title)
                            .font(.headline)
                        Text(video.createdAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Duration: \(Int(video.duration)) sec")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if shareIsSending {
                        Section {
                            ProgressView("Sending…")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }

                    if let message = shareStatusMessage {
                        Section {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(shareStatusIsError ? .red : .green)
                                .textSelection(.enabled)
                        }
                    }
                }
                .navigationTitle("Send Secure Share")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismissSharePrompt()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") {
                            sendShare(for: video)
                        }
                        .disabled(shareIsSending || shareRecipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear {
            syncParentProfileFields(with: viewModel.parentProfile)
        }
        .onChange(of: viewModel.parentProfile) { profile in
            syncParentProfileFields(with: profile)
        }
    }

    private var unlockedView: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $selectedSection) {
                ForEach(ParentZoneSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 12)

            sectionContent(for: selectedSection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
        }
        .background(Color.clear)
        .animation(.easeInOut(duration: 0.2), value: selectedSection)
        .overlay(alignment: .bottom) {
            errorBanner
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
                        .buttonStyle(KidPrimaryButtonStyle())
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
                            .buttonStyle(KidPrimaryButtonStyle())
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
        .background(Color.clear)
    }
}

private extension ParentZoneView {
    @ViewBuilder
    private func sectionContent(for section: ParentZoneSection) -> some View {
        switch section {
        case .overview:
            overviewSection
        case .family:
            familySection
        case .connections:
            connectionsSection
        case .library:
            librarySection
        case .storage:
            storageSection
        case .safety:
            safetySection
        case .settings:
            settingsSection
        }
    }

    private func insetGroupedList<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        List {
            content()
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = viewModel.errorMessage {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.red.opacity(0.9))
                )
                .padding(.horizontal)
                .padding(.bottom, 24)
        }
    }

    private var overviewSection: some View {
        let childCount = viewModel.childIdentities.count
        let videoCount = viewModel.videos.count
        let incomingCount = viewModel.incomingFollowRequests().count
        let activeCount = viewModel.activeFollowConnections().count
        let remoteShareCount = viewModel.totalAvailableRemoteShares()
        let groupCount = viewModel.marmotDiagnostics.groupCount
        let pendingWelcomes = viewModel.pendingWelcomes.count

        return insetGroupedList {
            Section("Family Summary") {
                if viewModel.parentIdentity != nil {
                    Label("Parent key ready", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(Color.green)
                } else {
                    Label("Parent key not configured", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                    Text("Create your parent identity to link families and publish profiles.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Label("\(childCount) child \(childCount == 1 ? "profile" : "profiles")", systemImage: "person.2.fill")
                    .foregroundStyle(Color.primary)

                Label("\(videoCount) saved \(videoCount == 1 ? "video" : "videos")", systemImage: "film.stack")
                    .foregroundStyle(Color.primary)

                Label("\(activeCount) active family \(activeCount == 1 ? "connection" : "connections")", systemImage: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(activeCount > 0 ? Color.accentColor : Color.secondary)

                if groupCount > 0 {
                    Label("\(groupCount) Marmot \(groupCount == 1 ? "group" : "groups") ready", systemImage: "person.3.sequence")
                        .foregroundStyle(Color.primary)
                } else {
                    Label("No Marmot groups yet", systemImage: "person.3.sequence.fill")
                        .foregroundStyle(Color.secondary)
                }

                if remoteShareCount > 0 {
                    Label("\(remoteShareCount) shared \(remoteShareCount == 1 ? "video" : "videos") from friends", systemImage: "tray.and.arrow.down.fill")
                        .foregroundStyle(Color.purple)
                }

                if pendingWelcomes > 0 {
                    Label("\(pendingWelcomes) pending Marmot invite\(pendingWelcomes == 1 ? "" : "s")", systemImage: "envelope.open")
                        .foregroundStyle(Color.orange)
                }

                if incomingCount > 0 {
                    Label("\(incomingCount) pending approval\(incomingCount == 1 ? "" : "s")", systemImage: "bell.badge.fill")
                        .foregroundStyle(Color.orange)
                }
            }

            Section("Quick Actions") {
                if viewModel.parentIdentity == nil {
                    Button {
                        viewModel.createParentIdentity()
                    } label: {
                        Label("Generate Parent Key", systemImage: "key.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(KidPrimaryButtonStyle())
                }

                childProfileActions

                Button {
                    prepareFollowRequest()
                } label: {
                    Label("New Marmot Invite", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.childIdentities.isEmpty)

                if viewModel.childIdentities.isEmpty {
                    Text("Add a child profile before sending Marmot invites.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Storage Snapshot") {
                StorageMeterView(usage: viewModel.storageUsage)
                    .padding(.vertical, 8)

                HStack {
                    Label(
                        viewModel.storageMode == .managed ? "Managed cloud enabled" : "Bring your own storage",
                        systemImage: viewModel.storageMode == .managed ? "icloud.and.arrow.down" : "externaldrive.fill"
                    )
                    .labelStyle(.titleAndIcon)
                    Spacer()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if let entitlement = viewModel.entitlement {
                    storageEntitlementSummary(entitlement)
                } else {
                    Text(viewModel.storageMode == .managed ?
                         "Start a free trial or refresh managed storage when you're ready." :
                         "Switch to Managed storage to try the Tubestr cloud uploads.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Refresh Storage") {
                    viewModel.storageBreakdown()
                }
            }
        }
    }

    private var familySection: some View {
        insetGroupedList {
            Section {
                Picker("Family Detail", selection: $familyViewSelection) {
                    ForEach(FamilyViewSelection.allCases) { selection in
                        Text(selection.title).tag(selection)
                    }
                }
                .pickerStyle(.segmented)
            }

            switch familyViewSelection {
            case .parent:
                Section("Parent Identity") {
                    if let parent = viewModel.parentIdentity {
                        identityParentSection(parent: parent)
                    } else {
                        Button {
                            viewModel.createParentIdentity()
                        } label: {
                            Label("Generate Parent Key", systemImage: "key.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(KidPrimaryButtonStyle())

                        Text("Your parent key manages child profiles, storage, and Marmot invites.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .children:
                Section("Child Profiles") {
                    childProfileActions

                    if viewModel.childIdentities.isEmpty {
                        Text("No child profiles yet. Add or import a delegated key to sync kid devices.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(viewModel.childIdentities) { child in
                            identityChildSection(child: child)
                        }
                    }
                }
            }
        }
    }

    private var connectionsSection: some View {
        // Get all children with groups
        let childrenWithGroups = viewModel.childIdentities.filter { child in
            viewModel.groupSummary(for: child) != nil
        }
        
        return insetGroupedList {
            Section("Marmot Invites & Approvals") {
                Button {
                    prepareFollowRequest()
                } label: {
                    Label("New Marmot Invite", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(KidPrimaryButtonStyle())
                .disabled(viewModel.childIdentities.isEmpty)

                if viewModel.childIdentities.isEmpty {
                    Text("Add a child profile before sending Marmot invites.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }

            Section("Active Marmot Groups") {
                Button {
                    viewModel.refreshConnections()
                    viewModel.refreshMarmotDiagnostics()
                } label: {
                    Label("Refresh Groups", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if childrenWithGroups.isEmpty {
                    Text("No active Marmot groups yet. Create a group by sending an invite to another family.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(childrenWithGroups) { child in
                        activeGroupRow(child: child)
                    }
                }
            }

            Section("Pending Welcomes") {
                if viewModel.pendingWelcomes.isEmpty {
                    if viewModel.isRefreshingPendingWelcomes {
                        HStack {
                            ProgressView()
                            Text("Loading invites…")
                        }
                        .font(.caption)
                    } else {
                        Text("No pending Marmot welcomes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(viewModel.pendingWelcomes) { welcome in
                        pendingWelcomeRow(welcome)
                    }
                }

                Button {
                    Task {
                        await viewModel.refreshPendingWelcomes()
                    }
                } label: {
                    if viewModel.isRefreshingPendingWelcomes {
                        HStack {
                            ProgressView()
                            Text("Refreshing…")
                        }
                    } else {
                        Label("Refresh Welcomes", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isRefreshingPendingWelcomes)
            }
        }
        .onAppear {
            viewModel.refreshConnections()
            Task {
                await viewModel.refreshPendingWelcomes()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .marmotStateDidChange)) { _ in
            guard viewModel.isUnlocked else { return }
            viewModel.refreshConnections()
            viewModel.refreshMarmotDiagnostics()
            Task {
                await viewModel.refreshPendingWelcomes()
            }
        }
    }

    private var librarySection: some View {
        insetGroupedList {
            Section("Family Library") {
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
                                Button("Export") {
                                    presentShare([viewModel.shareURL(for: video)])
                                }
                                Button("Send Secure Share") {
                                    prepareSharePrompt(with: video)
                                }
                                .disabled(!viewModel.canShareRemotely(video: video))
                                Button(role: .destructive) {
                                    viewModel.delete(video: video)
                                } label: {
                                    Text("Delete")
                                }
                            }
                            .font(.footnote)
                            if !viewModel.canShareRemotely(video: video) {
                                Text("Generate or import this child's key to enable secure sharing.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Button("Refresh Videos") {
                    viewModel.refreshVideos()
                }
            }
        }
    }

    private var storageSection: some View {
        insetGroupedList {
            Section("Storage Overview") {
                StorageMeterView(usage: viewModel.storageUsage)
                    .padding(.vertical, 8)

                Button("Refresh Storage") {
                    viewModel.storageBreakdown()
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Cloud Mode")
                        Spacer()
                        Text(viewModel.storageMode == .managed ? "Managed" : "Bring Your Own")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let entitlement = viewModel.entitlement {
                        storageEntitlementSummary(entitlement)
                    } else {
                        Text(viewModel.storageMode == .managed ?
                             "Start a free trial or refresh managed storage status when you're ready." :
                             "Switch to Managed storage to access the Tubestr cloud trial and managed uploads.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button(viewModel.entitlement == nil ? "Start Trial" : "Refresh Status") {
                            viewModel.refreshEntitlement(force: true)
                        }
                        .buttonStyle(KidPrimaryButtonStyle())
                        .disabled(viewModel.storageMode != .managed || viewModel.isRefreshingEntitlement)

                        if viewModel.isRefreshingEntitlement {
                            ProgressView()
                                .controlSize(.mini)
                        }

                        if viewModel.storageMode == .byo {
                            Button("Switch to Managed Storage") {
                                viewModel.activateManagedStorage()
                            }
                        }
                    }
                    .font(.footnote)
                }
                .padding(.vertical, 8)
            }

            if viewModel.storageMode == .managed {
                Section("Managed Backend") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("https://auth.tubestr.app", text: $viewModel.backendEndpoint)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)

                        Button("Apply Backend URL") {
                            viewModel.applyBackendEndpoint()
                        }
                        .buttonStyle(KidPrimaryButtonStyle())
                        .disabled(viewModel.backendEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Text("Used for NIP-98 auth, entitlement sync, and managed storage pre-sign requests.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Bring Your Own Storage") {
                DisclosureGroup("Credentials") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Use your own S3-compatible storage by supplying credentials below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("https://s3.example.com", text: $viewModel.byoEndpoint)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)

                        TextField("Bucket name", text: $viewModel.byoBucket)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)

                        TextField("Region (e.g. us-east-1)", text: $viewModel.byoRegion)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)

                        TextField("Access key", text: $viewModel.byoAccessKey)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)

                        SecureField("Secret key", text: $viewModel.byoSecretKey)

                        Toggle("Use path-style URLs", isOn: $viewModel.byoPathStyle)

                        Button("Apply BYO Storage") {
                            viewModel.activateBYOStorage()
                        }
                        .buttonStyle(KidPrimaryButtonStyle())

                        if viewModel.storageMode == .byo, !viewModel.byoEndpoint.isEmpty {
                            Text("Active endpoint: \(viewModel.byoEndpoint)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    private var safetySection: some View {
        insetGroupedList {
            Section("Inbound Reports") {
                let inbound = viewModel.inboundReports()
                if inbound.isEmpty {
                    Text("No one has reported your family's videos.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(inbound, id: \.id) { report in
                        inboundReportRow(report)
                    }
                }
            }

            Section("Outbound Reports") {
                let outbound = viewModel.outboundReports()
                if outbound.isEmpty {
                    Text("You haven't reported any shared videos yet. Incoming shares travel over Marmot groups.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(outbound, id: \.id) { report in
                        outboundReportRow(report)
                    }
                }
            }

            Section("Blocked Families") {
                let blocked = viewModel.followRelationships.filter { $0.status == .blocked }
                if blocked.isEmpty {
                    Text("No families are blocked.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(blocked, id: \.id) { follow in
                        blockedFamilyRow(follow)
                    }
                }
            }
        }
    }

    private var settingsSection: some View {
        insetGroupedList {
            Section("Relays") {
                if viewModel.relayEndpoints.isEmpty {
                    Text("Using default public relays.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.relayEndpoints) { endpoint in
                        relayStatusRow(for: endpoint)
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

            Section("Marmot Diagnostics") {
                LabeledContent {
                    Text("\(viewModel.marmotDiagnostics.groupCount)")
                        .font(.headline)
                } label: {
                    Label("Groups", systemImage: "person.3.sequence")
                        .font(.subheadline)
                }

                LabeledContent {
                    Text("\(viewModel.marmotDiagnostics.pendingWelcomes)")
                        .font(.headline)
                } label: {
                    Label("Pending welcomes", systemImage: "envelope.open")
                        .font(.subheadline)
                }

                Button {
                    viewModel.refreshMarmotDiagnostics()
                } label: {
                    if viewModel.isRefreshingMarmotDiagnostics {
                        HStack {
                            ProgressView()
                            Text("Refreshing…")
                        }
                    } else {
                        Label("Refresh Diagnostics", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isRefreshingMarmotDiagnostics)
            }

            Section("Maintenance") {
                Button(role: .destructive) {
                    showingResetAlert = true
                } label: {
                    Label("Reset App", systemImage: "arrow.counterclockwise.circle")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    private var childProfileActions: some View {
        HStack {
            Button {
                newChildName = ""
                newChildTheme = .ocean
                isAddingChild = true
            } label: {
                Label("Add Child", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(KidPrimaryButtonStyle())

            Button {
                importChildName = ""
                importChildSecret = ""
                importChildTheme = .ocean
                isImportingChild = true
            } label: {
                Label("Import Child", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func storageEntitlementSummary(_ entitlement: ParentZoneViewModel.CloudEntitlement) -> some View {
        let formatter = RelativeDateTimeFormatter()
        VStack(alignment: .leading, spacing: 4) {
            Label("\(entitlement.plan) • \(entitlement.statusLabel)", systemImage: entitlement.isActive ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(entitlement.isActive ? Color.accentColor : Color.orange)

            if let usage = entitlement.usageSummary {
                Text(usage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let expires = entitlement.expiresAt {
                Text("Renews \(formatter.localizedString(for: expires, relativeTo: Date()))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func inboundReportRow(_ report: ReportModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(report.reason.displayName)
                    .font(.headline)
                Spacer()
                Text(report.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Reporter: \(shortKey(report.reporterKey))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Status: \(reportStatusText(report.status))")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let note = report.note, !note.isEmpty {
                Text(note)
                    .font(.footnote)
            }

            HStack(spacing: 12) {
                Button("Mark Reviewed") {
                    viewModel.markReportReviewed(report)
                }
                .buttonStyle(.bordered)

                Button("Dismiss") {
                    viewModel.dismissReport(report)
                }
                .buttonStyle(.borderedProminent)
                .tint(.gray.opacity(0.2))
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func outboundReportRow(_ report: ReportModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(report.reason.displayName)
                    .font(.headline)
                Spacer()
                Text(report.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Subject child: \(shortKey(report.subjectChild))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Status: \(reportStatusText(report.status))")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let action = report.actionTaken, action != .none {
                Text("Action: \(reportActionText(action))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let note = report.note, !note.isEmpty {
                Text(note)
                    .font(.footnote)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func blockedFamilyRow(_ follow: FollowModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            let followerName = viewModel.followerProfile(for: follow)?.displayName ?? shortKey(follow.followerChild)
            let targetName = viewModel.targetProfile(for: follow)?.displayName ?? shortKey(follow.targetChild)

            Text("\(followerName) ↔︎ \(targetName)")
                .font(.headline)

            if let parentKey = viewModel.remoteParentKey(for: follow) {
                Text("Parent: \(shortKey(parentKey))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Updated \(follow.updatedAt, style: .relative)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button("Unblock") {
                viewModel.unblockFamily(for: follow)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private func reportStatusText(_ status: ReportStatus) -> String {
        switch status {
        case .pending: return "Pending"
        case .acknowledged: return "Reviewed"
        case .dismissed: return "Dismissed"
        case .actioned: return "Actioned"
        }
    }

    private func reportActionText(_ action: ReportAction) -> String {
        switch action {
        case .none, .reportOnly: return "Report only"
        case .unfollow: return "Unfollowed"
        case .block: return "Blocked"
        case .deleted: return "Deleted"
        }
    }

    @ViewBuilder
    func identityParentSection(parent: ParentIdentity) -> some View {
        let parentPublic = parent.publicKeyBech32 ?? parent.publicKeyHex
        let secret = parent.secretKeyBech32 ?? parent.keyPair.privateKeyData.hexEncodedString()

        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                QRCodeCard(
                    title: "Parent Public Key",
                    content: .text(label: "Parent npub", value: parentPublic),
                    footer: "Share with trusted parents so your kids can link families.",
                    copyAction: { copyToPasteboard(parentPublic) },
                    toggleSecure: nil,
                    qrValue: parentPublic,
                    showsShareButton: true,
                    shareAction: { presentShare([parentPublic]) }
                )

                QRCodeCard(
                    title: "Parent Secret Key",
                    content: .secure(
                        label: "Parent nsec",
                        value: secret,
                        revealed: viewModel.parentSecretVisible
                    ),
                    footer: "Keep this secret offline. It grants full access to this family.",
                    copyAction: { copyToPasteboard(secret) },
                    toggleSecure: { viewModel.toggleParentSecretVisibility() },
                    qrValue: viewModel.parentSecretVisible ? secret : nil,
                    showsShareButton: viewModel.parentSecretVisible,
                    shareAction: viewModel.parentSecretVisible ? { presentShare([secret]) } : nil
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Parent Profile")
                    .font(.headline)
                Text("Share a friendly name with your wrap key so trusted families can decrypt shared videos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Parent name", text: $parentProfileName)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
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
                    Text("Other parents will see this name when they connect with your family.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let profile = viewModel.parentProfile {
                    let formatter = RelativeDateTimeFormatter()
                    Text("Last published \(formatter.localizedString(for: profile.updatedAt, relativeTo: Date()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Button {
                    guard !isPublishingParentProfile else { return }
                    isPublishingParentProfile = true
                    let name = parentProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        defer { isPublishingParentProfile = false }
                        await viewModel.publishParentProfile(
                            name: name.isEmpty ? nil : name
                        )
                    }
                } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "paperplane.fill")
                                .imageScale(.medium)
                            Text("Publish Parent Profile")
                        }
                    }
                    .buttonStyle(KidPrimaryButtonStyle())
                    .disabled(isPublishingParentProfile)

                    if isPublishingParentProfile {
                        ProgressView()
                            .progressViewStyle(.circular)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    func identityChildSection(child: ParentZoneViewModel.ChildIdentityItem) -> some View {
        let isExpanded = expandedChildIDs.contains(child.id)

        VStack(alignment: .leading, spacing: 12) {
            Text(child.displayName)
                .font(.headline)

            if let summary = viewModel.groupSummary(for: child) {
                groupSummaryCard(summary: summary)
            } else {
                Text("Generate \(child.displayName)'s secure Marmot group to share invites.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let followInvite = viewModel.followInvite(for: child),
               let followURL = followInvite.encodedURL {
                let summary = "Parent: \(shortKey(followInvite.parentPublicKey))\nChild: \(shortKey(followInvite.childPublicKey))"
                    QRCodeCard(
                        title: "\(child.displayName) Marmot Invite",
                        content: .text(label: "Autofill Keys", value: summary),
                        footer: "Share once so the other parent gets both keys in a single scan for their Marmot invite.",
                    copyAction: { copyToPasteboard(followURL) },
                    toggleSecure: nil,
                    qrValue: followURL,
                    showsShareButton: true,
                    shareAction: { presentShare(followInvite.shareItems) }
                )
            }

            if isExpanded {
                Divider()

                if let npub = child.publicKey {
                    QRCodeCard(
                        title: "\(child.displayName) Public Key",
                        content: .text(label: "\(child.displayName) npub", value: npub),
                        footer: "Share this with approved families so they can join \(child.displayName)'s Marmot group.",
                        copyAction: { copyToPasteboard(npub) },
                        toggleSecure: nil,
                        qrValue: npub,
                        showsShareButton: true,
                        shareAction: { presentShare([npub]) }
                    )
                } else {
                    Text("No key created yet for this profile.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Generate Key") {
                        viewModel.generateChildKey(for: child.id)
                    }
                    .buttonStyle(.bordered)
                }

                if let secret = child.secretKey {
                    let revealed = viewModel.isChildSecretVisible(child.id)
                    QRCodeCard(
                        title: "\(child.displayName) Secret Key",
                        content: .secure(
                            label: "\(child.displayName) nsec",
                            value: secret,
                            revealed: revealed
                        ),
                        footer: "Reveal only when you need to import this child on another device.",
                        copyAction: { copyToPasteboard(secret) },
                        toggleSecure: { viewModel.toggleChildSecretVisibility(child.id) },
                        qrValue: revealed ? secret : nil,
                        showsShareButton: revealed,
                        shareAction: revealed ? { presentShare([secret]) } : nil
                    )
                }

                if let delegation = child.delegationTag {
                    QRCodeCard(
                        title: "\(child.displayName) Delegation",
                        content: .text(label: "Delegation Tag", value: delegation),
                        footer: "Provide to another device if it needs to verify this delegation.",
                        copyAction: { copyToPasteboard(delegation) },
                        toggleSecure: nil,
                        qrValue: delegation,
                        showsShareButton: true,
                        shareAction: { presentShare([delegation]) }
                    )
                }

                if let invite = viewModel.childDeviceInvite(for: child),
                   let inviteURL = invite.encodedURL {
                    QRCodeCard(
                        title: "\(child.displayName) Device Invite",
                        content: .text(label: "Invite Link", value: inviteURL),
                        footer: "Scan on the child's device to import keys, delegation, and connect to your family.",
                        copyAction: { copyToPasteboard(inviteURL) },
                        toggleSecure: nil,
                        qrValue: inviteURL,
                        showsShareButton: true,
                        shareAction: { presentShare(invite.shareItems) }
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    if let publishedName = child.publishedName {
                        Text("Published as \(publishedName)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let updated = child.metadataUpdatedAt {
                            Text("Last published \(updated, style: .relative)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Publish this profile so approved families see their name instead of an npub.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        viewModel.publishChildProfile(childId: child.id)
                    } label: {
                        if viewModel.isPublishingChild(child.id) {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                Text("Publishing…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Label("Publish Child Profile", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(KidPrimaryButtonStyle())
                    .disabled(viewModel.isPublishingChild(child.id) || child.identity == nil)
                }

                HStack {
                    if child.identity != nil {
                        Button("Reissue Delegation") {
                            viewModel.reissueDelegation(for: child.id)
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("Set Active") {
                        environment.switchProfile(child.profile)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }

            Button {
                if isExpanded {
                    expandedChildIDs.remove(child.id)
                } else {
                    expandedChildIDs.insert(child.id)
                }
            } label: {
                Label(isExpanded ? "Hide details" : "More…", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, 8)
    }

    private enum FollowRole {
        case incoming
        case outgoing
        case active
    }


    @ViewBuilder
    private func followSection(
        incoming: [FollowModel],
        outgoing: [FollowModel],
        active: [FollowModel]
    ) -> some View {
        if incoming.isEmpty && outgoing.isEmpty && active.isEmpty {
                Text("No Marmot connections yet. Share your child's invite with a family you trust to start a group.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            if !incoming.isEmpty {
                Text("Awaiting your approval")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(incoming, id: \.id) { follow in
                    followRow(follow, role: .incoming)
                }
            }

            if !outgoing.isEmpty {
                Text("Invites you sent")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(outgoing, id: \.id) { follow in
                    followRow(follow, role: .outgoing)
                }
            }

            if !active.isEmpty {
                Text("Active Marmot Families")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(active, id: \.id) { follow in
                    followRow(follow, role: .active)
                }
            }
        }
    }

    private func followRow(_ follow: FollowModel, role: FollowRole) -> some View {
        let followerItem = viewModel.followerProfile(for: follow)
        let targetItem = viewModel.targetProfile(for: follow)
        let localParentKeys = Set(
            [
                viewModel.parentIdentity?.publicKeyBech32?.lowercased(),
                viewModel.parentIdentity?.publicKeyHex.lowercased()
            ].compactMap { $0 }
        )

        let parentKey = viewModel.remoteParentKey(for: follow)
        let needsKeyPackages: Bool = {
            guard role == .incoming else { return false }
            guard let key = parentKey else { return true }
            return !viewModel.hasPendingKeyPackages(for: key)
        }()

        return VStack(alignment: .leading, spacing: 6) {
            switch role {
            case .incoming:
                let localName = targetItem?.displayName ?? "This child"
                Text("\(localName) ← \(shortKey(follow.followerChild))")
                    .font(.subheadline)
                Text("Waiting for you to accept the Marmot invite")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .outgoing:
                let localName = followerItem?.displayName ?? "This child"
                Text("\(localName) → \(shortKey(follow.targetChild))")
                    .font(.subheadline)
                Text("Waiting for the other parent to accept")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .active:
                let followerName = followerItem?.displayName ?? shortKey(follow.followerChild)
                let targetName = targetItem?.displayName ?? shortKey(follow.targetChild)
                Text("\(followerName) ↔︎ \(targetName)")
                    .font(.subheadline)
                Text("Families in this Marmot group can watch each other's shared videos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let summary = viewModel.groupSummary(for: follow) {
                groupSummaryCard(summary: summary)
            }

            if role == .active,
               let stats = viewModel.shareStats(for: follow) {
                remoteShareStatsCard(stats: stats)
            }

            if let parentKey,
               !localParentKeys.contains(parentKey.lowercased()) {
                Text("Parent: \(shortKey(parentKey))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if role == .incoming {
                if needsKeyPackages {
                    Text("Scan the other parent's Marmot invite to capture their key packages before approving.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        qrIntent = .followParent
                    } label: {
                        Label("Scan Invite", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if approvingFollowID == follow.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Approve") {
                        approvingFollowID = follow.id
                        Task {
                            defer { approvingFollowID = nil }
                            _ = await viewModel.approveFollow(follow)
                        }
                    }
                    .buttonStyle(KidPrimaryButtonStyle())
                    .controlSize(.small)
                    .disabled(needsKeyPackages)
                }
            }
        }
        .padding(.vertical, 4)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func groupSummaryCard(summary: ParentZoneViewModel.GroupSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(summary.displayName)
                    .font(.subheadline)
                Spacer()
                Text(summary.state.capitalized)
                    .font(.caption2)
                    .foregroundStyle(summary.isActive ? Color.green : Color.orange)
            }
            Text("\(summary.memberCount) member\(summary.memberCount == 1 ? "" : "s") • \(summary.relayCount) relay\(summary.relayCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let relative = relativeDateString(for: summary.lastMessageAt) {
                Text("Last activity \(relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    @ViewBuilder
    private func remoteShareStatsCard(stats: ParentZoneViewModel.RemoteShareStats) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if stats.hasAvailableShares {
                Text("\(stats.availableCount) shared \(stats.availableCount == 1 ? "video" : "videos") ready to play")
                    .font(.caption)
                    .foregroundStyle(.primary)
            } else {
                Text("No shared videos yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let relative = relativeDateString(for: stats.lastSharedAt) {
                Text("Last shared \(relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
    }

    private func relativeDateString(for date: Date?) -> String? {
        guard let date else { return nil }
        return ParentZoneView.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    func handleScanResult(_ rawValue: String, for intent: QRIntent) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let invite = ParentZoneViewModel.ChildDeviceInvite.decode(from: trimmed) {
            applyChildInvite(invite, for: intent)
            return
        }

        if (intent == .followChild || intent == .followParent),
           let followInvite = ParentZoneViewModel.FollowInvite.decode(from: trimmed) {
            applyFollowInvite(followInvite, rawValue: trimmed)
            return
        }

        switch intent {
        case .importChild:
            importChildSecret = trimmed

        case .followChild:
            let candidate = normalizedScannedKey(trimmed, validator: viewModel.isValidParentKey)
            followTargetChildKey = candidate
            followFormError = nil

        case .followParent:
            let candidate = normalizedScannedKey(trimmed, validator: viewModel.isValidParentKey)
            followTargetParentKey = candidate
            followSelectedParentKey = matchingParentOption(for: candidate, in: followParentOptions)
            followFormError = nil

        case .shareParent:
            let candidate = normalizedScannedKey(trimmed, validator: viewModel.isValidParentKey)
            if let match = matchingParentOption(for: candidate, in: shareParentOptions) {
                shareRecipient = match
                shareSelectedParentKey = match
            } else {
                shareRecipient = candidate
                shareSelectedParentKey = nil
            }
            shareStatusMessage = nil
            shareStatusIsError = false
        }
    }

    @ViewBuilder
    private func activeGroupRow(child: ParentZoneViewModel.ChildIdentityItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(child.displayName)
                .font(.headline)
            
            if let summary = viewModel.groupSummary(for: child) {
                groupSummaryCard(summary: summary)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func pendingWelcomeRow(_ welcome: ParentZoneViewModel.PendingWelcomeItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(welcome.groupName)
                        .font(.headline)
                    Text("Invited by \(shortKey(welcome.welcomerKey)) • \(welcome.memberCount) members")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.isProcessingWelcome(welcome) {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let description = welcome.groupDescription {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let relaySummary = welcome.relaySummary {
                Text("Relays: \(relaySummary)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if welcome.adminCount > 0 {
                Text("\(welcome.adminCount) admin\(welcome.adminCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Decline") {
                    Task {
                        await viewModel.declineWelcome(welcome)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isProcessingWelcome(welcome))

                Button("Accept") {
                    Task {
                        // Auto-link to first available child
                        await viewModel.acceptWelcome(welcome, linkToChildId: nil)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.isProcessingWelcome(welcome))
            }
        }
        .padding(.vertical, 4)
    }

    func applyChildInvite(_ invite: ParentZoneViewModel.ChildDeviceInvite, for intent: QRIntent) {
        switch intent {
        case .importChild:
            importChildSecret = invite.childSecretKey
            if importChildName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                importChildName = invite.childName
            }

        case .followChild:
            applyFollowInvite(
                ParentZoneViewModel.FollowInvite(
                    version: invite.version,
                    childName: invite.childName,
                    childPublicKey: invite.childPublicKey,
                    parentPublicKey: invite.parentPublicKey,
                    parentKeyPackages: nil
                )
            )

        case .followParent:
            applyFollowInvite(
                ParentZoneViewModel.FollowInvite(
                    version: invite.version,
                    childName: invite.childName,
                    childPublicKey: invite.childPublicKey,
                    parentPublicKey: invite.parentPublicKey,
                    parentKeyPackages: nil
                )
            )

        case .shareParent:
            if let match = matchingParentOption(for: invite.parentPublicKey, in: shareParentOptions) {
                shareRecipient = match
                shareSelectedParentKey = match
            } else {
                shareRecipient = invite.parentPublicKey
                shareSelectedParentKey = nil
            }
            shareStatusMessage = nil
            shareStatusIsError = false
        }
    }

    func applyFollowInvite(_ invite: ParentZoneViewModel.FollowInvite, rawValue: String? = nil) {
        followTargetChildKey = invite.childPublicKey
        followTargetParentKey = invite.parentPublicKey
        followSelectedParentKey = matchingParentOption(for: invite.parentPublicKey, in: followParentOptions)
        followFormError = nil
        if let encoded = invite.encodedURL {
            followInviteInput = encoded
        } else if let raw = rawValue, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            followInviteInput = raw
        }
        viewModel.storePendingKeyPackages(from: invite)
    }

    func normalizedScannedKey(_ rawValue: String, validator: (String) -> Bool) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if validator(trimmed) {
            return trimmed
        }

        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;|&?=<>\"'()[]{}:/\\"))
        let parts = trimmed.components(separatedBy: separators)
        for part in parts {
            let candidate = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if validator(candidate) {
                return candidate
            }
        }
        return trimmed
    }

    func matchingParentOption(for key: String, in options: [String]) -> String? {
        guard let scanned = ParentIdentityKey(string: key) else { return nil }
        return options.first { option in
            guard let normalizedOption = ParentIdentityKey(string: option) else { return false }
            return normalizedOption.hex.caseInsensitiveCompare(scanned.hex) == .orderedSame
        }
    }

    func sendShare(for video: VideoModel) {
        let recipient = shareRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recipient.isEmpty else {
            shareStatusMessage = "Enter the other parent's key."
            shareStatusIsError = true
            return
        }

        shareIsSending = true
        shareStatusMessage = nil
        shareStatusIsError = false

        Task {
            do {
                _ = try await viewModel.shareVideoRemotely(video: video, recipientPublicKey: recipient)
                await MainActor.run {
                    shareStatusMessage = "Shared securely with \(shortKey(recipient))."
                    shareStatusIsError = false
                    shareIsSending = false
                }
            } catch {
                await MainActor.run {
                    shareStatusMessage = error.localizedDescription
                    shareStatusIsError = true
                    shareIsSending = false
                }
            }
        }
    }

    func prepareSharePrompt(with video: VideoModel) {
        sharePromptVideo = video
        shareStatusMessage = nil
        shareStatusIsError = false
        shareIsSending = false
        shareSelectedParentKey = nil
        shareRecipient = ""

        shareParentOptions = viewModel.approvedParentKeys(forChild: video.profileId)
        if let first = shareParentOptions.first {
            shareSelectedParentKey = first
            shareRecipient = first
        }
    }

    func dismissSharePrompt() {
        sharePromptVideo = nil
        shareRecipient = ""
        shareSelectedParentKey = nil
        shareStatusMessage = nil
        shareStatusIsError = false
        shareIsSending = false
        shareParentOptions = []
    }

    func prepareFollowRequest() {
        followChildSelection = viewModel.childIdentities.first?.id
        followTargetChildKey = ""
        followTargetParentKey = ""
        followInviteInput = ""
        followSelectedParentKey = nil
        followParentOptions = []
        followFormError = nil
        followIsSubmitting = false
        isRequestingFollow = true
    }

    func dismissFollowRequest() {
        isRequestingFollow = false
        followChildSelection = nil
        followTargetChildKey = ""
        followTargetParentKey = ""
        followInviteInput = ""
        followSelectedParentKey = nil
        followParentOptions = []
        followFormError = nil
        followIsSubmitting = false
    }

    func parseFollowInviteInput() {
        let trimmed = followInviteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let invite = ParentZoneViewModel.FollowInvite.decode(from: trimmed) else { return }
        applyFollowInvite(invite, rawValue: trimmed)
        if let encoded = invite.encodedURL, encoded != followInviteInput {
            followInviteInput = encoded
        }
    }

    func pasteFollowInviteFromClipboard() {
        guard let string = UIPasteboard.general.string else { return }
        followInviteInput = string
        parseFollowInviteInput()
    }

    func copyToPasteboard(_ value: String) {
        UIPasteboard.general.string = value
    }

    func presentShare(_ items: [Any]) {
        sharePayload = items
    }

    func shortKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else { return trimmed }
        let prefix = trimmed.prefix(6)
        let suffix = trimmed.suffix(6)
        return "\(prefix)…\(suffix)"
    }

    func syncParentProfileFields(with profile: ParentProfileModel?) {
        guard !isPublishingParentProfile else { return }
        if let profile {
            parentProfileName = (profile.displayName?.isEmpty == false ? profile.displayName : profile.name) ?? ""
        } else {
            parentProfileName = ""
        }
    }

    func resetChildCreationState() {
        newChildName = ""
        newChildTheme = .ocean
        isAddingChild = false
    }

    func resetChildImportState() {
        importChildName = ""
        importChildSecret = ""
        importChildTheme = .ocean
        isImportingChild = false
    }
}

private enum FamilyViewSelection: String, CaseIterable, Identifiable {
    case parent
    case children

    var id: Self { self }

    var title: String {
        switch self {
        case .parent: return "Parent"
        case .children: return "Children"
        }
    }
}

private enum ParentZoneSection: String, CaseIterable, Identifiable {
    case overview
    case family
    case connections
    case library
    case storage
    case safety
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .family: return "Family"
        case .connections: return "Connections"
        case .library: return "Library"
        case .storage: return "Storage"
        case .safety: return "Safety"
        case .settings: return "Settings"
        }
    }
}

private enum QRIntent: Identifiable {
    case importChild
    case followParent
    case followChild
    case shareParent

    var id: String {
        switch self {
        case .importChild: return "importChild"
        case .followParent: return "followParent"
        case .followChild: return "followChild"
        case .shareParent: return "shareParent"
        }
    }

    var title: String {
        switch self {
        case .importChild:
            return "Scan Child nsec"
        case .followParent:
            return "Scan Parent npub"
        case .followChild:
            return "Scan Child npub"
        case .shareParent:
            return "Scan Parent npub"
        }
    }
}

private struct ChildProfileFormSheet: View {
    let title: String
    @Binding var name: String
    @Binding var theme: ThemeDescriptor
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                    Picker("Theme", selection: $theme) {
                        ForEach(ThemeDescriptor.allCases, id: \.self) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct ChildImportFormSheet: View {
    @Binding var name: String
    @Binding var secret: String
    @Binding var theme: ThemeDescriptor
    let onScan: () -> Void
    let onCancel: () -> Void
    let onImport: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                    Picker("Theme", selection: $theme) {
                        ForEach(ThemeDescriptor.allCases, id: \.self) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                }

                Section("Child nsec") {
                    TextField("nsec1...", text: $secret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Scan QR", action: onScan)
                }
            }
            .navigationTitle("Import Child Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: onImport)
                        .disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct QRScannerSheet: View {
    let title: String
    let onResult: (String) -> Void
    let onCancel: () -> Void

    @State private var isHandlingCode = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            QRCodeScannerView { value in
                guard !isHandlingCode else { return }
                isHandlingCode = true
                DispatchQueue.main.async {
                    onResult(value)
                }
            }

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .padding()
            }
        }
        .overlay(alignment: .topLeading) {
            Text(title)
                .font(.headline)
                .padding()
                .background(.ultraThinMaterial, in: Capsule())
                .padding()
        }
        .ignoresSafeArea()
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
