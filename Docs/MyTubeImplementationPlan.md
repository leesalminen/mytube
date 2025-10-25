# MyTube Implementation Plan

This plan translates the approved protocol and product spec into actionable engineering work. It captures the current application state (as of commit time) and outlines the roadmap Codex should follow to deliver the MVP.

---

## 1. Current State vs. Spec (Gap Analysis)

| Area | Spec Expectation | Current Implementation | Gaps / Risks |
| ---- | ---------------- | ---------------------- | ------------ |
| **Networking & Relays** | Full Nostr client (publish/subscribe, relay management, replaceables) with NIP-26 verification | Scaffolded `RelayDirectory`, `SyncCoordinator`, and `URLSessionNostrClient` with basic subscriptions | Flesh out event pipeline (DM parsing, replaceable dedupe), reconnection/backoff, durable subscription persistence |
| **Crypto Key Management** | Parent & child keypairs, delegation issuance/validation, Secure Enclave storage | Only parent PIN via Keychain (`MyTube/Services/ParentAuth.swift:11`) | Implement key generation, secure storage, delegation verification, key export/import UI |
| **Encrypted Messaging** | NIP-44 DM handling with payload schemas and state machines | `NostrEventReducer` placeholder only writes pointer/tombstone markers | Implement NIP-44 decrypt/encrypt, payload decoding, conflict resolution, and Core Data updates per state machine |
| **Media Encryption & Upload** | XChaCha20-Poly1305 media encryption, MinIO helper API, upload/delete flow | Local file moves via `VideoLibrary` and `StoragePaths` | Implement media encrypt/decrypt, upload client, signed URL handling, delete/revoke fan-out |
| **Sharing Graph** | Family links + child follows driven by replaceables and DM updates | Local Core Data models contain only profile/video/feedback | Extend Core Data (or alternative store) for relationships, approvals, rate limits |
| **Premium Paywall** | StoreKit subscription gating cloud features | No StoreKit code | Add StoreKit 2 flow, subscription state persistence, gating in UI/services |
| **UI/UX** | Needs relay management, approvals UI, share/revoke flows, premium onboarding, safety disclosures | Current UI covers feed/capture/editor/parent PIN | Design & build new flows, integrate with existing features |
| **Background Sync** | Relay subscriptions, cache persistence, offline handling, delete/revoke compliance | `SyncCoordinator` starts at launch but lacks persistence and reducer wiring | Persist subscriptions, handle offline replay, ensure delete/revoke purge paths |
| **Testing** | Unit tests for crypto, DM parsing, MinIO client, paywall; UI tests for end-to-end flows | Current tests focus on local ranking & storage | Expand coverage, add networking/crypto stubs, UI automation for approval flows |

Supporting files reviewed: `AppEnvironment.swift`, `StoragePaths.swift`, `Services/VideoLibrary.swift`, `Services/ParentAuth.swift`, `Domain/RankingEngine.swift`, `Features/*` SwiftUI views.

---

## 2. Implementation Roadmap

1. **Foundational Services**
   - Add `NostrClient` with relay management, publish/subscribe pipeline, durable storage of replaceables (extend existing `URLSessionNostrClient` scaffolding).
   - Implement `KeychainKeyStore` for parent/child keys using Secure Enclave, plus delegation verifier.
   - Create `CryptoEnvelopeService` for XChaCha20 media encryption, key wrapping/unwrapping, and NIP-44 DM envelopes.

2. **Data Model Extensions**
   - Expand Core Data (`MyTube.xcdatamodeld`) with entities for `FamilyLink`, `Follow`, `RemoteVideo`, `ShareRecipient`, `PendingAction`.
   - Provide migration helpers and background fetch APIs in new service layer (`GraphStore`, `ShareStore`). _Status:_ `FamilyLink`, `Follow`, and `RemoteVideo` entities now exist; reducers still need to populate real statuses from DM payloads.

3. **MinIO Integration**
   - Introduce `MinIOClient` to hit `/upload/init`, signed PUT/GET, `/upload/commit`, and `/media` DELETE.
   - Add retry/backoff and exponential fallback; persist keys for delete fan-out.

4. **Relay Sync Engine**
   - Complete `SyncCoordinator` (background actor) so it:
     - Maintains subscriptions (family link, follow, DM filters) across launches.
     - Validates signatures, NIP-26 delegations, and dedupes events via `NostrEventReducer`.
     - Persists reducer output to Core Data on the main actor and informs dependent view models.
   - Add rate limiting, telemetry hooks, and relay health reporting surfaced in Parent Zone.

5. **UI Enhancements**
   - Settings: relay list editor, key export (npub), Secure Enclave status, paywall messaging.
   - Parent Zone: approvals dashboard (family link/follow), share history, revoke/delete actions.
   - Feed: integrate remote shares, show download/decrypt states, purge on delete.
   - Capture/Editor: premium gating for cloud features, status indicators during upload/encrypt.
   - Player/Editor modals already widened; add share/revoke buttons per spec.

6. **Premium Paywall**
   - Implement StoreKit 2 subscription flow (`$20/year`), receipt validation (local), grace periods.
   - Gate MinIO and share features; expose upgrade CTA.

7. **Safety & Compliance**
   - Add “How MyTube protects your child” explainer.
   - Implement report/block UI and DM publishing helpers.
   - Ensure calm mode combines with remote content filters.

8. **Testing & QA**
   - Unit tests for crypto utilities, DM decoding, MinIO client, relay directory, and sync reducers.
   - UI tests for family link + follow approvals, share/decrypt playback, delete propagation, and relay management.
   - Stress tests for large remote graph (cached data) and offline delete propagation.

9. **Documentation & Dev Tooling**
   - Update `AGENTS.md` with relay setup, MinIO credentials, development workflows.
   - Provide scripts for seeding relays, mocking upload endpoints, and running local MinIO.

Each milestone should land via atomic commits (per repository guidelines) with proof of tests (`xcodebuild test` and relevant suites). Prioritize delivering a functioning local experience while layering cloud capabilities carefully to preserve offline-first behavior.

---

## 3. Immediate Follow-up Tasks

- Extend `URLSessionNostrClient` with relay health checks, exponential backoff reconnects, and on-disk persistence for subscription state.
- Implement full XChaCha20-Poly1305 media encryption and X25519 key wrapping in `CryptoEnvelopeService`, replacing the temporary ChaChaPoly path.
- Add NIP-44 compliant DM encryption/decryption helpers next, then teach `NostrEventReducer` to parse family link/follow/video lifecycle payloads and persist canonical states.
- Extend `KeychainKeyStore` with secure export/import tooling (npub/nsec bech32 encoding, delegation storage) and biometry error handling surfaced to the UI.
- Finalize `SyncCoordinator` so it consumes reducer output, updates Core Data on the main actor, and invalidates feeds/player/editor when remote data changes.
- Surface `RelayDirectory` management in the Parent Zone settings (add/remove/toggle relays) with health indicators, and ensure `SyncCoordinator` refreshes subscriptions on edits.
- Hook synced remote videos and relationship states into Home Feed, Player, and Editor flows once reducer data is live, purging content immediately on delete/revoke.
