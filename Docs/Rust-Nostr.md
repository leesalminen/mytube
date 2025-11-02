The following documentation is extracted from the "Rust Nostr Book," focusing on the core API usage, excluding introductory, getting started, and donation sections. Code examples are provided in **Swift** as it had the most complete code blocks in the source material.

---

## Keys and Signers

The `rust-nostr` library provides methods for generating and handling Nostr key pairs.

### Generate New Random Keys

A new key pair can be generated using the `Keys.generate()` method.

```swift
func generate() throws {
    let keys = Keys.generate()
    let publicKey = keys.publicKey()
    let secretKey = keys.secretKey()

    print("Public key (hex): \(publicKey.toHex())")
    print("Secret key (hex): \(secretKey.toHex())")

    print("Public key (bech32): \(try publicKey.toBech32())")
    print("Secret key (bech32): \(try secretKey.toBech32())")
}
```

### Keys Parsing

An existing secret key can be restored using the `Keys.parse()` method.

```swift
func restore() throws {
    let keys = try Keys.parse(secretKey:
        "nsec1j4c6269y9w0q2er2xjw8sv2ehyrtfxq3jwgdlxj6qfn8z4gjsq5qfvfk99")

    let publicKey = keys.publicKey()

    print("Public key: \(try publicKey.toBech32())")
}
```

### Signers

Signers are used to sign events. The `NostrSigner` can be constructed from `Keys`, a `Browser Extension`, or `Nostr Connect`.

| Signer Type | Status |
| :--- | :--- |
| **Keys** | Implemented |
| **Browser Extension** | Documented, functionality implicit in usage |
| **Nostr Connect** | Documented, functionality implicit in usage |

---

## Client Management and Publishing Events

The `Client` manages connections to Nostr relays and is used to send and fetch events.

### Client Construction

A client is typically constructed with a `NostrSigner` to enable publishing signed events.

```swift
let keys = Keys.generate()
let signer = NostrSigner.keys(keys: keys)
let client = Client(signer: signer)
```

### Add Relays and Connect

Relays must be added and connected to the client before they can be used.

```swift
let relayUrl = try RelayUrl.parse(url: "wss://relay.damus.io")
try await client.addRelay(url: relayUrl)
await client.connect()
```

### Publishing a Text Note

Events are constructed using the `EventBuilder`, signed implicitly by the client's signer, and then published.

```swift
let builder = EventBuilder.textNote(content: "Hello, rust-nostr!")
let output = try await client.sendEventBuilder(builder: builder)

// Inspect the output
print("Event ID: \(try output.id.toBech32())")
print("Sent to: \(output.success)")
print("Not sent to: \(output.failed)")
```

---

## Event Building and Signing

The `EventBuilder` is the primary mechanism for composing Nostr events.

### Construct Standard Events (e.g., Text Note)

```swift
let builder1 = EventBuilder.textNote(content: "Hello")
```

### Customizing the Event Builder

The builder allows for customizations such as setting tags, proof-of-work (PoW) difficulty, or a fixed timestamp.

```swift
let tag = Tag.alt(summary: "POW text-note")
let timestamp = Timestamp.fromSecs(secs: 1737976769)
let builder2 = EventBuilder.textNote(content: "Hello with POW")
    .tags(tags: [tag])
    .pow(difficulty: 20)
    .customCreatedAt(createdAt: timestamp)
```

### Constructing Non-Standard Events

The default `EventBuilder` constructor can be used for custom kinds.

```swift
let kind = Kind(kind: 33001)
let builder3 = EventBuilder(kind: kind, content: "My custom event")
```

### Building and Signing the Event

The `EventBuilder` is used with a `NostrSigner` to produce a finalized, signed `Event`.

```swift
let event = try await builder.sign(signer: signer)
print(try event.asJson())
```

---

## Requesting Events

The library supports various methods for retrieving events from connected relays.

### Fetching Events

The `fetchEvents` method requests events based on a `Filter` and waits until all relays return a result or a timeout is reached.

**1. Initialize Client for Fetching (Signer is usually optional):**

```swift
let client = Client()
let relayUrl = try RelayUrl.parse(url: "wss://relay.damus.io")
try await client.addRelay(url: relayUrl)
await client.connect()
```

**2. Perform Fetch:**

```swift
let filter1 = Filter().kind(kind: Kind.fromStd(e:
    KindStandard.metadata)).limit(limit: 3)
let events1 = try await client.fetchEvents(filter: filter1, timeout: 10.0)
```

**3. Fetch from Specific Relays:**

```swift
let filter2 = Filter().kind(kind: Kind.fromStd(e:
    KindStandard.textNote)).limit(limit: 5)
let events2 = try await client.fetchEventsFrom(
    urls: [relayUrl],
    filter: filter2,
    timeout: 10.0
)
```
*Note: The specified relays must be already added and connected.*

### Other Request Methods

| Method | Description | Implementation Status (in provided Swift examples) |
| :--- | :--- | :--- |
| **Streaming** | Request and immediately receive events; terminate the stream when all relays satisfy the exit condition. | TODO: not supported yet |
| **Syncing** | Execute a negentropy reconciliation, which requests only missing events. | TODO |
| **Subscribing** | Create a long-lived subscription to receive events in real-time. | TODO |

---

## Core NIP Implementations

### NIP-44: Encrypted Payloads (Versioned)

This NIP defines a versioned scheme for encrypting event payloads.

```swift
import NostrSDK
// ...
func nip44() throws {
    let keys = Keys.generate()
    let publickey = try PublicKey.parse(publicKey:
        "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")

    let ciphertext = try nip44Encrypt(secretKey: keys.secretKey(), publicKey:
        publickey, content: "my message", version: Nip44Version.v2)
    print("Encrypted: \(ciphertext)");

    let plaintext = try nip44Decrypt(secretKey: keys.secretKey(), publickey:
        publickey, payload: ciphertext)
    print("Decrypted: \(plaintext)");
}
```

### NIP-49: Private Key Encryption

This NIP defines a method for clients to encrypt and decrypt a user's private key with a password (`ncryptsec`).

**1. Encrypt a Secret Key:**

```swift
let secretKey = try SecretKey.parse(secretKey:
    "3501454135014541350145413501453fefb02227e449e57cf4d3a3ce05378683")

let password = "nostr"
let encrypted = try secretKey.encrypt(password: password)

// Custom encryption settings
let encryptedCustom = try EncryptedSecretKey(secretKey: secretKey, password:
    password, logN: 12, keySecurity: KeySecurity.weak)

print("Encrypted secret key: \(try encrypted.toBech32())")
print("Encrypted secret key (custom): \(try encryptedCustom.toBech32())")
```

**2. Decrypt a Secret Key:**

```swift
let encrypted = try EncryptedSecretKey.fromBech32(bech32:
    "ncryptsec1qgg9947rlpvqu76pj5ecreduf9jxhselq2nae2kghhvd5g7dgjtcxfqtd67p9m0w57lspw8gsq6yphnm8623nsl8xn9j4jdzz84zm3frztj3z7s35vpzmqf6ksu8r89qk5z2zxfmu5gv8th8wclt0h4p"
)

let secretKey = try encrypted.decrypt(password: "nostr")
print("Decrypted secret key: \(try secretKey.toBech32())")
```

### NIP-65: Relay List Metadata

This NIP is used to construct events of **Kind 10002** (Relay List Metadata) to advertise a user's preferred relays.

*   Use the `EventBuilder` struct and associated `relay_list()` function.
*   Alternatively, use the `Tag` struct and associated `relay_metadata()` function.

---

## Filters

Filters are JSON objects used in web-socket subscription models to specify criteria for events, including `ids`, `authors`, `kinds`, single-letter `tags`, timestamps (`since`/`until`), and a record `limit`.

The section on `Create Filters`, `Modify Filters`, and `Other Filter Operations` in the source documentation is marked as **TODO**. An example of Filter creation is available in the fetching section:

```swift
let filter1 = Filter().kind(kind: Kind.fromStd(e: KindStandard.metadata)).limit(limit: 3)
```

---

## Core Data Structures

### Event ID

An Event ID is the 32-byte lowercase hex-encoded SHA-256 hash of the serialized event data (excluding the signature), as defined by [NIP-01](https://github.com/nostr-protocol/nips).

The sections on **Creation, Formatting and Parsing** and **Access and Verify** for Event ID are marked as **TODO**.

### Kind

The `Kind` object, represented by an integer between 0 and 65535, signals to clients how to parse the event data. Common kinds include:
*   **Kind 0:** User metadata
*   **Kind 1:** Text Note
*   **Kind 3:** Following/Contact Lists

The sections on **Kind by Integer and Enum**, **Events and Kinds**, and **Logical Tests** are marked as **TODO**.

### Tag

Tags are a main element of Nostr events, allowing diverse functionality like referencing public keys (`p`), relays (`r`), or other events (`e`). Tags are an array of strings, where the first element is the tag name.

The `Tag` struct and `TagKind` enum are used to create and manipulate tag objects.

The sections on **Creating Tags**, and **Serializing and Logical Tests** are marked as **TODO**.

### Event JSON Serialization

**Deserialization**
```swift
let event = try Event.fromJson(json: originalJson)
```

**Serialization**
```swift
let json = try event.asJson()
```

---

## Other Nostr Implementation Proposals (NIPs)

The following NIPs are documented as part of the `rust-nostr` library but are marked as **TODO** for implementation examples in the provided Swift documentation:

| NIP | Title | Description |
| :--- | :--- | :--- |
| **NIP-01** | Basic protocol flow description | Defines the core protocol flow (User metadata section is **TODO**). |
| **NIP-05** | Mapping Nostr keys to DNS-based internet identifiers | Allows using a DNS-based internet identifier (e.g., `user@domain.com`) as metadata. |
| **NIP-06** | Basic key derivation from mnemonic seed phrase | Defines deriving Nostr keys from a mnemonic seed phrase using BIP-32 and BIP-39. |
| **NIP-07** | `window.nostr` capability for web browsers | Standardizes browser extension capabilities. |
| **NIP-17** | Private Direct Messages | Defines an encrypted direct messaging scheme using NIP-44, NIP-59, and gift wraps. |
| **NIP-19** | bech32-encoded entities | Defines bech32 encoding for Nostr entities (e.g., `npub`, `nsec`, `note`, `nprofile`, `nevent`, `nrelay`, `naddr`). |
| **NIP-21** | nostr URI scheme | Defines the `nostr:` URI scheme for interoperability. |
| **NIP-46** | Nostr Remote Signing | (Nostr Connect) Protocol for remote signing. (**TODO**) |
| **NIP-47** | Nostr Wallet Connect | Protocol for connecting Nostr clients to a wallet. (**TODO**) |
| **NIP-59** | Gift Wrap | Used in Private Direct Messages. (**TODO**) |
