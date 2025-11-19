# MyTube — Protocol & Product Specification (MVP)

This document captures the complete protocol, crypto, storage, and product requirements agreed for MyTube. Treat it as the canonical source of truth for client, control-plane, and premium-feature implementations.

> **Note (2026-03):** All messaging now flows through MDK/Marmot groups. The payload schemas below map to `MarmotMessageKind` values and travel inside MLS-encrypted rumors that `MarmotShareService` produces and `MarmotTransport` publishes (gift-wrapped via NIP-59 when required). See `Docs/mdk.md` for up-to-date MDK usage and the planned Safety HQ group for moderation traffic.

---

## 0. Summary

- **Client:** iPad-only SwiftUI app focused on local-first creation and playback.
- **Control plane:** Public Nostr relays (default `wss://no.str.cr`; users can manage relay list).
- **Graph & safety:** Cross-family sharing requires bilateral parent-approved follows.
- **Media plane:** Blobs live in MinIO, encrypted client-side. Nostr only carries encrypted metadata and wrapped keys.
- **Deletion:** Owners can revoke and delete; all clients must hide and purge on receipt.
- **Monetization:** Free tier is local-only. Premium ($20/year) unlocks encrypted upload, sharing, and sync.

---

## 1. Identities, Keys, and Parent-Only Model

### Identity Model (Updated Nov 2025)
- **Parent/Household:** Holds a single Nostr keypair (`npub`/`nsec`). This identity joins Marmot groups and signs all outbound events.
- **Child Profile:** Local-only profile with UUID, display name, theme, and avatar. NO separate Nostr key. Children are metadata in video payloads.

### Key Rules
- **Only parents have keys**: Generated via `nostr-sdk-swift`, stored in Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- **Children identified by UUID**: Profile IDs (128-bit UUIDs) used as stable identifiers in video share messages.
- **NIP-26 delegations**: DEPRECATED. Previously used for child devices; no longer needed since children don't have keys.
- **Group membership**: Only parent pubkeys appear in Marmot groups. Children never join groups directly.

---

## 2. Relays
- Default relay list:
  - `wss://no.str.cr` (primary, user-editable)
  - Ship 3–5 extra public relays for resilience.
- Behavior:
  - Publish and subscribe to all configured relays.
  - Dedupe by event ID.
  - Backoff and retry on publish; cache latest replaceables per `d` tag.

---

## 3. Cryptography

### Marmot Messaging
- MDK maintains MLS sessions per child group; `MarmotShareService` encodes payloads as JSON, calls `mdk.createMessage`, and tags them with the appropriate `MarmotMessageKind` (`kind 4543`–`4547`).
- Rumor events are published via `MarmotTransport` to every relay backing the child’s group. Gift wraps (NIP-59) are only used for welcomes so new members can decrypt `welcomeRumorsJson`.
- Messaging now exclusively uses MDK/MLS; confidentiality and membership enforcement live there.

### Media Encryption (Blobs)
- Per-video content key `Vk`: 32 random bytes.
- Cipher: XChaCha20-Poly1305 (IETF) with 24-byte random nonce.
- Encrypt MP4 and JPEG thumb separately; outputs `nonce || ciphertext || tag`.
- Store both outputs as `.enc` objects in MinIO.

### Key Wrapping (Per Recipient)
- KEM: X25519 (ECDH) between sender’s ephemeral key `Es` and recipient pubkey `Pr`.
- KDF: HKDF-SHA256 (`info = "mytube:wrap:Vk:v1"`, `salt = 32` random bytes `wrap_salt`).
- AEAD: ChaCha20-Poly1305 with 12-byte random `wrap_nonce`.
- Produce `key_wrapped = AEAD(Kwrap, Vk)`; include `Es`, `wrap_salt`, `wrap_nonce`.
- Algorithm identifiers:
  - `"alg_media": "xchacha20poly1305_v1"`
  - `"alg_wrap":  "x25519-hkdf-chacha20poly1305_v1"`

Rationale: XChaCha for long nonces and robust file encryption; X25519 + HKDF for portable wrapping.

---

## 4. Namespaces, Kinds, and Tags

- Reserve the `mytube/*` namespace for payload `t` fields encoded inside Marmot application messages.
- Use NIP-33 replaceables where we still need public pointers.

### Replaceable (NIP-33) Kinds
- **kind 30301 — Child follow pointer**: DEPRECATED. Follow relationships replaced by MDK group membership.
- **kind 30302 — Video tombstone**
  - `d = "mytube/video:<video_id>"`.
  - Published when video is deleted to notify all group members.

Replaceables carry no PII; they provide "latest pointer" handles.

### Marmot Core Event Kinds
- **kind 443 — Key package** (`MarmotEventKind.keyPackage`)
- **kind 444 — Welcome rumor** (`MarmotEventKind.welcome`)
- **kind 445 — Group commit** (`MarmotEventKind.group`)
- **kind 1059 — Gift wrap** (`MarmotEventKind.giftWrap`)

### Marmot Application Message Kinds
These are the `MarmotMessageKind` values produced by `MarmotShareService`:
- **kind 4543 — Video share**
- **kind 4544 — Video revoke**
- **kind 4545 — Video delete**
- **kind 4546 — Like**
- **kind 4547 — Report**

---

## 5. Marmot Payload Schemas

All Marmot payloads include:
- `ts` — Unix seconds
- `by` — `npub` of signer (parent or delegated child key)
- Optional `v` (e.g. `"v": 1`) for forward compatibility.

### 5.1 Follow Messages - DEPRECATED

**Follow relationships have been removed** in favor of MDK group membership. The social graph is now determined entirely by who is in which Marmot groups.

**Migration**: Fresh installs required. No backward compatibility with follow-based builds.

**Replacement**: Use MDK APIs directly:
- `mdkActor.getGroups()` - list all groups the parent is in
- `mdkActor.getMembers(inGroup:)` - see who's in each group
- `groupMembershipCoordinator.addMembers()` - invite another family
- `groupMembershipCoordinator.removeMembers()` - remove a family

### 5.2 Video Share (Parent-Only Groups)
- Type: `t = "mytube/video_share"`
- Recipients: All members of the child profile's associated Marmot group (parent identities only).
- Author: Always the parent's key, with child metadata in payload.

```json
{
  "t": "mytube/video_share",
  "video_id": "uuid-v4",
  "owner_child": "profile-uuid-without-dashes",
  "child_name": "Emma",
  "child_profile_id": "uuid-v4-of-profile",
  "meta": { "title": "optional", "dur": 94, "created_at": 1730000200 },
  "blob": { "url": "https://minio.example.com/media/x/y/z.mp4.enc", "mime": "video/mp4", "len": 12345678 },
  "thumb": { "url": "https://minio.example.com/thumbs/x/y/z.jpg.enc", "mime": "image/jpeg", "len": 54321 },
  "crypto": {
    "alg_media": "xchacha20poly1305_v1",
    "nonce_media": "base64-24B",
    "media_key": "base64-32B"
  },
  "policy": { "visibility": "followers", "expires_at": null, "version": 1 },
  "by": "npubParent",
  "ts": 1730000300,
  "v": 1
}
```

**Changes from previous version**:
- `owner_child`: Now contains child profile UUID (32 hex chars) instead of child npub (64 hex chars)
- `child_name`: New field for display purposes ("From: Family – Emma (7)")
- `child_profile_id`: Explicit UUID for client-side correlation
- `crypto.wrap`: Removed - MLS handles encryption, no per-recipient wrapping needed
- `by`: Always parent npub (children don't sign)

### 5.3 Video Revoke (stop showing)
- Type: `t = "mytube/video_revoke"`
- Recipients: prior recipients (viewer child devices + their parents) and owner parents (same MDK group fan-out).

```json
{
  "t": "mytube/video_revoke",
  "video_id": "uuid-v4",
  "reason": "parent_deleted | owner_request | policy_violation",
  "by": "npubSignerParent",
  "ts": 1730000400
}
```

### 5.4 Video Delete (purge caches)
- Type: `t = "mytube/video_delete"`
- Recipients: same broadcast set as revoke.

```json
{
  "t": "mytube/video_delete",
  "video_id": "uuid-v4",
  "by": "npubSignerParent",
  "ts": 1730000500
}
```

Client must purge feed entries and local decrypted files immediately.

### 5.5 Like
- Type: `t = "mytube/like"`
- Recipients: owner child device and owner parents.

```json
{
  "t": "mytube/like",
  "video_id": "uuid-v4",
  "viewer_child": "npubChildViewer",
  "by": "npubSignerParentOrDelegatedChild",
  "ts": 1730000600
}
```

### 5.6 Report
- Type: `t = "mytube/report"`
- Recipients: both families’ parents and, once online, the Safety HQ moderator group.

```json
{
  "t": "mytube/report",
  "video_id": "uuid-v4",
  "subject_child": "npubChildSubject",
  "reason": "string",
  "by": "npubSignerParent",
  "ts": 1730000700
}
```

---

## 6. Client State Machines

### 6.1 Follow (pointers + MDK)
- Maintain latest kind `30301` per child pair for discoverability.
- Active when:
  1. Latest follow Marmot payload shows `approved_from=true` and `approved_to=true`.
  2. MDK reports the remote child’s `mlsGroupId` membership (no newer `revoked` or `blocked`).

### 6.2 Video Lifecycle
- `local_only` → (Premium) share: enqueue `video_share` Marmot messages per eligible group.
- Revoke: send `video_revoke`; clients hide immediately.
- Delete: hard delete blobs, send `video_delete`; clients purge caches.
- Optional: publish kind `30302` tombstone for convergence.

---

## 7. MinIO (Blob Storage) Contracts

### Buckets & Keys
- Bucket: `mytube`.
- Keys:
  - Videos: `media/<ownerChildPrefix>/<video_id>.mp4.enc`
  - Thumbs: `thumbs/<ownerChildPrefix>/<video_id>.jpg.enc`
- `ownerChildPrefix` can be first 16 chars of child `npub`.

### Helper HTTP API (minimal)
- Hosted service with minimal logic; primarily storage.

#### `POST /upload/init`
- Request: `{"video_id":"uuid","owner_child":"npubChildOwner","size":12345678,"mime":"video/mp4"}`
- Response: `{"put_url":"...","key":"media/...mp4.enc","thumb_put_url":"...","thumb_key":"thumbs/...jpg.enc","expires_in":600}`

#### `POST /upload/commit`
- Request: `{"video_id":"uuid","key":"media/...mp4.enc","thumb_key":"thumbs/...jpg.enc"}`
- Response: `204`

#### `DELETE /media`
- Request: `{"key":"media/...mp4.enc","thumb_key":"thumbs/...jpg.enc"}`
- Response: `204`

#### `GET /media/sign` (optional if bucket private)
- Request: `{"key":"media/...mp4.enc"}`
- Response: `{"url":"https://...","expires_in":600}`

Auth: Parent JWT or NIP-98 signed HTTP (recommended).

Deletion semantics: hard delete both objects; future GETs return 404. The `video_delete` Marmot message instructs clients to purge.

---

## 8. Paywall & Gating

- **Free:** Local features only; no `/upload/*`; cannot send `video_share` Marmot messages. Receiving shares requires Premium as well — cloud features require Premium on at least the recipient device’s parent account.
- **Premium ($20/year):**
  - `/upload/*` enabled.
  - Send/receive `video_share` Marmot messages.
  - Multi-device sync for a family.
- Enforcement: StoreKit subscription check on device; hide cloud features when inactive. No backend receipt validation required unless desired.

---

## 9. Rate Limits (Client-Enforced)

- Follow requests: 10/day per child.
- Approvals: 50/day per parent.
- Uploads: 20/day per child.
- Likes: 120/hour per child.
- Publish to ≤6 relays per event.

---

## 10. Sequences (End-to-End)

### 10.1 Follow X → Y
1. Parent of X sends `mytube/follow` Marmot payload with `approved_from=true`.
2. Parent of Y sends the matching payload with `approved_to=true`.
3. Both approvals recorded in MDK ⇒ follow active.

### 10.2 Share a Video
1. App (Premium) generates `Vk`, encrypts MP4/JPG (XChaCha20-Poly1305), uploads via `/upload/init` → PUT → `/upload/commit`.
2. Compute eligible recipients = active followers of owner child (`mlsGroupId` membership).
3. For each group, send a `video_share` Marmot message (with wrapped key and URLs).
4. Recipient downloads ciphertext (signed GET if private), unwraps `Vk`, decrypts, and plays.

### 10.3 Delete a Video
1. Owner parent selects delete (PIN gated).
2. Send `video_revoke` Marmot messages (broadcast).
3. Call `DELETE /media`.
4. Send `video_delete` Marmot messages (broadcast).
5. Optional: publish `30302` tombstone. Clients purge caches on receipt.

---

## 11. Client Responsibilities

- Keep all Marmot payloads inside MDK (MLS handles encryption); no child IDs exposed publicly beyond replaceable IDs.
- Verify signatures on every event and NIP-26 delegations for child-signed actions.
- Track recipient list at share time for revoke/delete fan-out.
- Converge on latest replaceable per `d` tag (last-writer-wins by `created_at`, relay ID tie-breaker).
- Respect delete: purge decrypted files and thumbnails on `video_delete`.
- Keep ranking engine fully on-device; no server ranking.

---

## 12. Safety & App Store Notes

- Cross-family connections require two parent approvals; no discovery/search/public timelines.
- All media is E2EE; relays/storage never see plaintext.
- Parents can report/block; clients hide content immediately.
- Provide “How MyTube protects your child” explainer in Settings.

---

## 13. QA Checklist

1. **Graph:** A↔B active; A1→B1 follow becomes active only after both approvals.
2. **Share:** A1 shares; B1 receives Marmot message, decrypts via MDK, downloads, decrypts, plays.
3. **Delete:** A1 deletes; revoke Marmot message hides; blob delete; delete Marmot message purges; subsequent GET returns 404.
4. **Offline:** B1 offline during delete; on reconnect, receives delete Marmot message and purges.
5. **Block:** Family B blocks A; new shares stop; old items hidden on next sync.
6. **Relays:** With one relay down, events still converge through others.
7. **Paywall:** Free tier cannot upload/share; Premium unlocks; UI reflects state.
8. **Delegation:** Child device limited to delegated kinds per NIP-26.

---

## 14. Open Items to Document (Implementation-Time)

- Final public relay list to ship alongside `wss://no.str.cr`.
- StoreKit product identifiers and family sharing policy copy.
- Error and toast strings (e.g., “Item deleted by owner”, “Waiting for both parents to approve”).
