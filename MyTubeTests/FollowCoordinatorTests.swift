import XCTest
@testable import MyTube

@MainActor
final class FollowCoordinatorTests: XCTestCase {
    private var persistence: PersistenceController!
    private var profileStore: ProfileStore!
    private var relationshipStore: RelationshipStore!
    private var keyStore: KeychainKeyStore!
    private var identityManager: IdentityManager!
    private var cryptoService: CryptoEnvelopeService!
    private var nostrClient: StubNostrClient!
    private var relayDirectory: RelayDirectory!
    private var directMessageOutbox: DirectMessageOutbox!
    private var followCoordinator: FollowCoordinator!
    private var relayURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        persistence = PersistenceController(inMemory: true)
        profileStore = ProfileStore(persistence: persistence)
        relationshipStore = RelationshipStore(persistence: persistence)
        keyStore = KeychainKeyStore(service: "FollowCoordinatorTests.\(UUID().uuidString)")
        identityManager = IdentityManager(keyStore: keyStore, profileStore: profileStore)
        cryptoService = CryptoEnvelopeService()
        nostrClient = StubNostrClient()
        relayDirectory = RelayDirectory(userDefaults: UserDefaults(suiteName: "FollowCoordinatorTests-\(UUID().uuidString)")!)
        directMessageOutbox = DirectMessageOutbox(
            keyStore: keyStore,
            cryptoService: cryptoService,
            nostrClient: nostrClient,
            relayDirectory: relayDirectory
        )
        followCoordinator = FollowCoordinator(
            identityManager: identityManager,
            relationshipStore: relationshipStore,
            directMessageOutbox: directMessageOutbox,
            nostrClient: nostrClient,
            relayDirectory: relayDirectory
        )

        relayURL = URL(string: "wss://relay.example.com")!
    }

    override func tearDown() {
        followCoordinator = nil
        directMessageOutbox = nil
        relayDirectory = nil
        nostrClient = nil
        cryptoService = nil
        identityManager = nil
        keyStore = nil
        relationshipStore = nil
        profileStore = nil
        persistence = nil
        relayURL = nil
        super.tearDown()
    }

    func testRequestFollowSucceeds() async throws {
        await relayDirectory.addRelay(relayURL)
        try await nostrClient.connect(relays: [relayURL])

        let profile = try profileStore.createProfile(
            name: "Nova",
            theme: .ocean,
            avatarAsset: ThemeDescriptor.ocean.defaultAvatarAsset
        )
        let parentIdentity = try identityManager.generateParentIdentity(requireBiometrics: false)
        let childIdentity = try identityManager.ensureChildIdentity(for: profile)

        let remote = try makeRemoteIdentity()
        let remoteParentHex = remote.parent.publicKeyHex
        let remoteParentNpub = remote.parent.publicKeyBech32 ?? remoteParentHex

        let follow = try await followCoordinator.requestFollow(
            followerProfile: profile,
            targetChildKey: remote.child.publicKeyHex,
            targetParentKey: remoteParentNpub
        )

        XCTAssertEqual(follow.status, .pending)
        XCTAssertTrue(follow.approvedFrom)
        XCTAssertFalse(follow.approvedTo)

        let stored = try relationshipStore.fetchFollowRelationships()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.status, .pending)
        if let storedFollower = stored.first?.followerChild {
            let normalized = ParentIdentityKey(string: storedFollower)
            XCTAssertEqual(normalized?.hex.lowercased(), childIdentity.publicKeyHex.lowercased())
        } else {
            XCTFail("Expected stored follow to contain follower child key")
        }
    }

    private func makeRemoteIdentity() throws -> (parent: ParentIdentity, child: ChildIdentity) {
        let remotePersistence = PersistenceController(inMemory: true)
        let remoteProfileStore = ProfileStore(persistence: remotePersistence)
        let remoteKeyStore = KeychainKeyStore(service: "FollowCoordinatorTests.remote.\(UUID().uuidString)")
        let remoteIdentityManager = IdentityManager(keyStore: remoteKeyStore, profileStore: remoteProfileStore)

        let parent = try remoteIdentityManager.generateParentIdentity(requireBiometrics: false)
        let profile = try remoteProfileStore.createProfile(
            name: "Remote",
            theme: .forest,
            avatarAsset: ThemeDescriptor.forest.defaultAvatarAsset
        )
        let child = try remoteIdentityManager.ensureChildIdentity(for: profile)
        return (parent, child)
    }
}
