# MyTube Implementation Plan

This plan translates the approved protocol and product spec into actionable engineering work. It captures the current application state (as of commit time) and outlines the roadmap Codex should follow to deliver the MVP.

---

## 1. Current State vs. Spec (Gap Analysis)

| Area | Spec Expectation | Current Implementation | Gaps / Risks |
| ---- | ---------------- | ---------------------- | ------------ |
| **Networking & Relays** | Full Nostr client (publish/subscribe, relay management, replaceables) with NIP-26 verification | `URLSessionNostrClient` now manages retry/backoff, health snapshots, and resubscription across relays | Persist subscription filters, surface latency metrics, add replaceable dedupe/storage |
| **Crypto Key Management** | Parent & child keypairs, delegation issuance/validation, Secure Enclave storage | `KeychainKeyStore` + `IdentityManager` now generate/store keys, issue NIP-26 delegations, and surface QR/clipboard onboarding plus Parent Zone child management | Persist delegation metadata, validate on inbound events, add rotation UX, and cover biometric failure recovery |
| **Encrypted Messaging** | NIP-44 DM handling with payload schemas and state machines | DM decrypt/parse hooked into `NostrEventReducer`; follow/video lifecycle updates reach Core Data | Harden signature/delegation validation, add outgoing DM helpers, enable conflict resolution tests |
| **Media Encryption & Upload** | XChaCha20-Poly1305 media encryption, MinIO helper API, upload/delete flow | `CryptoEnvelopeService` handles XChaCha media encryption and key wrapping; new `MinIOClient` + `VideoSharePublisher` orchestrate helper API calls and share DMs | Harden upload error handling, add download helpers, and wire UI workflows plus revoke fan-out |
| **Sharing Graph** | Parent-approved follows driven by replaceables and DM updates | Core Data tracks follow entities; FollowCoordinator now enforces bilateral parent approvals before follow activation; Parent Zone surfaces follow requests/approvals/active connections and secure sharing checks link status | Add pending-action queue, conflict resolution, rate-limit enforcement, and cross-device follow onboarding |
| **Premium Paywall** | StoreKit subscription gating cloud features | No StoreKit code | Add StoreKit 2 flow, subscription state persistence, gating in UI/services |
| **UI/UX** | Needs relay management, approvals UI, share/revoke flows, premium onboarding, safety disclosures | Feed now shows local shelves plus "Shared With You"; Parent Zone now includes relay diagnostics with connection gating, a DM smoke test, and a secure share sheet for remote publishing | Design approvals, sharing, and premium flows; add remote playback/download UX, share history/revoke controls, and safety disclosures |
| **Background Sync** | Relay subscriptions, cache persistence, offline handling, delete/revoke compliance | Sync pipeline now writes remote video state + relationship entities; relay health exposed to UI | Persist subscriptions, add offline reconciliation, purge local caches on delete/revoke |
| **Testing** | Unit tests for crypto, DM parsing, MinIO client, paywall; UI tests for end-to-end flows | Current tests focus on local ranking & storage | Expand coverage, add networking/crypto stubs, UI automation for approval flows |

Supporting files reviewed: `AppEnvironment.swift`, `StoragePaths.swift`, `Services/VideoLibrary.swift`, `Services/ParentAuth.swift`, `Domain/RankingEngine.swift`, `Features/*` SwiftUI views.

---

## 2. Implementation Roadmap

1. **Foundational Services**
   - Add `NostrClient` with relay management, publish/subscribe pipeline, durable storage of replaceables (extend existing `URLSessionNostrClient` scaffolding).
   - Implement `KeychainKeyStore` for parent/child keys using Secure Enclave, plus delegation verifier. _Status: IdentityManager + onboarding/Parent Zone now cover generation/import, QR export, and delegation issuance; validation + Secure Enclave fallback still pending._
   - Create `CryptoEnvelopeService` for XChaCha20 media encryption, key wrapping/unwrapping, and NIP-44 DM envelopes. _Status: service implemented and integrated; unit tests pending._

2. **Data Model Extensions**
   - Expand Core Data (`MyTube.xcdatamodeld`) with entities for `Follow`, `RemoteVideo`, `ShareRecipient`, `PendingAction`.
   - Provide migration helpers and background fetch APIs in new service layer (`GraphStore`, `ShareStore`). _Status:_ Follow/remote video entities exist and DM reducers populate them; need pending-action queue and duplication reconciliation.

3. **MinIO Integration**
   - Introduce `MinIOClient` to hit `/upload/init`, signed PUT/GET, `/upload/commit`, and `/media` DELETE.
   - Add retry/backoff and exponential fallback; persist keys for delete fan-out. _Status: helper client + share publisher actor implemented; Parent Zone share sheet now drives outbound uploads; retries plus download/delete wiring still pending._

4. **Relay Sync Engine**
   - Complete `SyncCoordinator` (background actor) so it:
     - Maintains subscriptions (follow and DM filters) across launches.
     - Validates signatures, NIP-26 delegations, and dedupes events via `NostrEventReducer`.
     - Persists reducer output to Core Data on the main actor and informs dependent view models.
   - Add rate limiting, telemetry hooks, and relay health reporting surfaced in Parent Zone. _Status: health UI and DM reducers are live; subscription persistence/dedupe still pending._

5. **UI Enhancements**
   - Onboarding: role selection, parent setup, child import via QR, and delegation export. _Status: Completed; diagnostics view now enforces relay readiness; next ensure reducers consume stored delegations._
   - Settings/Parent Zone: relay editor, Secure Enclave status, paywall messaging.
   - Parent Zone: approvals dashboard (follow), share history, revoke/delete actions, enhanced diagnostics. _Status: secure share sheet available; approvals, history, and revoke tooling remain open._
   - Feed: integrate remote shares, show download/decrypt states, purge on delete. _Status: "Shared With You" shelf live; playback/download UX still TBD._
   - Capture/Editor: premium gating for cloud features, status indicators during upload/encrypt.
   - Player/Editor modals already widened; add share/revoke buttons per spec.

6. **Premium Paywall**
   - Implement StoreKit 2 subscription flow (`$20/year`), receipt validation (local), grace periods.
   - Gate MinIO and share features; expose upgrade CTA.

7. **Safety & Compliance**
   - Add "How MyTube protects your child" explainer.
   - Implement report/block UI and DM publishing helpers.

8. **Testing & QA**
   - Unit tests for crypto utilities, DM decoding, MinIO client, relay directory, remote video store, and sync reducers.
   - UI tests for follow approvals, share/decrypt playback, delete propagation, and relay management.
   - Stress tests for large remote graph (cached data) and offline delete propagation.

9. **Documentation & Dev Tooling**
   - Update `AGENTS.md` with relay setup, MinIO credentials, development workflows.
   - Provide scripts for seeding relays, mocking upload endpoints, and running local MinIO.

Each milestone should land via atomic commits (per repository guidelines) with proof of tests (`xcodebuild test` and relevant suites). Prioritize delivering a functioning local experience while layering cloud capabilities carefully to preserve offline-first behavior.

---

## 3. Immediate Follow-up Tasks

- Persist relay subscription filters on disk, dedupe replaceables, and emit health telemetry (latency, consecutive failures) from `URLSessionNostrClient`.
- Add deterministic unit tests for `CryptoEnvelopeService` covering XChaCha media encryption, key wrapping, and NIP-44 framing edge cases.
- Validate the DM reducer with integration tests for follow/video lifecycle flows, ensuring follow activation only occurs when both parents have approved, and reconcile duplicate pointer records.
- Reflect effective follow status across feed/share queries (remote shelves, recipient presets) and surface revoke/block states in the Parent Zone UI.
- Extend identity layer with delegation validation/persistence, fallback paths when biometrics unavailable, and automated backup reminders.
- Finalize `SyncCoordinator` so it consumes reducer output, updates Core Data on the main actor, and invalidates feeds/player/editor when remote data changes.
- Surface `RelayDirectory` management in Parent Zone settings (add/remove/toggle relays) with health indicators, and ensure `SyncCoordinator` refreshes subscriptions on edits.
- Finish remote share UX: enable decrypt/download actions from the "Shared With You" shelf and propagate delete/revoke handling into Player/Editor flows.
- Expand the new Parent Zone share flow with recipient presets, share history, revoke/delete fan-out, and download hooks into player/editor.
