# MyTube — Protocol & Product Specification (MVP)

This document captures the complete protocol, crypto, storage, and product requirements agreed for MyTube. Treat it as the canonical source of truth for client, control-plane, and premium-feature implementations.

---

## 0. Summary

- **Client:** iPad-only SwiftUI app focused on local-first creation and playback.
- **Control plane:** Public Nostr relays (default `wss://no.str.cr`; users can manage relay list).
- **Graph & safety:** Cross-family sharing requires bilateral parent approvals (family link plus child follow).
- **Media plane:** Blobs live in MinIO, encrypted client-side. Nostr only carries encrypted metadata and wrapped keys.
- **Deletion:** Owners can revoke and delete; all clients must hide and purge on receipt.
- **Monetization:** Free tier is local-only. Premium ($20/year) unlocks encrypted upload, sharing, and sync.

---

## 1. Identities, Keys, Delegation

### Roles
- **Parent:** Owns decisions; authenticates actions; holds a Nostr keypair (`npub`/`nsec`).
- **Child device:** Own keypair; delegated by a parent via NIP-26 (restricted kinds and time-bound).

### Key Rules
- Parents store keys in Secure Enclave and expose read-only `npub` in UI for linking.
- Delegation (NIP-26): parent issues delegation to child device key.
  - Example conditions: `kind=14`, `since=<now-1d>`, `until=<now+365d>`, optional `kind=30301` if child publishes follow requests; otherwise approvals stay on parent.
- Apps must verify delegations for every child-signed event.

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

### Message & Envelope Encryption
- NIP-44 encrypted DMs (`kind 14`) with compliant framing. Library choice is flexible.

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

- Reserve `mytube/*` namespace for payload types inside DMs.
- Use NIP-33 replaceables.

### Replaceable (NIP-33) Kinds
- **kind 30300 — Family link pointer**
  - `d = "mytube/family-link:<A_hash>:<B_hash>"` (ordered pair; `hash` is stable hash of parent `npub` set per family).
- **kind 30301 — Child follow pointer**
  - `d = "mytube/follow:<followerChildPub>:<targetChildPub>"`.
- **kind 30302 — Video tombstone (optional)**
  - `d = "mytube/video:<video_id>"`.

Replaceables carry no PII; they provide “latest pointer” handles. Status details reside in encrypted DMs only.

### DM Kind
- **kind 14 — NIP-44 encrypted DMs**
  - Use `p` tags for each recipient `npub`.
  - Encrypted content uses JSON payload schemas below.

---

## 5. Encrypted DM Payload Schemas

All payloads include:
- `ts` — Unix seconds
- `by` — `npub` of signer (parent or delegated child key)
- Optional `v` (e.g. `"v": 1`) for forward compatibility.

### 5.1 Family Link (bilateral prerequisite)
- Type: `t = "mytube/family_link"`
- Recipients: all parents of both families.

```json
{
  "t": "mytube/family_link",
  "pair": ["npubParentA1","npubParentB1"],
  "status": "pending_a | pending_b | active | revoked | blocked",
  "by": "npubSignerParent",
  "ts": 1730000000
}
```

Rules:
- Side “A” posts `pending_b` (“await B approval”) or vice versa.
- Side “B” posts `active` to activate.
- Either side may post `revoked` or `blocked`.

### 5.2 Child Follow (two approvals: from / to)
- Type: `t = "mytube/follow"`
- Recipients: all parents of both families.

```json
{
  "t": "mytube/follow",
  "follower_child": "npubChildX",
  "target_child":   "npubChildY",
  "approved_from": true,
  "approved_to":   false,
  "status": "pending | active | revoked | blocked",
  "by": "npubSignerParent",
  "ts": 1730000100
}
```

Rules:
- Follower’s parent sets `approved_from = true`.
- Target’s parent sets `approved_to = true`.
- When both are true and the family link is active, the follow becomes `active`.
- Either side may set `revoked` or `blocked`.

### 5.3 Video Share (per recipient)
- Type: `t = "mytube/video_share"`
- Recipients: viewer child device key and that child’s parents.

```json
{
  "t": "mytube/video_share",
  "video_id": "uuid-v4",
  "owner_child": "npubChildOwner",
  "meta": { "title": "optional", "dur": 94, "created_at": 1730000200 },
  "blob": { "url": "https://minio.example.com/media/x/y/z.mp4.enc", "mime": "video/mp4", "len": 12345678 },
  "thumb": { "url": "https://minio.example.com/thumbs/x/y/z.jpg.enc", "mime": "image/jpeg", "len": 54321 },
  "crypto": {
    "alg_media": "xchacha20poly1305_v1",
    "nonce_media": "base64-24B",
    "alg_wrap": "x25519-hkdf-chacha20poly1305_v1",
    "wrap": {
      "ephemeral_pub": "npubEs",
      "wrap_salt": "base64-32B",
      "wrap_nonce": "base64-12B",
      "key_wrapped": "base64"
    }
  },
  "policy": { "visibility": "followers", "expires_at": null, "version": 1 },
  "by": "npubSignerParentOrDelegatedChild",
  "ts": 1730000300,
  "v": 1
}
```

### 5.4 Video Revoke (stop showing)
- Type: `t = "mytube/video_revoke"`
- Recipients: prior recipients (viewer child devices + their parents) and owner parents.

```json
{
  "t": "mytube/video_revoke",
  "video_id": "uuid-v4",
  "reason": "parent_deleted | owner_request | policy_violation",
  "by": "npubSignerParent",
  "ts": 1730000400
}
```

### 5.5 Video Delete (purge caches)
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

### 5.6 Like
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

### 5.7 Report
- Type: `t = "mytube/report"`
- Recipients: both families’ parents and a moderator `npub` controlled by us.

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

### 6.1 Family Link (pointer + DM)
- Maintain latest kind `30300` for the parent pair.
- Effective state derives from latest DM signed by the other family’s parent.
- Link is active only if no `blocked`/`revoked` newer than the `active` event.

### 6.2 Follow (pointer + DM)
- Maintain latest kind `30301` per child pair.
- Active when:
  1. Family link is active.
  2. Latest follow DM shows `approved_from=true` and `approved_to=true`.
  3. No newer `revoked` or `blocked`.

### 6.3 Video Lifecycle
- `local_only` → (Premium) share: send per-recipient `video_share` DMs.
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

Deletion semantics: hard delete both objects; future GETs return 404. The `video_delete` DM instructs clients to purge.

---

## 8. Paywall & Gating

- **Free:** Local features only; no `/upload/*`; cannot send `video_share` DMs. Receiving shares requires Premium as well — cloud features require Premium on at least the recipient device’s parent account.
- **Premium ($20/year):**
  - `/upload/*` enabled.
  - Send/receive `video_share` DMs.
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

### 10.1 Link Families
1. Parent A sends `family_link` DM `pending_b` to B’s parents; optionally publish pointer `30300`.
2. Parent B sends `family_link` DM `active`; clients mark link active.

### 10.2 Follow X → Y
1. Parent of X sends follow DM with `approved_from=true`.
2. Parent of Y sends follow DM with `approved_to=true`.
3. Both true and link active ⇒ follow active.

### 10.3 Share a Video
1. App (Premium) generates `Vk`, encrypts MP4/JPG (XChaCha20-Poly1305), uploads via `/upload/init` → PUT → `/upload/commit`.
2. Compute eligible recipients = active followers of owner child.
3. For each recipient, send `video_share` DM (with wrapped key and URLs).
4. Recipient downloads ciphertext (signed GET if private), unwraps `Vk`, decrypts, and plays.

### 10.4 Delete a Video
1. Owner parent selects delete (PIN gated).
2. Send `video_revoke` DMs (broadcast).
3. Call `DELETE /media`.
4. Send `video_delete` DMs (broadcast).
5. Optional: publish `30302` tombstone. Clients purge caches on receipt.

---

## 11. Client Responsibilities

- Encrypt all DM payloads (NIP-44); no child IDs exposed publicly beyond replaceable IDs.
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
2. **Share:** A1 shares; B1 receives DM, decrypts envelope, downloads, decrypts, plays.
3. **Delete:** A1 deletes; revoke DM hides; blob delete; delete DM purges; subsequent GET returns 404.
4. **Offline:** B1 offline during delete; on reconnect, receives delete DM and purges.
5. **Block:** Family B blocks A; new shares stop; old items hidden on next sync.
6. **Relays:** With one relay down, events still converge through others.
7. **Paywall:** Free tier cannot upload/share; Premium unlocks; UI reflects state.
8. **Delegation:** Child device limited to delegated kinds per NIP-26.

---

## 14. Open Items to Document (Implementation-Time)

- Final public relay list to ship alongside `wss://no.str.cr`.
- StoreKit product identifiers and family sharing policy copy.
- Error and toast strings (e.g., “Item deleted by owner”, “Waiting for both parents to approve”).

