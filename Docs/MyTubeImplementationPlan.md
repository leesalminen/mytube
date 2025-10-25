# MyTube Implementation Plan

This plan translates the approved protocol and product spec into actionable engineering work. It captures the current application state (as of commit time) and outlines the roadmap Codex should follow to deliver the MVP.

---

## 1. Current State vs. Spec (Gap Analysis)

| Area | Spec Expectation | Current Implementation | Gaps / Risks |
| ---- | ---------------- | ---------------------- | ------------ |
| **Networking & Relays** | Full Nostr client (publish/subscribe, relay management, replaceables) with NIP-26 verification | `URLSessionNostrClient` now manages retry/backoff, health snapshots, and resubscription across relays | Persist subscription filters, surface latency metrics, add replaceable dedupe/storage |
| **Crypto Key Management** | Parent & child keypairs, delegation issuance/validation, Secure Enclave storage | Only parent PIN via Keychain (`MyTube/Services/ParentAuth.swift:11`) | Implement key generation, secure storage, delegation verification, key export/import UI |
| **Encrypted Messaging** | NIP-44 DM handling with payload schemas and state machines | DM decrypt/parse hooked into `NostrEventReducer`; family link/follow/video lifecycle updates reach Core Data | Harden signature/delegation validation, add outgoing DM helpers, enable conflict resolution tests |
| **Media Encryption & Upload** | XChaCha20-Poly1305 media encryption, MinIO helper API, upload/delete flow | `CryptoEnvelopeService` now performs XChaCha media encryption and X25519 key wrapping; MinIO client still pending | Implement MinIO upload/download helpers, signed URL handling, and delete/revoke fan-out |
| **Sharing Graph** | Family links + child follows driven by replaceables and DM updates | Core Data now includes `FamilyLink`, `Follow`, and `RemoteVideo` entities populated by Nostr reducers | Add pending-action queue, approvals UI, conflict resolution, and rate-limit enforcement |
| **Premium Paywall** | StoreKit subscription gating cloud features | No StoreKit code | Add StoreKit 2 flow, subscription state persistence, gating in UI/services |
| **UI/UX** | Needs relay management, approvals UI, share/revoke flows, premium onboarding, safety disclosures | Feed now shows local shelves plus "Shared With You"; Parent Zone exposes relay diagnostics + smoke test view | Design approvals, sharing, and premium flows; add remote playback/download UX and safety disclosures |
| **Background Sync** | Relay subscriptions, cache persistence, offline handling, delete/revoke compliance | Sync pipeline now writes remote video state + relationship entities; relay health exposed to UI | Persist subscriptions, add offline reconciliation, purge local caches on delete/revoke |
| **Testing** | Unit tests for crypto, DM parsing, MinIO client, paywall; UI tests for end-to-end flows | Current tests focus on local ranking & storage | Expand coverage, add networking/crypto stubs, UI automation for approval flows |

Supporting files reviewed: `AppEnvironment.swift`, `StoragePaths.swift`, `Services/VideoLibrary.swift`, `Services/ParentAuth.swift`, `Domain/RankingEngine.swift`, `Features/*` SwiftUI views.

---

## 2. Implementation Roadmap

1. **Foundational Services**
   - Add `NostrClient` with relay management, publish/subscribe pipeline, durable storage of replaceables (extend existing `URLSessionNostrClient` scaffolding).
   - Implement `KeychainKeyStore` for parent/child keys using Secure Enclave, plus delegation verifier.
   - Create `CryptoEnvelopeService` for XChaCha20 media encryption, key wrapping/unwrapping, and NIP-44 DM envelopes. _Status: service implemented and integrated; unit tests pending._

2. **Data Model Extensions**
   - Expand Core Data (`MyTube.xcdatamodeld`) with entities for `FamilyLink`, `Follow`, `RemoteVideo`, `ShareRecipient`, `PendingAction`.
   - Provide migration helpers and background fetch APIs in new service layer (`GraphStore`, `ShareStore`). _Status:_ Entities exist and DM reducers populate them; need pending-action queue and duplication reconciliation.

3. **MinIO Integration**
   - Introduce `MinIOClient` to hit `/upload/init`, signed PUT/GET, `/upload/commit`, and `/media` DELETE.
   - Add retry/backoff and exponential fallback; persist keys for delete fan-out. _Status: not started._

4. **Relay Sync Engine**
   - Complete `SyncCoordinator` (background actor) so it:
     - Maintains subscriptions (family link, follow, DM filters) across launches.
     - Validates signatures, NIP-26 delegations, and dedupes events via `NostrEventReducer`.
     - Persists reducer output to Core Data on the main actor and informs dependent view models.
   - Add rate limiting, telemetry hooks, and relay health reporting surfaced in Parent Zone. _Status: health UI and DM reducers are live; subscription persistence/dedupe still pending._

5. **UI Enhancements**
   - Settings: relay list editor, key export (npub), Secure Enclave status, paywall messaging.
   - Parent Zone: approvals dashboard (family link/follow), share history, revoke/delete actions, enhanced diagnostics.
   - Feed: integrate remote shares, show download/decrypt states, purge on delete. _Status: "Shared With You" shelf live; playback/download UX still TBD._
   - Capture/Editor: premium gating for cloud features, status indicators during upload/encrypt.
   - Player/Editor modals already widened; add share/revoke buttons per spec.

6. **Premium Paywall**
   - Implement StoreKit 2 subscription flow (`$20/year`), receipt validation (local), grace periods.
   - Gate MinIO and share features; expose upgrade CTA.

7. **Safety & Compliance**
   - Add "How MyTube protects your child" explainer.
   - Implement report/block UI and DM publishing helpers.
   - Ensure calm mode combines with remote content filters.

8. **Testing & QA**
   - Unit tests for crypto utilities, DM decoding, MinIO client, relay directory, remote video store, and sync reducers.
   - UI tests for family link + follow approvals, share/decrypt playback, delete propagation, and relay management.
   - Stress tests for large remote graph (cached data) and offline delete propagation.

9. **Documentation & Dev Tooling**
   - Update `AGENTS.md` with relay setup, MinIO credentials, development workflows.
   - Provide scripts for seeding relays, mocking upload endpoints, and running local MinIO.

Each milestone should land via atomic commits (per repository guidelines) with proof of tests (`xcodebuild test` and relevant suites). Prioritize delivering a functioning local experience while layering cloud capabilities carefully to preserve offline-first behavior.

---

## 3. Immediate Follow-up Tasks

- Persist relay subscription filters on disk, dedupe replaceables, and emit health telemetry (latency, consecutive failures) from `URLSessionNostrClient`.
- Add unit tests for `CryptoEnvelopeService` covering XChaCha media encryption, key wrapping, and NIP-44 framing edge cases.
- Validate the DM reducer with integration tests for family link/follow/video lifecycle flows and reconcile duplicate pointer records.
- Extend `KeychainKeyStore` with secure export/import tooling (npub/nsec bech32 encoding, delegation storage) and biometry error handling surfaced to the UI.
- Finalize `SyncCoordinator` so it consumes reducer output, updates Core Data on the main actor, and invalidates feeds/player/editor when remote data changes.
- Surface `RelayDirectory` management in Parent Zone settings (add/remove/toggle relays) with health indicators, and ensure `SyncCoordinator` refreshes subscriptions on edits.
- Finish remote share UX: enable decrypt/download actions from the "Shared With You" shelf and propagate delete/revoke handling into Player/Editor flows.
