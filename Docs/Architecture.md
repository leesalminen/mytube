# MyTube Architecture Overview

_Last updated: 2025-12-30_

This document captures the current end-to-end architecture of the MyTube iPad app, with a focus on module boundaries, persistence/caching strategies, and the Nostr protocol features (NIPs) we rely on for cross-device coordination.

---

## 1. High-Level Layering

```
SwiftUI Features  ─────────────┐
Shared UI Components           │  Presentation Layer
                               │
Domain Models & Auth Helpers ──┤
                               │  Domain Layer
Ranking, Relationship, Identity│
                               │
Services (Nostr, MinIO, Crypto,
Share Coordinator, Remote Video)── Infrastructure Layer
                               │
Persistence (Core Data, StoragePaths, Keychain) ── Data Layer
```

- **AppEnvironment (`MyTube/AppEnvironment.swift`)** acts as the dependency injector, wiring together the persistence stack, service singletons, and feature coordinators. It is created once at launch and exposed to SwiftUI scenes via `@EnvironmentObject`.
- **Features** (`MyTube/Features/**`) are SwiftUI modules (Home Feed, Capture, Editor, Parent Zone, Onboarding). They interact with services exclusively through environment dependencies or injected view models.
- **Domain** (`MyTube/Domain/**`) provides immutable models (`VideoModel`, `FollowModel`, etc.) and helpers (`ParentIdentityKey`, `RankingEngine`), isolating Core Data entities from feature logic.
- **Services** (`MyTube/Services/**`) encapsulate side effects: Nostr networking, crypto, MinIO uploads/downloads, relationship reconciliation, and background sharing/downloading tasks.

---

## 2. Data Flow & Key Coordinators

### 2.1 Local Capture → Storage
1. **CaptureViewModel** records with `AVCaptureSession`, emits a `VideoEntity` persisted via `VideoLibrary`.
2. Video files and thumbnails are written under `Application Support/MyTube/Media|Thumbs/<profileID>` using `StoragePaths` (complete file protection).
3. Combine publishers from Core Data (`NSFetchedResultsController`) update Home Feed via `HomeFeedViewModel`.

### 2.2 Cross-Device Sharing Pipeline
1. **VideoShareCoordinator** listens for new `VideoEntity` inserts and fetches current follow approvals from `RelationshipStore`. It reuses cached relationships and will retry queued videos when approvals arrive.
2. **VideoSharePublisher** encrypts the media with XChaCha20-Poly1305, uploads blobs directly to MinIO (signed PUT), and constructs a `VideoShareMessage`.
3. The message is delivered to remote parents via `DirectMessageOutbox` (NIP-44 DM) and persisted to `RemoteVideoEntity` by `NostrEventReducer`.
4. **RemoteVideoDownloader** decrypts and caches the shared media locally on demand (under `Media/Shared`), tracking status, errors, and last-downloaded timestamps in Core Data.

### 2.3 Relationship & Follow Management
1. **FollowCoordinator** issues or approves follow requests. It wraps outbound DMs, publishes follow pointer events, and records remote parent keys for later reconciliation.
2. **RelationshipStore** stores `FollowEntity` records in Core Data and exposes a `CurrentValueSubject` of normalized `FollowModel`s. It deduplicates variants (hex vs npub) and tracks all participating parent keys.
3. **SyncCoordinator** maintains relay connections, rebuilds primary subscriptions using tracked child and parent keys, and streams events into `NostrEventReducer`.
4. **NostrEventReducer** decrypts NIP-44 payloads, updates `RelationshipStore` (including participant keys), and persists remote video state.

---

## 3. Persistence & Caching Strategies

| Storage Concern | Mechanism | Notes |
| --- | --- | --- |
| **Structured state** | Core Data via `PersistenceController` | Entities: `VideoEntity`, `RemoteVideoEntity`, `FollowEntity`, `ProfileEntity`, `RankingStateEntity`, etc. Background contexts use `NSMergeByPropertyStoreTrump`. Persistent history is enabled. |
| **Local media** | `StoragePaths` (Application Support) | Separate folders for `Media`, `Thumbs`, `Edits`, each segregated by profile UUID. All directories use `.completeFileProtection`. |
| **Remote shares** | Core Data + file system | `RemoteVideoEntity` stores metadata, download status, and pointers to decrypted files in `Media/Shared`. Thumbnails mirror to `Thumbs/Shared`. |
| **Relationship cache** | `RelationshipStore` | Maintains in-memory `CurrentValueSubject` plus Core Data backing. Cached relationships allow share retries without hitting Core Data synchronously. |
| **Key material** | Keychain via `KeychainKeyStore` | Parent/child signing keys stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Delegations (NIP-26) cached in memory and exposed for QR export. |
| **Subscriptions** | `SyncCoordinator` state | Tracks subscribed keys (`trackedKeySnapshot`), parent keys, and ensures keep-alive refresh every 60s. |
| **UI state caches** | View-model level | e.g., `VideoShareCoordinator` caches follow arrays, `HomeFeedViewModel` caches fetch controllers, `RemoteVideoDownloader` tracks in-flight tasks. |

---

## 4. Nostr Integration & NIPs

| NIP | Usage in MyTube | Location |
| --- | --- | --- |
| **NIP-01** (base protocol) | Event signing/verification, relay subscriptions. | `NostrEventSigner`, `URLSessionNostrClient`. |
| **NIP-19** (bech32 identifiers) | Encoding/decoding `npub`/`nsec` keys for parent/child sharing and input validation. | `Services/Nostr/NIP19.swift`, `ParentIdentityKey`, `IdentityManager`. |
| **NIP-26** (delegations) | Parent delegates limited permissions to child devices; delegation tags exported in onboarding. | `IdentityManager.issueDelegation`, `NostrEventSigner`, Parent Zone onboarding UI. |
| **NIP-33** (parameterized replaceables) | Follow pointer events (`kind 30301`) and video tombstones (`kind 30302`) use `d` tags for replaceable semantics. | `NostrModels`, `FollowCoordinator.publishFollowPointer`, `NostrEventReducer`. |
| **NIP-44 v2** (encrypted DMs) | All direct messages (follow approvals, video share payloads) use the v2 envelope supplied by `nostr-sdk-swift`. | `CryptoEnvelopeService`, `DirectMessageOutbox`, `NostrEventReducer`. |
| **Planned/Partial:** NIP-65 (relay metadata), NIP-98 (HTTP auth), NIP-59 (gift wraps) | Mentioned in docs but not yet implemented in code. |

Additional protocol notes:
- Custom kinds `30301` and `30302` follow the NIP-33 pattern with `d` tags for deterministic replacement.
- DM decrypt failures currently show `invalid HMAC` for some partner devices; this is an active follow-up in the project tracker.

---

## 5. Local/Remote Security Considerations

- Media blobs are encrypted per-share with a unique 32-byte key; the key is embedded directly in the DM payload (and wrapped legacy fields retained for backwards compatibility).
- All local files under `StoragePaths` inherit iOS complete file protection, and writes occur on background queues with atomic semantics.
- Outbound HTTP uploads to MinIO use SigV4-signed `PUT` requests; downloads rely on authenticated URLs stored in `VideoShareMessage`.
- Parent/child keypairs are generated via `nostr-sdk-swift` and stored in Keychain; biometric requirements are currently disabled for parent keys to support background decrypt.

---

## 6. Future Enhancements

1. **NIP-44 Reliability:** Investigate remaining HMAC failures when decrypting partner DMs (likely due to mismatched derivation or stale keys).
2. **Follow Reconciliation:** Add jobs that backfill follow pointers on launch, revalidate dual approvals, and clear stale pending states.
3. **Analytics & Telemetry:** Surface relay health and subscription metrics in Parent Zone diagnostics for easier troubleshooting.
4. **Documentation & Support:** Extend this document with sequence diagrams and add a “multi-device troubleshooting” section once the DM fix ships.

---

For further details, see:
- `Docs/MyTubeImplementationPlan.md` – roadmap & outstanding engineering tasks.
- `Docs/MyTubeProtocolSpec.md` – data formats for follows, shares, and device provisioning.
- `Docs/Rust-Nostr.md` – nostr-sdk-swift usage notes and NIP references.
