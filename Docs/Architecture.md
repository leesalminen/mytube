# MyTube Architecture Overview

_Last updated: 2025-11-19_

This document captures the current end-to-end architecture of the MyTube iPad app, with a focus on module boundaries, persistence/caching strategies, and the Marmot/MDK group-based social model.

---

## 1. High-Level Layering

```
SwiftUI Features  ─────────────┐
Shared UI Components           │  Presentation Layer
                               │
Domain Models & Auth Helpers ──┤
                               │  Domain Layer
Ranking, Identity, Groups      │
                               │
Services (MDK/Marmot, Nostr,   │
MinIO, Crypto, Share)          ── Infrastructure Layer
                               │
Persistence (Core Data, MDK,   │
StoragePaths, Keychain)        ── Data Layer
```

- **AppEnvironment (`MyTube/AppEnvironment.swift`)** acts as the dependency injector, wiring together the persistence stack, service singletons, and feature coordinators. It is created once at launch and exposed to SwiftUI scenes via `@EnvironmentObject`.
- **Features** (`MyTube/Features/**`) are SwiftUI modules (Home Feed, Capture, Editor, Parent Zone, Onboarding). They interact with services exclusively through environment dependencies or injected view models.
- **Domain** (`MyTube/Domain/**`) provides immutable models (`VideoModel`, `ProfileModel`, etc.) and helpers (`ParentIdentityKey`, `RankingEngine`), isolating Core Data entities from feature logic.
- **Services** (`MyTube/Services/**`) encapsulate side effects: Marmot/MDK group operations, Nostr networking, crypto, MinIO uploads/downloads, and background sharing/downloading tasks.

---

## 2. Data Flow & Key Coordinators

### 2.1 Local Capture → Storage
1. **CaptureViewModel** records with `AVCaptureSession`, emits a `VideoEntity` persisted via `VideoLibrary`.
2. Video files and thumbnails are written under `Application Support/MyTube/Media|Thumbs/<profileID>` using `StoragePaths` (complete file protection).
3. Combine publishers from Core Data (`NSFetchedResultsController`) update Home Feed via `HomeFeedViewModel`.

### 2.2 Cross-Device Sharing Pipeline (Parent-Only Groups)
1. **VideoShareCoordinator** listens for new `VideoEntity` inserts and looks up the child profile's `mlsGroupId` to determine which Marmot group to share to. Videos are automatically shared when a group exists.
2. **VideoSharePublisher** encrypts the media with XChaCha20-Poly1305, uploads blobs directly to MinIO (signed PUT), and constructs a `VideoShareMessage` with child metadata (`childName`, `childProfileId`).
3. **MarmotShareService** hands the JSON payload to `MarmotTransport`, which publishes the MDK message (encrypted with MLS) to all group members. The video is signed by the parent's key with embedded child information.
4. **RemoteVideoDownloader** decrypts and caches the shared media locally on demand (under `Media/Shared`), tracking status, errors, and last-downloaded timestamps in Core Data.

### 2.3 Group Management & Identity Model
1. **Parent-Only Membership**: Only parent/household Nostr identities join Marmot groups. Children are local profiles without separate Nostr keys. All content is published under the parent's key with child metadata in the payload.
2. **GroupMembershipCoordinator** issues Marmot/MDK group operations: creates groups with remote parents as initial members, adds/removes members via `addMembers`/`removeMembers`, and wraps welcomes through `MarmotTransport`.
3. **Child Profiles**: Each child profile can be associated with one Marmot group (stored in `profile.mlsGroupId`). Groups are created when the first connection is made (requires 2+ members per MLS spec).
4. **SyncCoordinator** maintains relay connections, subscribes to Marmot kinds (key packages, welcomes, group commits, gift wraps), and fans events out to `MarmotTransport` and `NostrEventReducer`.
5. **NostrEventReducer** now only handles replaceables (metadata, tombstones). Follow pointers are deprecated. All group messaging moved to MDK, and `MarmotProjectionStore` projects MDK data into Core Data for UI consumption.

---

## 3. Persistence & Caching Strategies

| Storage Concern | Mechanism | Notes |
| --- | --- | --- |
| **Structured state** | Core Data via `PersistenceController` | Entities: `VideoEntity`, `RemoteVideoEntity`, `ProfileEntity`, `RankingStateEntity`, etc. Background contexts use `NSMergeByPropertyStoreTrump`. Persistent history is enabled. |
| **MDK group state** | MDK SQLite database | Groups, members, MLS state, messages stored in `Application Support/MyTube/mdk.sqlite`. Accessed via `MdkActor` (thread-safe actor wrapper). |
| **Local media** | `StoragePaths` (Application Support) | Separate folders for `Media`, `Thumbs`, `Edits`, each segregated by profile UUID. All directories use `.completeFileProtection`. |
| **Remote shares** | Core Data + file system | `RemoteVideoEntity` stores metadata, download status, and pointers to decrypted files in `Media/Shared`. Thumbnails mirror to `Thumbs/Shared`. |
| **Key material** | Keychain via `KeychainKeyStore` | Only parent signing keys stored (children don't have keys). Uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. |
| **Group membership** | MDK database + Core Data projection | Source of truth is MDK via `getGroups()`, `getMembers()`. `MarmotProjectionStore` mirrors to Core Data for UI queries. |
| **Subscriptions** | `SyncCoordinator` state | Tracks parent key only. Subscribes to Marmot events (key packages, welcomes, commits) on behalf of all local profiles. |
| **UI state caches** | View-model level | e.g., `HomeFeedViewModel` caches fetch controllers, `RemoteVideoDownloader` tracks in-flight tasks, `ParentZoneViewModel` caches group summaries. |

---

## 4. Nostr Integration & NIPs

| NIP | Usage in MyTube | Location |
| --- | --- | --- |
| **NIP-01** (base protocol) | Event signing/verification, relay subscriptions. | `NostrEventSigner`, `RelayPoolNostrClient`. |
| **NIP-19** (bech32 identifiers) | Encoding/decoding `npub`/`nsec` keys for parent identity sharing and input validation. | `Services/Nostr/NIP19.swift`, `ParentIdentityKey`, `IdentityManager`. |
| **NIP-26** (delegations) | DEPRECATED - Previously used for child delegations, no longer needed since children don't have keys. | Stub remains in `IdentityManager` for compatibility. |
| **NIP-33** (parameterized replaceables) | Video tombstones (`kind 30302`) use `d` tags. Follow pointers (`kind 30301`) are deprecated (no-op in reducer). | `NostrModels`, `NostrEventReducer`. |
| **NIP-59** (gift wraps) | Marmot welcomes use NIP-59 gift wraps with ephemeral keys. `CryptoEnvelopeService` handles wrapping/unwrapping for `MarmotTransport`. | `CryptoEnvelopeService`, `MarmotTransport`. |

Additional protocol notes:
- **Marmot Event Kinds**: 443 (key packages), 444 (MLS proposals/commits), 1059 (gift-wrapped welcomes), 9000-9002 (MLS messages/application data).
- Gift wraps use random ephemeral keys with recipient in `p` tag, not the event's `pubkey` field.
- All Marmot events are MLS-encrypted; MDK handles encryption/decryption transparently.

---

## 5. Local/Remote Security Considerations

- **Media encryption**: Blobs are encrypted per-share with a unique 32-byte XChaCha20-Poly1305 key; the key lives inside the `VideoShareMessage` payload that MDK MLS-encrypts for transport.
- **File protection**: All local files under `StoragePaths` inherit iOS complete file protection, and writes occur on background queues with atomic semantics.
- **Storage**: Outbound HTTP uploads to MinIO use SigV4-signed `PUT` requests; downloads rely on authenticated URLs stored in `VideoShareMessage`.
- **Identity model**: Only parents have Nostr keypairs (generated via `nostr-sdk-swift`). Children are local profiles identified by UUID, with no separate keys or on-chain presence.
- **MLS security**: Marmot groups use MLS (Message Layer Security) for end-to-end encryption. MDK manages key packages, ratcheting, and forward secrecy automatically.

---

## 6. Key Architectural Decisions

### Parent-Only Groups (Nov 2025)
**Decision**: Only parent/household identities participate in Marmot groups. Children are local profiles without Nostr keys.

**Rationale**:
- **Safety**: Protocol-level social graph is adult-only, simplifying moderation and COPPA compliance
- **Simplicity**: Eliminates child key management, delegation complexity, and dual identity sync
- **Scalability**: Cleaner permission model - parent controls all group membership
- **Security**: Reduces attack surface by not exposing children as network identities

**Implementation**:
- `ChildIdentity` is just a profile wrapper with no `NostrKeyPair`
- Videos published under parent key with `childName` and `childProfileId` in payload
- Groups created when first connection is made (MLS requires 2+ members)
- `profile.mlsGroupId` links child profiles to their sharing group

### Removal of Follow/Relationship System (Nov 2025)
**Decision**: Eliminated `RelationshipStore`, `FollowModel`, and all follow-related state tracking.

**Rationale**:
- MDK groups ARE the social graph - no need for duplicate state
- Group membership queries (`getGroups()`, `getMembers()`) provide real-time truth
- Reduced complexity: ~2000 lines of follow management code removed
- Welcome/accept flow directly manages group membership

**Migration**: This is a breaking change requiring fresh installs.

## 7. Future Enhancements

1. **Enhanced Group UI:** Replace legacy follow UI with group management interface showing MDK group names, member lists, and admin controls.
2. **Multi-Group Support:** Allow child profiles to be shared with multiple groups (classroom, family, friends).
3. **Analytics & Telemetry:** Surface relay health and MDK group metrics in Parent Zone diagnostics.
4. **Safety Group Rollout:** Stand up the shared "Safety HQ" MDK group that every parent joins for moderation reports.
5. **Offline Support:** Improve MDK message queuing for offline scenarios and conflict resolution.

---

For further details, see:
- `Docs/MyTubeImplementationPlan.md` – roadmap & outstanding engineering tasks.
- `Docs/MyTubeProtocolSpec.md` – data formats for follows, shares, and device provisioning.
- `Docs/Rust-Nostr.md` – nostr-sdk-swift usage notes and NIP references.
