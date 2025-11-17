# MDK Refactor Plan

_Owner: Codex • Last updated: 2026-02-14_

This plan explains how we will replace the current NIP-44 / NIP-17 direct messaging implementation with Marmot (MLS over Nostr) using the `MDKBindings` package. It breaks the refactor into discrete phases so we can land incremental PRs safely even though we are effectively rebuilding the sharing graph and messaging stack. We do **not** need data migrations because we have no production users yet.

---

## 1. Goals, Scope, and Non-Goals

### Goals
- Swap every direct-message pathway (follow approvals, video shares, likes, reports, diagnostics) to use MDK groups and MLS-secured Marmot messages.
- Give each child their own Marmot group; parents approve new members (other families) via the MDK welcome flow; all sharing happens inside those groups.
- Keep a single source of truth for remote state inside the MDK SQLite store and mirror only UX-facing projections into Core Data (feed shelves, share history).
- Preserve the existing SwiftUI feature surface area (Home Feed, Capture, Editor, Parent Zone, etc.) while changing the underlying transport/storage layers.

### Out of Scope
- Shipping a bridging layer for legacy DMs. We will delete the old code paths instead of trying to interoperate.
- Server-side tooling or new control-plane endpoints. The app will continue to publish to public relays.
- Data export/migration tools—fresh installs suffice per product guidance.

---

## 2. Guiding Principles

1. **Single MDK actor** – instantiate `Mdk` once, keep it on a dedicated actor/serial queue, and expose async APIs to the rest of the app.
2. **Transport separation** – MDK produces/consumes JSON strings; Nostr remains the wire transport, so we need a thin “MarmotTransport” layer that knows how to publish MDK events and feed inbound events back into MDK.
3. **Feature isolation** – Feature modules (HomeFeed, ParentZone, etc.) should talk to domain-level coordinators (`GroupMembershipCoordinator`, `MarmotShareService`) rather than calling MDK directly.
4. **Deterministic data flow** – MDK owns MLS state; Core Data caches derived projections for UI. No circular writes (Core Data → MDK → Core Data).
5. **Observability first** – surface MDK stats (group count, pending welcomes, last sync) in Parent Zone so QA can validate the new stack quickly.

---

## 3. Target Architecture

```
SwiftUI Features ────────────────────────────────────────────┐
  (HomeFeed, Capture, ParentZone, Player, Editor, etc.)      │
                                                             │
Domain Coordinators ─────────────────────────────────────────┤
  GroupMembershipCoordinator, MarmotShareService,            │
  RemoteVideoStore, ParentAuth, RankingEngine                │
                                                             │
MDK Integration Layer ───────────────────────────────────────┤
  MdkActor (wraps MDKBindings)                               │
  MarmotTransport (NostrClient + MDK APIs)                   │
  MarmotProjectionStore (bridges MDK data → Core Data)       │
                                                             │
Infrastructure ──────────────────────────────────────────────┤
  NostrClient, RelayDirectory, StoragePaths, MinIOClient,    │
  PersistenceController, KeychainKeyStore                    │
```

- **MdkActor**: singleton actor that creates the MDK instance at `Application Support/MyTube/mdk.sqlite` (see `Docs/mdk.md` quick start). Provides async methods for group, welcome, and message APIs.
- **MarmotTransport**: owns all Nostr publish/subscribe logic for Marmot events. It requests outbound JSON from `Mdk` (`createGroup`, `addMembers`, `createMessage`) and publishes them via the existing `NostrClient`. It also ingests relay events (`key packages`, `welcome gift wraps`, `rumor messages`) and funnels them through MDK (`parseKeyPackage`, `processWelcome`, `mergePendingCommit`, etc.).
- **MarmotProjectionStore**: listens for MDK changes (polling or notifications) and updates Core Data entities used by the SwiftUI layers (remote videos, membership status, pending approvals).
- **GroupMembershipCoordinator**: replaces the legacy follow coordinator entirely. It orchestrates child group creation, invite approvals/removals via MDK, and surfaces state to Parent Zone.
- **MarmotShareService**: replaces `VideoSharePublisher`, `DirectMessageOutbox`, `LikePublisher`, and `ReportCoordinator` by writing share events through MDK (`createMessage`) and mapping replies back into Core Data shelves.

---

## 4. Work Breakdown (Phased)

Each phase is designed to land independently with CI + tests. We expect some phases to ship as multiple PRs; the bullets call out the concrete tasks/files to touch.

### Phase 0 – Repo hygiene & kill switches
1. **Freeze legacy DM surfaces**: wrap `DirectMessageOutbox`, `VideoSharePublisher`, `LikePublisher`, and `ReportCoordinator` behind feature flags so we can delete them after MDK replaces the functionality (the old follow DM actor has already been removed).
2. **Audit Core Data model**: identify entities used solely for DMs (`FollowEntity`, DM payload caches). Since no users exist, we can remove unused entities once the MDK projection layer is ready.
3. **Document kill plan**: add deprecation warnings in code comments pointing to this plan.

_Acceptance_: Feature flags compiled but default to “legacy” until MDK foundation is ready; no functional change yet.

### Phase 1 – MDK foundation
1. **MDK storage path**: extend `StoragePaths` to expose `mdkDatabaseURL` underneath `Application Support/MyTube` with `.completeFileProtection`.
2. **MdkActor**: new file `Services/Marmot/MdkActor.swift` that lazily instantiates `newMdk(dbPath:)`, exposes async wrappers for every MDK API we plan to use, and serializes calls via `actor` or `MainActor`.
3. **Dependency wiring**: update `AppEnvironment` to create `MdkActor` and thread it into a new `MarmotEnvironment` struct alongside `NostrClient`, `RelayDirectory`, `KeychainKeyStore`.
4. **Diagnostics hooks**: expose `MdkActor.stats()` (wrapping `getGroups`, `getPendingWelcomes`) for Parent Zone.

_Acceptance_: App compiles with MDK hooks; Parent Zone shows placeholder stats from MDK (even if empty). No legacy behavior removed yet.

### Phase 2 – Marmot transport bridge
1. **Outbound publishing**: implement `MarmotTransport.publish(eventJson: String)` that takes MDK-generated JSON (group creations, welcome rumors, MLS messages) and hands them to `NostrClient` with the correct kind/tags. Reuse existing relay selection/health logic.
2. **Inbound ingestion**: enhance `SyncCoordinator` or create `MarmotSubscriptionManager` to subscribe to all Marmot-relevant event kinds (key packages, welcomes, rumor messages). On receipt, pass raw JSON strings into MDK (`parseKeyPackage`, `processWelcome`, `acceptWelcome`, `createMessage`, etc.) per `Docs/mdk.md`.
3. **Welcome decisions**: add Parent Zone UI + service methods to list `getPendingWelcomes()` and call `acceptWelcome` / `declineWelcome`.
4. **Commit merging**: after publishing MDK evolution events, call `mergePendingCommit` to keep local MLS state healthy.

_Acceptance_: We can create MDK groups locally, publish the resulting events to relays, ingest them back (loopback), and see them represented in MDK’s `getGroups()` response.

### Phase 3 – Group + identity rewrite
1. **Child = Group**: when onboarding a child profile, automatically call `createGroup` with the child’s display name/description plus parent/child relays. Store the returned `Group` metadata alongside the `ChildProfile` entity (persist `mlsGroupId`).
2. **Invites + approvals**: replace follow requests with MDK `addMembers` + welcome fan-out. Parent Zone becomes the approval surface:
   - Outbound: choose another family → gather their key packages → `addMembers` → publish `evolutionEventJson` + `welcomeRumorsJson`.
   - Inbound: show pending welcomes from `Mdk.getPendingWelcomes()`; parent approves to call `acceptWelcome`.
3. **Access control**: remove `RelationshipStore` gating logic and derive share eligibility from MDK membership (group contains remote child/parent keys).
4. **Core Data alignment**: add `mlsGroupId` columns to relevant entities (e.g., `RemoteVideoEntity`, `FollowEntity` replacement) or create a new `GroupMembershipEntity` that mirrors MDK data for UI queries.

_Acceptance_: Parents can create groups per child, invite another family, see the invite pending, and accept it locally; the rest of the app still uses legacy sharing.

### Phase 4 – Share + messaging rewrite
1. **MarmotShareService**:
   - Wraps `createMessage(mlsGroupId:senderPublicKey:content:kind:)`.
   - Encodes the existing video/like/report payloads as JSON strings and writes them via MDK (✅ done: `DirectMessageOutbox` has been removed in favor of this service).
   - Returns the Nostr rumor event JSON so `MarmotTransport` can publish it.
2. **Remote video ingestion**:
   - Build `MarmotProjectionStore` that reads MDK state (`getGroups`, `getMessages`, `getMembers`) and mirrors the relevant data into Core Data (remote shelves, like counts, report states) so UI no longer depends on the retired DM reducer.
   - Keep `CryptoEnvelopeService.encrypt/decryptDirectMessage` only for NIP-59 gift wraps; the standalone DM envelope path has already been deleted.
3. **Backpressure + retries**: reuse `VideoShareCoordinator` queueing but swap the send primitive to `MarmotShareService`.

_Acceptance_: Sending a video share/like/report uses MDK; inbound events populate Core Data via the new MDK projection (the legacy DM services are now gone, so remote UX depends entirely on the projection layer landing).

### Phase 5 – UI + UX alignment
1. **Parent Zone**: show group membership, pending invites, per-child share stats sourced from MDK. Provide actions to revoke members (call `addMembers` with updated list or a forthcoming `removeMembers` API if MDK exposes one).
2. **Home Feed / Shared With You**: ensure remote shelves are powered by Marmot data; handle `Group.state` changes (paused, removed).
3. **Capture / Editor**: gating logic now depends on MDK membership (only allow sharing to groups where the recipient is active).
4. **Notifications + toasts**: update copy to reference “groups” instead of “follow approvals / DMs”.

_Acceptance_: All visible UI references MDK group concepts; QA can complete capture → share → parent approval → playback using the new stack.

### Safety Group – Moderation Channel
- Create a dedicated MDK group (working name: “Safety HQ”) that every parent joins during onboarding. Membership is read-only for parents; only the local device can post reports/escalations.
- When a parent submits a report/block, `ReportCoordinator` should fan the message out to:
  1. The child’s family group (for transparency) via `MarmotShareService`.
  2. The Safety HQ group so moderators (and future automation) receive a consistent feed with no DM fallback.
- Parent Zone needs UI to show the Safety HQ membership state (joined/pending) plus basic diagnostics (last sync, relay set).
- Moderation tooling can treat Safety HQ as the canonical inbox, which keeps all safety comms on the same MDK rails as family messaging.
- Open items: decide whether the Safety HQ group is global or per-region, determine how moderator keys are provisioned, and design the “leave / rejoin safety group” flows.

### Phase 6 – Cleanup
1. Delete unused files: `DirectMessageOutbox.swift`, `DirectMessageModels.swift`, DM-specific reducers/tests, `CryptoEnvelopeService` DM helpers, `RelationshipStore` follow-specific code, NIP-44 test suites. _(First wave complete: the DM outbox/models and reducer path are gone; remaining cleanup focuses on docs/tests.)_
2. Remove protocol/docs sections that reference NIP-44; update `Docs/Architecture.md` and `Docs/MyTubeProtocolSpec.md` to describe Marmot-based groups.
3. Audit entitlements and Info.plist for stale descriptions (e.g., “Direct Messages”).

_Acceptance_: No references to `DirectMessage*`, `NIP-44`, or DM “follow approvals” remain; build + tests pass.

---

## 5. Testing & Tooling Strategy

- **Unit tests**:
  - `MdkActorTests`: verify DB path creation, error propagation, and serialization (call MDK APIs using the xcframework in tests).
  - `MarmotTransportTests`: stub `NostrClient` to confirm publish payloads, ensure `mergePendingCommit` is invoked, validate error handling when relays are offline.
  - `MarmotShareServiceTests`: encode/decode messages, ensure `VideoShareCoordinator` queues retry on MDK errors.
  - `GroupMembershipCoordinatorTests`: simulate invite + accept flows, ensure Core Data projections match MDK membership.
- **Integration tests**:
  - Launch an in-memory MDK instance pointing at a temporary file, simulate two parents exchanging welcomes, and assert Core Data updates.
  - End-to-end UI test: capture video → share to group → accept welcome → download/playback.
- **Tooling**:
  - Add a `just mdk-reset` helper that deletes the MDK DB for local clean-room testing.
  - Extend the existing relay diagnostics panel to display MDK metrics (group count, pending welcomes, last sync timestamp).

---

## 6. Open Questions

1. **Member removal**: MDK doc references `addMembers` but not `removeMembers`. Need to confirm via the upstream Marmot repo whether removing members requires a manual `createCommit` API or if we call `addMembers` with a “removal” variant. Track this before Phase 5.
2. **Inbound message projection**: Do we rely solely on MDK’s SQLite for persistence, or continue duplicating key fields into Core Data for SwiftUI fetch controllers? Proposed approach is to project (denormalize) into Core Data for now to avoid rewriting every view to query MDK synchronously.
3. **Push/poll cadence**: MDK is synchronous and not thread-safe. We plan to poll `getMessages` / `getGroups` whenever `MarmotTransport` ingests new relay events, but we may need a background refresh timer if relays deliver events while the app is suspended.
4. **Key package distribution**: We need UX for exporting MDK key packages (likely piggyback on existing Parent Zone QR flow). Design is pending.

---

## 7. Next Steps

1. Land Phase 0 + Phase 1 scaffolding (storage path, `MdkActor`, dependency wiring) behind feature flags.
2. Build the Marmot transport (Phase 2) and add loopback integration tests so we trust MDK event handling before touching feature modules.
3. Coordinate with design for the new group-centric Parent Zone experience before starting Phase 3 UI work.

Once these steps are complete we can start slicing the actual implementation work per feature (shares, likes, reports, approvals) knowing the MDK plumbing is stable.

---

_References_: `Docs/mdk.md`, `https://github.com/parres-hq/marmot`, `swift/MDKPackage` sources.
