# MDK Swift Package Integration Guide

This document covers the full workflow for producing the UniFFI-based Swift bindings, pulling them into any iOS-only SwiftUI application, and calling the available APIs. Share it with downstream teams so they never need to read the Rust sources.

---

## 1. Prerequisites

- **Rust**: `rustup toolchain install 1.91.0` (the `just` recipes pin to `+1.91.0` automatically).
- **just**: command runner used by this repo (`brew install just`).
- **Xcode 15+ / Swift 5.10+** with the iOS SDK installed.
- **CocoaPods not required**; the bindings ship as an `.xcframework` inside a Swift Package.

---

## 2. Build the Swift bindings

From the repo root:

```bash
just gen-binding-swift
```

The recipe performs the following:

1. Builds the `mdk-uniffi` crate (regular macOS target plus iOS + iOS Simulator static libs) with Rust `1.91.0`.
2. Runs `uniffi-bindgen` to emit the Swift glue code into `crates/mdk-uniffi/bindings/swift`.
3. Copies `mdk_uniffiFFI.h` into `ios-artifacts/headers` and regenerates `ios-artifacts/mdk_uniffi.xcframework`. (The recipe deletes any prior xcframework automatically to avoid “item already exists” errors.)
4. Assembles a redistributable Swift package under `swift/MDKPackage`:
   - `Sources/MDKBindings/` → generated high-level Swift module.
   - `Sources/mdk_uniffiFFI/` → C shim that exposes the FFI header.
   - `Binary/mdk_uniffi.xcframework` → fat binary containing the iOS + Simulator static libs.

> **Output to share:** commit or copy the whole `swift/MDKPackage` directory (plus `ios-artifacts/mdk_uniffi.xcframework` if another consumer wants the raw binary).

---

## 3. Add the package to an iOS-only SwiftUI app

1. **Open the consuming app in Xcode.**
2. **File ▸ Add Packages…**
   - Click the **Add Local…** button.
   - Select the `swift/MDKPackage` directory inside this repo.
   - Leave the default dependency rule (“Branch: main” or a specific commit tag you provide).
3. **Target selection**
   - Under *Add to Target*, pick your iOS app target(s) only.
   - Xcode adds the `MDKBindings` product and automatically embeds `mdk_uniffi.xcframework`.
4. **Verify build settings**
   - In *Build Settings ▸ Excluded Architectures*, ensure nothing excludes `arm64` for devices.
   - Under *General ▸ Frameworks, Libraries, and Embedded Content*, confirm `mdk_uniffi.xcframework` is listed as “Embed & Sign”.
5. **Import in code**

```swift
import MDKBindings
```

The module is iOS-only; there is no macOS Catalyst slice.

---

## 4. Initializing MDK in SwiftUI

```swift
import MDKBindings

final class MDKController: ObservableObject {
    let mdk: Mdk

    init() {
        let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dbURL = supportDir.appendingPathComponent("mdk.sqlite3")
        try? FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // newMdk() bootstraps a fresh SQLite-backed instance
        self.mdk = try! newMdk(dbPath: dbURL.path)
    }
}
```

Use a different database path per signed-in account if your app supports multiple identities.

---

## 5. Happy-path sample (three members)

```swift
import Foundation
import MDKBindings

struct Participant {
    let displayName: String
    let publicKeyHex: String
    let mdk: Mdk
}

func bootstrapParticipants(namesAndPubkeys: [(String, String)]) -> [Participant] {
    namesAndPubkeys.map { (name, pubkey) in
        let db = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).sqlite3")
        return Participant(
            displayName: name,
            publicKeyHex: pubkey,
            mdk: try! newMdk(dbPath: db.path)
        )
    }
}

func createInitialKeyPackages(_ members: [Participant], relays: [String]) -> [String] {
    members.map { member in
        let kp = try! member.mdk.createKeyPackageForEvent(
            publicKey: member.publicKeyHex,
            relays: relays
        )
        // Wrap the hex payload in your own Kind 443 event (omitted here) and return its JSON.
        return buildKeyPackageEventJson(pubkey: member.publicKeyHex,
                                        keyPackageHex: kp.key_package,
                                        tags: kp.tags)
    }
}

func runHappyPath() throws {
    let relays = ["wss://relay.example.com"]
    let participants = bootstrapParticipants(namesAndPubkeys: [
        ("Alice", "02…"),
        ("Bob", "03…"),
        ("Carol", "04…"),
    ])

    let creator = participants[0]
    let memberEvents = createInitialKeyPackages(participants.dropFirst().map { $0 }, relays: relays)
    let admins = [creator.publicKeyHex]

    // 1. Alice creates the group
    let createResult = try creator.mdk.createGroup(
        creatorPublicKey: creator.publicKeyHex,
        memberKeyPackageEventsJson: memberEvents,
        name: "Friends",
        description: "General chat",
        relays: relays,
        admins: admins
    )
    publish(eventsJson: createResult.welcome_rumors_json + [createResult.group.nostr_group_id])

    // 2. Bob adds Carol later
    let carolEvent = createInitialKeyPackages([participants[2]], relays: relays)
    let addResult = try participants[1].mdk.addMembers(
        mlsGroupId: createResult.group.mls_group_id,
        keyPackageEventsJson: carolEvent
    )
    publish(eventsJson: [addResult.evolutionEventJson])

    // 3. Alice removes Carol
    let removeResult = try creator.mdk.removeMembers(
        mlsGroupId: createResult.group.mls_group_id,
        memberPublicKeys: [participants[2].publicKeyHex]
    )
    publish(eventsJson: [removeResult.evolutionEventJson])

    // 4. Alice sends a message
    let rumorJson = try creator.mdk.createMessage(
        mlsGroupId: createResult.group.mls_group_id,
        senderPublicKey: creator.publicKeyHex,
        content: "{\"text\":\"Hi team\"}",
        kind: 6000
    )
    publish(eventsJson: [rumorJson])

    // 5. Anyone can inspect local state
    let groups = try creator.mdk.getGroups()
    let members = try creator.mdk.getMembers(mlsGroupId: groups[0].mls_group_id)
    let messages = try creator.mdk.getMessages(mlsGroupId: groups[0].mls_group_id)
    print("Group has \(members.count) members and \(messages.count) messages")
}
```

`publish(eventsJson:)` represents your client’s Nostr publishing pipeline; it should post the JSON payloads to the chosen relays and only call `mergePendingCommit` after a commit event is confirmed on the relays.

---

## 6. Admin & sync flows

Once the group is running, admins usually need to update metadata, rotate their own leaf node, propose departures, and hydrate state from relays.

```swift
// 1) Update group metadata (name, description, relays, admins, image fields)
let update = GroupDataUpdate(
    name: "Friends ++",
    description: nil,
    imageHash: nil,      // pass .some(.some(data)) to set, .some(nil) to clear
    imageKey: nil,
    imageNonce: nil,
    relays: ["wss://new.example"],
    admins: [creator.publicKeyHex]
)
let updateResult = try creator.mdk.updateGroupData(
    mlsGroupId: createResult.group.mls_group_id,
    update: update
)
publish(eventsJson: [updateResult.evolutionEventJson])

// 2) Rotate the local member's credential
let selfUpdateResult = try creator.mdk.selfUpdate(
    mlsGroupId: createResult.group.mls_group_id
)
publish(eventsJson: [selfUpdateResult.evolutionEventJson])

// 3) Creator proposes to leave the group
let leaveResult = try creator.mdk.leaveGroup(mlsGroupId: createResult.group.mls_group_id)
publish(eventsJson: [leaveResult.evolutionEventJson])

// 4) Merge commits after publishing
try creator.mdk.mergePendingCommit(mlsGroupId: createResult.group.mls_group_id)

// 5) Process inbound commits/messages pulled from relays
let processResult = try creator.mdk.processMessage(eventJson: inboundEventJson)
switch processResult {
case .applicationMessage(let payload):
    render(payload.message)
case .proposal(let update):
    publish(eventsJson: [update.result.evolutionEventJson])
case .externalJoinProposal(let info):
    review(info.mlsGroupId)
case .commit:
    try creator.mdk.mergePendingCommit(mlsGroupId: createResult.group.mls_group_id)
case .unprocessable:
    break
}
```

`processMessage` returns the `ProcessMessageResult` enum so callers can branch on proposals vs commits vs decrypted application content. Always publish the `evolutionEventJson` to relays before calling `mergePendingCommit`.

---

## 7. Full Swift API inventory

| Category | Method | Notes |
|----------|--------|-------|
| Factory | `newMdk(dbPath:) -> Mdk` | Opens/creates the SQLite-backed MDK instance. |
| Key packages | `createKeyPackageForEvent(publicKey:, relays:) -> KeyPackageResult` | Build Kind 443 payloads. |
|  | `parseKeyPackage(eventJson:)` | Validates incoming key package events. |
| Groups (query) | `getGroups() -> [Group]` | All cached groups. |
|  | `getGroup(mlsGroupId:) -> Group?` | Lookup by MLS ID. |
|  | `getMembers(mlsGroupId:) -> [String]` | Hex pubkeys. |
|  | `getRelays(mlsGroupId:) -> [String]` | Relay URLs. |
| Welcomes | `getPendingWelcomes() -> [Welcome]` | Local queue. |
|  | `processWelcome(wrapperEventId:, rumorEventJson:) -> Welcome` | Decrypts rumor content. |
|  | `acceptWelcome(welcomeJson:)` / `declineWelcome(welcomeJson:)` | Update state once user decides. |
| Group lifecycle | `createGroup(...) -> CreateGroupResult` | Returns stored group + welcome rumors. |
|  | `addMembers(mlsGroupId:, keyPackageEventsJson:) -> AddMembersResult` | Publish `evolutionEventJson`, optionally welcomes. |
|  | `removeMembers(mlsGroupId:, memberPublicKeys:) -> GroupUpdateResult` | Admin-only removal. |
|  | `updateGroupData(mlsGroupId:, update: GroupDataUpdate) -> GroupUpdateResult` | Mutate metadata/relays/admins/images. |
|  | `selfUpdate(mlsGroupId:) -> GroupUpdateResult` | Rotates the local signer credential. |
|  | `leaveGroup(mlsGroupId:) -> GroupUpdateResult` | Emits a leave proposal. |
|  | `mergePendingCommit(mlsGroupId:)` | Call after publishing the corresponding commit event. |
| Messaging | `createMessage(mlsGroupId:, senderPublicKey:, content:, kind:) -> String` | Returns the Kind 445 JSON event. |
|  | `getMessages(mlsGroupId:) -> [Message]` | Local decrypted history. |
|  | `getMessage(eventId:) -> Message?` | Lookup by wrapper ID. |
|  | `processMessage(eventJson:) -> ProcessMessageResult` | Handles inbound commits/proposals/application ciphertext. |

### FFI records and enums

- `KeyPackageResult`: `keyPackage` hex payload plus Nostr `tags`.
- `CreateGroupResult`: `group` (`Group`) and `welcomeRumorsJson`.
- `GroupUpdateResult`: `evolutionEventJson`, optional `welcomeRumorsJson`, `mlsGroupId`. Returned by remove/self-update/leave/update- group-data flows.
- `GroupDataUpdate`: optional fields (`name`, `description`, `imageHash`, `imageKey`, `imageNonce`, `relays`, `admins`). Pass `nil` to skip, `.some(nil)` to clear binary fields, `.some(Data)` to set.
- `AddMembersResult`: used for add-member commits (same schema as `GroupUpdateResult` for backwards compatibility).
- `Group`: metadata snapshot from storage (IDs, relays, admins, epoch, etc.).
- `Message`: decrypted wrapper + original event JSON + timestamps and state.
- `Welcome`: onboarding metadata (relays, admins, image info, welcomer).
- `ProcessMessageResult`: enum covering `.applicationMessage`, `.proposal`, `.externalJoinProposal`, `.commit`, `.unprocessable`.

This inventory matches the generated `swift/MDKPackage/Sources/MDKBindings/mdk_uniffi.swift` surface. Anytime new Rust methods are exported, rerun `just gen-binding-swift` and update this list so downstream repos stay current.

---

## 7. Validation checklist

1. `just gen-binding-swift`
2. `swift build` inside `swift/MDKPackage`
3. Add/update the package in your Xcode workspace and build the iOS target
4. Run your end-to-end smoke test (for example, the “three member happy path” sample above)

Following these steps guarantees every consuming repo can stay in sync with the MDK UniFFI bindings without touching the Rust codebase.
