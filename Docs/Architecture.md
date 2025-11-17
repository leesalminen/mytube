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
3. `MarmotShareService` hands the JSON payload to `MarmotTransport`, which publishes the MDK rumor (plus any welcome gift wraps) to the relays backing that child’s group. Legacy direct-message delivery has been removed; inbound history will soon be sourced from MDK’s local database instead of the deprecated reducer.
4. **RemoteVideoDownloader** decrypts and caches the shared media locally on demand (under `Media/Shared`), tracking status, errors, and last-downloaded timestamps in Core Data.

### 2.3 Relationship & Follow Management
1. **GroupMembershipCoordinator** issues Marmot/MDK group operations: it creates per-child MLS groups, adds remote parents via `addMembers`, wraps welcomes through `MarmotTransport`, and now removes members (revoke/block) through MDK’s `removeMembers` API.
2. **RelationshipStore** stores `FollowEntity` records in Core Data and exposes a `CurrentValueSubject` of normalized `FollowModel`s. It deduplicates variants (hex vs npub), tracks participant keys, and records the `mlsGroupId` tied to each child/parent relationship.
3. **SyncCoordinator** maintains relay connections, subscribes to Marmot kinds (key packages, welcomes, group commits, gift wraps), and fans events out to `MarmotTransport` plus the pared-down `NostrEventReducer`.
4. **NostrEventReducer** now only handles replaceables (metadata, follow pointers, tombstones). All encrypted messaging moved to MDK, and a future Marmot projection layer will replace the remaining Core Data ingest.

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
| **NIP-33** (parameterized replaceables) | Video tombstones (`kind 30302`) still use `d` tags; legacy follow pointers (`kind 30301`) have been replaced by Marmot/MDK groups. | `NostrModels`, `NostrEventReducer`. |
| **NIP-59 gift wraps (NIP-44 envelopes inside)** | Marmot welcomes and rumor fan-out use NIP-59 gift wraps that embed the NIP-44 envelope; `CryptoEnvelopeService` handles the wrapping/unwrapping for `MarmotTransport`. | `CryptoEnvelopeService`, `MarmotTransport`. |
| **Planned/Partial:** NIP-65 (relay metadata), NIP-98 (HTTP auth), NIP-59 (gift wraps) | Mentioned in docs but not yet implemented in code. |

Additional protocol notes:
- Custom kinds `30301` and `30302` follow the NIP-33 pattern with `d` tags for deterministic replacement.
- Gift-wrap decrypt failures (NIP-59) currently show `invalid HMAC` for some partner devices; this is an active follow-up in the project tracker.

---

## 5. Local/Remote Security Considerations

- Media blobs are encrypted per-share with a unique 32-byte key; the key lives inside the `VideoShareMessage` payload that MDK encrypts/gift-wraps for transport.
- All local files under `StoragePaths` inherit iOS complete file protection, and writes occur on background queues with atomic semantics.
- Outbound HTTP uploads to MinIO use SigV4-signed `PUT` requests; downloads rely on authenticated URLs stored in `VideoShareMessage`.
- Parent/child keypairs are generated via `nostr-sdk-swift` and stored in Keychain; biometric requirements are currently disabled for parent keys to support background decrypt.

---

## 6. Future Enhancements

1. **Marmot Projection:** Finish the Core Data projection that reads MDK groups/messages so remote shelves, likes, and reports no longer rely on the removed direct-message reducer.
2. **Follow Reconciliation:** Add jobs that backfill follow pointers on launch, revalidate dual approvals, and clear stale pending states.
3. **Analytics & Telemetry:** Surface relay health and subscription metrics in Parent Zone diagnostics for easier troubleshooting.
4. **Documentation & Support:** Extend this document with Marmot sequence diagrams (gift-wraps, welcome approvals) and add “multi-device troubleshooting” once the projection work lands.
5. **Safety Group Rollout:** Document and stand up the shared “Safety HQ” MDK group that every parent joins so moderation reports can fan out without reviving legacy direct-messaging plumbing.

---

For further details, see:
- `Docs/MyTubeImplementationPlan.md` – roadmap & outstanding engineering tasks.
- `Docs/MyTubeProtocolSpec.md` – data formats for follows, shares, and device provisioning.
- `Docs/Rust-Nostr.md` – nostr-sdk-swift usage notes and NIP references.
