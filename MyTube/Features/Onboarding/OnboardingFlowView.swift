//
//  OnboardingFlowView.swift
//  MyTube
//
//  Created by Codex on 11/06/25.
//

import SwiftUI
import UIKit

struct OnboardingFlowView: View {
    @StateObject private var viewModel: ViewModel
    @State private var introSelection = 0
    @State private var qrIntent: QRIntent?
    @State private var isPresentingParentProfile = false
    @State private var parentProfileName = ""
    @State private var isPublishingParentProfile = false
    @State private var parentProfileSheetError: String?
    @State private var isPresentingNewChild = false
    @State private var newChildName = ""
    @State private var newChildTheme: ThemeDescriptor = .ocean
    @State private var isCreatingChild = false
    @State private var childCreationError: String?
    @State private var isPresentingImportChild = false
    @State private var importChildName = ""
    @State private var importChildSecret = ""
    @State private var importChildTheme: ThemeDescriptor = .ocean
    private let introSlides = IntroSlide.slides

    init(environment: AppEnvironment) {
        _viewModel = StateObject(wrappedValue: ViewModel(environment: environment))
    }

    var body: some View {
        Group {
            if viewModel.step == .introduction {
                introductionStep
            } else {
                onboardingNavigation
            }
        }
        .onAppear { viewModel.start() }
        .onChange(of: viewModel.step) { newValue in
            if newValue == .introduction {
                introSelection = 0
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
        .sheet(isPresented: $isPresentingParentProfile) {
            ParentProfileOnboardingSheet(
                name: $parentProfileName,
                isSubmitting: isPublishingParentProfile,
                errorMessage: parentProfileSheetError,
                onSubmit: handleParentProfileSubmit
            )
            .interactiveDismissDisabled(isPublishingParentProfile)
        }
        .sheet(isPresented: $isPresentingNewChild) {
            ChildProfileSheet(
                title: "Add Child Profile",
                name: $newChildName,
                theme: $newChildTheme,
                isSubmitting: isCreatingChild,
                errorMessage: childCreationError,
                onCancel: {
                    resetChildCreationState()
                },
                onSave: handleChildCreation
            )
        }
        .sheet(isPresented: $isPresentingImportChild) {
            ChildImportSheet(
                name: $importChildName,
                secret: $importChildSecret,
                theme: $importChildTheme,
                onScan: {
                    qrIntent = .parentChildImport
                },
                onCancel: {
                    resetChildImportState()
                },
                onImport: {
                    viewModel.importChildForParent(
                        name: importChildName,
                        secret: importChildSecret,
                        theme: importChildTheme
                    )
                    resetChildImportState()
                }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.step {
        case .introduction:
            EmptyView()
        case .roleSelection:
            roleSelectionStep
        case .parentKey(let mode):
            parentKeyStep(mode: mode)
        case .parentChildSetup:
            parentChildSetupStep
        case .childImport:
            childImportStep
        case .ready:
            completionStep
        }
    }

    private var onboardingNavigation: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                content

                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }
            }
            .padding()
            .navigationTitle(viewModel.navigationTitle)
            .toolbar {
                if viewModel.canGoBack {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back") {
                            viewModel.goBack()
                        }
                    }
                }
            }
        }
    }

    private var introductionStep: some View {
        GeometryReader { proxy in
            ZStack {
                TabView(selection: $introSelection) {
                    ForEach(Array(introSlides.enumerated()), id: \.offset) { index, slide in
                        IntroSlideView(
                            slide: slide,
                            safeAreaInsets: proxy.safeAreaInsets
                        )
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.3), value: introSelection)
                .background(Color.clear)
                .ignoresSafeArea()

                VStack {
                    HStack {
                        Button {
                            viewModel.advanceFromIntroduction()
                        } label: {
                            Text("Skip")
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.15), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, proxy.safeAreaInsets.top + 12)

                    Spacer()

                    VStack(spacing: 24) {
                        HStack(spacing: 8) {
                            ForEach(0..<introSlides.count, id: \.self) { index in
                                Capsule()
                                    .fill(index == introSelection ? Color.white : Color.white.opacity(0.3))
                                    .frame(width: index == introSelection ? 32 : 12, height: 4)
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: introSelection)

                        Button {
                            if introSelection < introSlides.count - 1 {
                                withAnimation(.easeInOut) {
                                    introSelection += 1
                                }
                            } else {
                                viewModel.advanceFromIntroduction()
                            }
                        } label: {
                            Text(introSelection == introSlides.count - 1 ? "Start Setup" : "Next")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Color.white)
                                )
                                .shadow(color: Color.black.opacity(0.15), radius: 12, y: 8)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.black)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, proxy.safeAreaInsets.bottom + 32)
                }
            }
            .ignoresSafeArea()
        }
    }

    private var roleSelectionStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Welcome to Tubestr")
                    .font(.largeTitle.weight(.bold))
                Text("Choose how you want to get started. You can set up a new family, bring an existing parent account to this iPad, or add a child device using a delegated key.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 16) {
                Button {
                    viewModel.startParentSetup(mode: .new)
                    if viewModel.parentIdentity != nil {
                        parentProfileName = suggestedParentName()
                        parentProfileSheetError = nil
                        isPublishingParentProfile = false
                        isPresentingNewChild = false
                        isCreatingChild = false
                        isPresentingParentProfile = true
                    }
                } label: {
                    Label("I'm a new parent", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    viewModel.startParentSetup(mode: .existing)
                } label: {
                    Label("I'm an existing parent", systemImage: "key.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    viewModel.startChildImport()
                } label: {
                    Label("Import a child device", systemImage: "person.2.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
            }
        }
    }

    private func parentKeyStep(mode: ViewModel.ParentMode) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(mode == .new ? "Create Parent Identity" : "Import Parent Identity")
                    .font(.title.bold())

                Text(mode == .new
                     ? "Parents hold the master key that signs delegations and approvals. We're creating a fresh secure key for you now—store the nsec safely once it appears."
                     : "Paste or scan your parent nsec to bring your account onto this device. We'll keep it secured in the keychain.")
                    .foregroundStyle(.secondary)

                if let parent = viewModel.parentIdentity {
                    IdentityCard(
                        title: "Parent npub",
                        value: parent.publicKeyBech32 ?? parent.publicKeyHex,
                        subtitle: "Share with trusted adults to link families."
                    )

                    let secret = parent.secretKeyBech32 ?? parent.keyPair.privateKeyData.hexEncodedString()
                    SecureValueCard(
                        title: "Parent nsec",
                        value: secret,
                        isRevealed: viewModel.parentSecretVisible,
                        toggle: { viewModel.toggleParentSecretVisibility() },
                        copyAction: { viewModel.copyToPasteboard(secret) }
                    )

                    if viewModel.parentProfile == nil {
                        Button {
                            parentProfileName = suggestedParentName()
                            parentProfileSheetError = nil
                            isPublishingParentProfile = false
                            isPresentingParentProfile = true
                        } label: {
                            Label("Publish Parent Profile", systemImage: "person.crop.circle.badge.checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }

                    Button {
                        viewModel.advanceToChildSetup()
                    } label: {
                        Text("Continue to Child Profiles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.parentProfile == nil)
                } else {
                    if mode == .new {
                        VStack(spacing: 16) {
                            ProgressView()
                                .progressViewStyle(.circular)
                            Text("Preparing your secure parent key…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Paste your nsec below or scan it from another device.")
                                .foregroundStyle(.secondary)

                            TextField("nsec1...", text: $viewModel.parentSecretInput)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(.footnote).monospaced())
                                .textFieldStyle(.roundedBorder)

                            HStack {
                                Button {
                                    qrIntent = .parentSecret
                                } label: {
                                    Label("Scan QR", systemImage: "qrcode.viewfinder")
                                }
                                Button {
                                    viewModel.importParentIdentity()
                                } label: {
                                    Text("Import nsec")
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    private var parentChildSetupStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Child Profiles & Delegated Keys")
                    .font(.title.bold())

                Text("Each child gets their own Tubestr profile with a delegated key. Share the nsec (and optional delegation tag) with the child’s iPad by scanning or copying.")
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        newChildName = ""
                        newChildTheme = .ocean
                        isPresentingNewChild = true
                    } label: {
                        Label("Add Child Profile", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        importChildName = ""
                        importChildSecret = ""
                        importChildTheme = .ocean
                        isPresentingImportChild = true
                    } label: {
                        Label("Import Child Key", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if viewModel.childEntries.isEmpty {
                    Text("No child keys yet. Add at least one profile to finish setup.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 16) {
                        ForEach(viewModel.childEntries) { entry in
                            ChildIdentityCard(
                                entry: entry,
                                isSecretVisible: viewModel.isChildSecretVisible(entry.id),
                                toggleSecret: { viewModel.toggleChildSecretVisibility(entry.id) },
                                copySecret: {
                                    if let secret = entry.secretKey {
                                        viewModel.copyToPasteboard(secret)
                                    }
                                },
                                copyDelegation: {
                                    if let tag = entry.delegationTagDisplay {
                                        viewModel.copyToPasteboard(tag)
                                    }
                                }
                            )
                        }
                    }
                }

                Button {
                    viewModel.finishParentFlow()
                } label: {
                    Text("Finish Parent Setup")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.childEntries.isEmpty)
            }
        }
    }

    private var childImportStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Import Child Device")
                    .font(.title.bold())
                Text("Paste or scan the delegated child nsec provided by your parent. We'll create a profile on this device using that key.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Child name")
                        .font(.headline)
                    TextField("e.g. Riley", text: $viewModel.childImportName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Child nsec")
                        .font(.headline)
                    TextField("nsec1...", text: $viewModel.childImportSecret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote).monospaced())
                        .textFieldStyle(.roundedBorder)

                    Button {
                        qrIntent = .childDeviceImport
                    } label: {
                        Label("Scan QR", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Theme")
                        .font(.headline)
                    Picker("Theme", selection: $viewModel.childImportTheme) {
                        ForEach(ThemeDescriptor.allCases, id: \.self) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Button {
                    viewModel.importChildDevice()
                } label: {
                    Text("Import Child Key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var completionStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            Text("All Set!")
                .font(.largeTitle.weight(.semibold))
            Text("Keys are secured and profiles are ready. Head to Parent Zone anytime to manage identities or export delegations.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func handleScanResult(_ value: String, for intent: QRIntent) {
        switch intent {
        case .parentSecret:
            viewModel.parentSecretInput = value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .parentChildImport:
            importChildSecret = value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .childDeviceImport:
            viewModel.childImportSecret = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func resetChildCreationState() {
        newChildName = ""
        newChildTheme = .ocean
        childCreationError = nil
        isCreatingChild = false
        isPresentingNewChild = false
    }

    private func resetChildImportState() {
        importChildName = ""
        importChildSecret = ""
        importChildTheme = .ocean
        isPresentingImportChild = false
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.leading)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.1)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.red.opacity(0.3))
        )
    }

    private func handleParentProfileSubmit() {
        let trimmed = parentProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            parentProfileSheetError = "Enter your name to continue."
            return
        }
        parentProfileSheetError = nil

        Task { @MainActor in
            isPublishingParentProfile = true
            let error = await viewModel.publishParentProfile(name: trimmed)
            isPublishingParentProfile = false
            if let error {
                parentProfileSheetError = error
            } else {
                parentProfileSheetError = nil
                parentProfileName = trimmed
                isPresentingParentProfile = false
                resetChildCreationState()
                isPresentingNewChild = true
            }
        }
    }

    private func handleChildCreation() {
        let trimmed = newChildName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            childCreationError = "Enter a name for the child profile."
            return
        }
        newChildName = trimmed
        childCreationError = nil

        Task { @MainActor in
            isCreatingChild = true
            let error = await viewModel.createChild(name: trimmed, theme: newChildTheme)
            isCreatingChild = false
            if let error {
                childCreationError = error
            } else {
                childCreationError = nil
                resetChildCreationState()
            }
        }
    }

    private func suggestedParentName() -> String {
        if let profile = viewModel.parentProfile {
            if let displayName = profile.displayName, !displayName.isEmpty {
                return displayName
            }
            if let name = profile.name, !name.isEmpty {
                return name
            }
        }
        return UIDevice.current.name
    }
}

// MARK: - View Model

extension OnboardingFlowView {
    @MainActor
    final class ViewModel: ObservableObject {
        enum Step: Equatable {
            case introduction
            case roleSelection
            case parentKey(ParentMode)
            case parentChildSetup
            case childImport
            case ready
        }

        enum ParentMode: Equatable {
            case new
            case existing
        }

        @Published var step: Step = .introduction
        @Published var parentIdentity: ParentIdentity?
        @Published var parentProfile: ParentProfileModel?
        @Published var parentSecretInput: String = ""
        @Published var parentSecretVisible = false
        @Published var childEntries: [ChildEntry] = []
        @Published var childSecretVisibility: Set<UUID> = []
        @Published var errorMessage: String?
        @Published var childImportName: String = ""
        @Published var childImportSecret: String = ""
        @Published var childImportTheme: ThemeDescriptor = .ocean

        var navigationTitle: String {
            switch step {
            case .introduction:
                return ""
            case .roleSelection:
                return "Welcome"
            case .parentKey(let mode):
                return mode == .new ? "Parent Key" : "Import Parent Key"
            case .parentChildSetup:
                return "Child Keys"
            case .childImport:
                return "Import Child"
            case .ready:
                return "Done"
            }
        }

        var canGoBack: Bool {
            switch step {
            case .introduction, .roleSelection, .ready:
                return false
            default:
                return true
            }
        }

        private let environment: AppEnvironment
        private var parentMode: ParentMode?
        private var delegationCache: [UUID: ChildDelegation] = [:]
        private var lastCreatedChildID: UUID?

        init(environment: AppEnvironment) {
            self.environment = environment
        }

        func start() {
            do {
                if let parent = try environment.identityManager.parentIdentity() {
                    parentIdentity = parent
                    parentMode = .existing
                    parentProfile = try environment.parentProfileStore.profile(for: parent.publicKeyHex)
                    step = .parentChildSetup
                    refreshChildEntries()
                } else {
                    parentProfile = nil
                    step = .introduction
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        func goBack() {
            errorMessage = nil
            parentMode = nil
            step = .roleSelection
        }

        func advanceFromIntroduction() {
            errorMessage = nil
            step = .roleSelection
        }

        func startParentSetup(mode: ParentMode) {
            parentMode = mode
            parentIdentity = nil
            parentProfile = nil
            parentSecretInput = ""
            parentSecretVisible = false
            errorMessage = nil
            step = .parentKey(mode)
            if mode == .new {
                generateParentIdentity()
            }
        }

        func startChildImport() {
            errorMessage = nil
            childImportName = ""
            childImportSecret = ""
            childImportTheme = .ocean
            step = .childImport
        }

        func generateParentIdentity() {
            do {
                parentIdentity = try environment.identityManager.generateParentIdentity(requireBiometrics: false)
                parentProfile = nil
                parentSecretInput = ""
                parentSecretVisible = false
                errorMessage = nil
                Task {
                    await environment.syncCoordinator.refreshSubscriptions()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        func importParentIdentity() {
            do {
                parentIdentity = try environment.identityManager.importParentIdentity(parentSecretInput, requireBiometrics: false)
                if let parentIdentity {
                    parentProfile = try environment.parentProfileStore.profile(for: parentIdentity.publicKeyHex)
                } else {
                    parentProfile = nil
                }
                parentSecretInput = ""
                parentSecretVisible = false
                errorMessage = nil
                Task {
                    await environment.syncCoordinator.refreshSubscriptions()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        func advanceToChildSetup() {
            guard parentIdentity != nil else {
                errorMessage = "Create or import a parent key first."
                return
            }
            errorMessage = nil
            step = .parentChildSetup
            refreshChildEntries()
        }

        func toggleParentSecretVisibility() {
            parentSecretVisible.toggle()
        }

        func isChildSecretVisible(_ id: UUID) -> Bool {
            childSecretVisibility.contains(id)
        }

        func toggleChildSecretVisibility(_ id: UUID) {
            if childSecretVisibility.contains(id) {
                childSecretVisibility.remove(id)
            } else {
                childSecretVisibility.insert(id)
            }
        }

        @discardableResult
        func createChild(name: String, theme: ThemeDescriptor) async -> String? {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                let message = "Enter a name for the child profile."
                errorMessage = message
                return message
            }
            guard parentIdentity != nil else {
                let message = "Generate or import the parent key first."
                errorMessage = message
                return message
            }

            var identity: ChildIdentity
            if let existing = childEntries.first(where: { $0.profile.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                identity = existing.identity
            } else {
                do {
                    var created = try environment.identityManager.createChildIdentity(
                        name: trimmed,
                        theme: theme,
                        avatarAsset: theme.defaultAvatarAsset
                    )
                    if let delegation = created.delegation {
                        delegationCache[created.profile.id] = delegation
                    }
                    let wasEmpty = childEntries.isEmpty
                    upsertChildEntry(created, delegation: created.delegation)
                    if wasEmpty {
                        environment.switchProfile(created.profile)
                    }
                    Task {
                        await environment.syncCoordinator.refreshSubscriptions()
                    }
                    identity = created
                } catch {
                    let message = error.localizedDescription
                    errorMessage = message
                    return message
                }
            }

            childSecretVisibility.insert(identity.profile.id)
            lastCreatedChildID = identity.profile.id

            do {
                _ = try await environment.childProfilePublisher.publishProfile(
                    for: identity.profile,
                    identity: identity,
                    nameOverride: trimmed
                )
                refreshChildEntries()
                errorMessage = nil
                Task {
                    await environment.syncCoordinator.refreshSubscriptions()
                }
                return nil
            } catch {
                let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                errorMessage = description
                return description
            }
        }

        func importChildForParent(name: String, secret: String, theme: ThemeDescriptor) {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmedName.isEmpty else {
                errorMessage = "Enter a name for the child profile."
                return
            }
            guard !trimmedSecret.isEmpty else {
                errorMessage = "Paste the child nsec before importing."
                return
            }
            guard parentIdentity != nil else {
                errorMessage = "Import or generate the parent key first."
                return
            }

            do {
                var identity = try environment.identityManager.importChildIdentity(
                    trimmedSecret,
                    profileName: trimmedName,
                    theme: theme,
                    avatarAsset: theme.defaultAvatarAsset
                )
                let delegation = try environment.identityManager.issueDelegation(
                    to: identity,
                    conditions: DelegationConditions.defaultChild()
                )
                identity.delegation = delegation
                delegationCache[identity.profile.id] = delegation
                upsertChildEntry(identity, delegation: delegation)
                childSecretVisibility.insert(identity.profile.id)
                lastCreatedChildID = identity.profile.id
                if childEntries.count == 1 {
                    environment.switchProfile(identity.profile)
                }
                errorMessage = nil
                Task {
                    await environment.syncCoordinator.refreshSubscriptions()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        func finishParentFlow() {
            guard !childEntries.isEmpty else {
                errorMessage = "Add at least one child profile before finishing."
                return
            }

            let targetProfile: ProfileModel
            if let lastID = lastCreatedChildID,
               let entry = childEntries.first(where: { $0.id == lastID }) {
                targetProfile = entry.profile
            } else if let first = childEntries.first {
                targetProfile = first.profile
            } else {
                errorMessage = "Unable to determine active profile."
                return
            }

            environment.switchProfile(targetProfile)
            environment.completeOnboarding()
            step = .ready
            errorMessage = nil
        }

        func importChildDevice() {
            let trimmedName = childImportName.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedSecret = childImportSecret.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmedName.isEmpty else {
                errorMessage = "Enter the child's name."
                return
            }
            guard !trimmedSecret.isEmpty else {
                errorMessage = "Paste or scan the child nsec to continue."
                return
            }

            do {
                let identity = try environment.identityManager.importChildIdentity(
                    trimmedSecret,
                    profileName: trimmedName,
                    theme: childImportTheme,
                    avatarAsset: childImportTheme.defaultAvatarAsset
                )
                environment.switchProfile(identity.profile)
                environment.completeOnboarding()
                step = .ready
                errorMessage = nil
                Task {
                    await environment.syncCoordinator.refreshSubscriptions()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        func copyToPasteboard(_ value: String) {
            UIPasteboard.general.string = value
        }

        @discardableResult
        func publishParentProfile(name: String, displayName: String? = nil) async -> String? {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                let message = "Enter your name to continue."
                errorMessage = message
                return message
            }
            guard parentIdentity != nil else {
                let message = "Generate the parent key before continuing."
                errorMessage = message
                return message
            }

            do {
                guard await ensureRelayConnection() else {
                    let message = "Connect to a relay before publishing your parent profile."
                    errorMessage = message
                    return message
                }

                let cleanedDisplay: String
                if let provided = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !provided.isEmpty {
                    cleanedDisplay = provided
                } else {
                    cleanedDisplay = trimmed
                }

                let model = try await environment.parentProfilePublisher.publishProfile(
                    name: trimmed,
                    displayName: cleanedDisplay,
                    about: nil,
                    pictureURL: nil
                )
                parentProfile = model
                if let refreshed = try environment.identityManager.parentIdentity() {
                    parentIdentity = refreshed
                }
                errorMessage = nil
                advanceToChildSetup()
                Task {
                    await environment.syncCoordinator.refreshSubscriptions()
                }
                return nil
            } catch {
                let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                errorMessage = description
                return description
            }
        }

        private func refreshChildEntries() {
            do {
                let identities = try environment.identityManager.allChildIdentities()
                childEntries = identities.map { identity in
                    let delegation = delegationCache[identity.profile.id]
                    return ChildEntry(identity: identity, delegation: delegation)
                }
                childEntries.sort { lhs, rhs in
                    lhs.profile.name.localizedCaseInsensitiveCompare(rhs.profile.name) == .orderedAscending
                }
                let ids = Set(childEntries.map(\.id))
                childSecretVisibility = childSecretVisibility.intersection(ids)
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        private func upsertChildEntry(_ identity: ChildIdentity, delegation: ChildDelegation?) {
            let entry = ChildEntry(identity: identity, delegation: delegation)
            if let index = childEntries.firstIndex(where: { $0.id == entry.id }) {
                childEntries[index] = entry
            } else {
                childEntries.append(entry)
            }
            childEntries.sort { lhs, rhs in
                lhs.profile.name.localizedCaseInsensitiveCompare(rhs.profile.name) == .orderedAscending
            }
        }

        private func ensureRelayConnection(
            timeout: TimeInterval = 6,
            pollInterval: TimeInterval = 0.5
        ) async -> Bool {
            await environment.syncCoordinator.refreshRelays()
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let statuses = await environment.syncCoordinator.relayStatuses()
                if statuses.contains(where: { $0.status == .connected }) {
                    return true
                }
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            }
            return false
        }

        struct ChildEntry: Identifiable {
            let identity: ChildIdentity
            let delegation: ChildDelegation?

            var id: UUID { identity.profile.id }
            var profile: ProfileModel { identity.profile }

            var publicKey: String {
                identity.publicKeyBech32 ?? identity.publicKeyHex
            }

            var secretKey: String? {
                identity.secretKeyBech32 ?? identity.keyPair.privateKeyData.hexEncodedString()
            }

            var delegationTagDisplay: String? {
                guard let tag = delegation?.nostrTag else { return nil }
                let formatted = ([tag.name, tag.value] + tag.otherParameters).joined(separator: ", ")
                return "[\(formatted)]"
            }
        }
    }
}

// MARK: - Supporting Views & Helpers

private struct IntroSlideView: View {
    let slide: IntroSlide
    let safeAreaInsets: EdgeInsets

    var body: some View {
        ZStack {
            LinearGradient(
                colors: slide.gradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tubestr")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Playful video sharing for trusted families")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.top, safeAreaInsets.top + 24)
                .padding(.horizontal, 28)

                Spacer()

                VStack(spacing: 28) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 220, height: 220)
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            .frame(width: 256, height: 256)
                        Circle()
                            .fill(slide.accent.opacity(0.35))
                            .frame(width: 180, height: 180)
                        Image(systemName: slide.iconName)
                            .font(.system(size: 76, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.22), radius: 10, y: 8)
                    }

                    VStack(spacing: 16) {
                        Text(slide.title)
                            .font(.system(size: 34, weight: .bold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.15), radius: 6, y: 4)

                        Text(slide.subtitle)
                            .font(.system(size: 18, weight: .medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.88))
                            .padding(.horizontal, 12)
                    }
                    .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity)

                Spacer()
            }
        }
    }
}

private struct IntroSlide {
    let title: String
    let subtitle: String
    let iconName: String
    let accent: Color
    let gradient: [Color]

    static let slides: [IntroSlide] = [
        IntroSlide(
            title: "Curated For Kids",
            subtitle: "Browse a hand-picked library of age-appropriate videos tuned for discovery and delight.",
            iconName: "sparkles.rectangle.stack",
            accent: Color(red: 1.0, green: 0.82, blue: 0.58),
            gradient: [
                Color(red: 0.99, green: 0.69, blue: 0.36),
                Color(red: 0.91, green: 0.29, blue: 0.42)
            ]
        ),
        IntroSlide(
            title: "Create Magical Moments",
            subtitle: "Capture, edit, and remix family clips with playful tools that keep kids in the loop.",
            iconName: "wand.and.stars",
            accent: Color(red: 1.0, green: 0.75, blue: 0.88),
            gradient: [
                Color(red: 0.86, green: 0.32, blue: 0.58),
                Color(red: 0.59, green: 0.29, blue: 0.89)
            ]
        ),
        IntroSlide(
            title: "Stay In Control",
            subtitle: "Approve follows, manage profiles, and share safely from the Parent Zone whenever you need.",
            iconName: "shield.lefthalf.fill",
            accent: Color(red: 0.46, green: 0.94, blue: 0.87),
            gradient: [
                Color(red: 0.22, green: 0.65, blue: 0.85),
                Color(red: 0.19, green: 0.31, blue: 0.52)
            ]
        ),
        IntroSlide(
            title: "Private By Design",
            subtitle: "Link trusted devices with secure follow invites that pair parent and child keys automatically.",
            iconName: "qrcode.viewfinder",
            accent: Color(red: 0.78, green: 0.86, blue: 1.0),
            gradient: [
                Color(red: 0.37, green: 0.47, blue: 0.94),
                Color(red: 0.20, green: 0.24, blue: 0.52)
            ]
        )
    ]
}

private struct ChildIdentityCard: View {
    let entry: OnboardingFlowView.ViewModel.ChildEntry
    let isSecretVisible: Bool
    let toggleSecret: () -> Void
    let copySecret: () -> Void
    let copyDelegation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.profile.name)
                .font(.headline)

            IdentityCard(
                title: "npub",
                value: entry.publicKey,
                subtitle: "Share with followers and relatives."
            )

            if let secret = entry.secretKey {
                SecureValueCard(
                    title: "nsec",
                    value: secret,
                    isRevealed: isSecretVisible,
                    toggle: toggleSecret,
                    copyAction: copySecret
                )
            }

            if let delegation = entry.delegationTagDisplay {
                DelegationCard(
                    value: delegation,
                    copyAction: copyDelegation
                )
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }
}

private struct DelegationCard: View {
    let value: String
    let copyAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Delegation Tag")
                .font(.headline)
            Text(value)
                .font(.system(.footnote).monospaced())
                .textSelection(.enabled)
            Button("Copy delegation") {
                copyAction()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

private struct ParentProfileOnboardingSheet: View {
    @Binding var name: String
    let isSubmitting: Bool
    let errorMessage: String?
    let onSubmit: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Parent name", text: $name)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                        .disabled(isSubmitting)
                        .submitLabel(.done)
                        .onSubmit(onSubmit)
                } header: {
                    Text("Introduce yourself")
                } footer: {
                    Text("Publishing your parent profile stores the wrap key trusted families use to decrypt shared videos.")
                }

                if let message = errorMessage, !message.isEmpty {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                    }
                }
            }
            .navigationTitle("Parent Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "Publishing…" : "Continue") {
                        onSubmit()
                    }
                    .disabled(isSubmitting || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .overlay {
                if isSubmitting {
                    ProgressView("Publishing…")
                        .progressViewStyle(.circular)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.systemBackground))
                                .shadow(radius: 10)
                        )
                }
            }
        }
    }
}

private struct ChildProfileSheet: View {
    let title: String
    @Binding var name: String
    @Binding var theme: ThemeDescriptor
    let isSubmitting: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                        .disabled(isSubmitting)
                        .submitLabel(.done)
                        .onSubmit(onSave)
                    Picker("Theme", selection: $theme) {
                        ForEach(ThemeDescriptor.allCases, id: \.self) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .disabled(isSubmitting)
                }
                if let message = errorMessage, !message.isEmpty {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave()
                    }
                    .disabled(isSubmitting || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .overlay {
                if isSubmitting {
                    ProgressView("Creating…")
                        .progressViewStyle(.circular)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.systemBackground))
                                .shadow(radius: 10)
                        )
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct ChildImportSheet: View {
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

    @State private var isHandlingResult = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            QRCodeScannerView { code in
                guard !isHandlingResult else { return }
                isHandlingResult = true
                DispatchQueue.main.async {
                    onResult(code)
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

private enum QRIntent: Identifiable {
    case parentSecret
    case parentChildImport
    case childDeviceImport

    var id: String {
        switch self {
        case .parentSecret: return "parentSecret"
        case .parentChildImport: return "parentChildImport"
        case .childDeviceImport: return "childDeviceImport"
        }
    }

    var title: String {
        switch self {
        case .parentSecret:
            return "Scan Parent nsec"
        case .parentChildImport:
            return "Scan Child nsec"
        case .childDeviceImport:
            return "Scan Child nsec"
        }
    }
}

private struct IdentityCard: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(value)
                .font(.system(.footnote).monospaced())
                .textSelection(.enabled)

            HStack {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = value
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }
}

private struct SecureValueCard: View {
    let title: String
    let value: String
    let isRevealed: Bool
    let toggle: () -> Void
    let copyAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            Group {
                if isRevealed {
                    Text(value)
                        .font(.system(.footnote).monospaced())
                        .textSelection(.enabled)
                } else {
                    Text("••••••••••••••")
                        .font(.system(.title2).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button(isRevealed ? "Hide" : "Reveal") {
                    toggle()
                }
                Button("Copy") {
                    copyAction()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("Store this nsec offline. Anyone with access can control the family account.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }
}
