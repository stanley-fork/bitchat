//
// ChatPeerIdentityCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `ChatPeerIdentityCoordinator` against a mock
// `ChatPeerIdentityContext` — proving the coordinator works without a
// `ChatViewModel`, following the `ChatDeliveryCoordinatorContextTests` /
// `ChatPrivateConversationCoordinatorContextTests` exemplars.
//
// Scope note: flows that hit the `FavoritesPersistenceService.shared`
// singleton (`isFavorite` / `toggleFavoriteForNoiseKey` / favorite
// notifications / `nicknameForPeer` fallbacks) remain covered by the full
// view-model tests; the session, migration, encryption-status, and nickname
// resolution flows are covered here.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Mock Context

/// Lightweight stand-in for `ChatPeerIdentityContext` proving that
/// `ChatPeerIdentityCoordinator` is testable without a `ChatViewModel`.
@MainActor
private final class MockChatPeerIdentityContext: ChatPeerIdentityContext {
    // Conversation state
    var privateChats: [PeerID: [BitchatMessage]] = [:]
    var unreadPrivateMessages: Set<PeerID> = []
    var selectedPrivateChatPeer: PeerID?
    var selectedPrivateChatFingerprint: String?
    var nickname = "me"
    var myPeerID = PeerID(str: "0011223344556677")
    var activeChannel: ChannelID = .mesh
    private(set) var notifyUIChangedCount = 0
    private(set) var systemMessages: [String] = []

    func notifyUIChanged() { notifyUIChangedCount += 1 }
    func addSystemMessage(_ content: String) { systemMessages.append(content) }

    // Private chat session lifecycle
    private(set) var consolidatedPeers: [(peerID: PeerID, peerNickname: String)] = []
    private(set) var syncedReadReceiptPeers: [PeerID] = []
    private(set) var begunChatSessions: [PeerID] = []
    private(set) var privateStoreSyncCount = 0
    private(set) var selectionStoreSyncCount = 0
    private(set) var markedReadPeers: [PeerID] = []

    @discardableResult
    func consolidatePrivateMessages(for peerID: PeerID, peerNickname: String) -> Bool {
        consolidatedPeers.append((peerID, peerNickname))
        return false
    }

    func syncReadReceiptsForSentMessages(for peerID: PeerID) {
        syncedReadReceiptPeers.append(peerID)
    }

    func beginPrivateChatSession(with peerID: PeerID) {
        begunChatSessions.append(peerID)
    }

    func synchronizePrivateConversationStore() { privateStoreSyncCount += 1 }
    func synchronizeConversationSelectionStore() { selectionStoreSyncCount += 1 }
    func markPrivateMessagesAsRead(from peerID: PeerID) { markedReadPeers.append(peerID) }

    // Unified peer service
    var connectedPeers: Set<PeerID> = []
    var peersByID: [PeerID: BitchatPeer] = [:]
    var blockedPeers: Set<PeerID> = []
    var fingerprintsByPeerID: [PeerID: String] = [:]
    var peerIDsByNickname: [String: PeerID] = [:]
    var ephemeralPeerIDsByNoiseKey: [Data: PeerID] = [:]
    private(set) var toggledFavoritePeers: [PeerID] = []

    func unifiedPeer(for peerID: PeerID) -> BitchatPeer? { peersByID[peerID] }
    func unifiedIsBlocked(_ peerID: PeerID) -> Bool { blockedPeers.contains(peerID) }
    func unifiedToggleFavorite(_ peerID: PeerID) { toggledFavoritePeers.append(peerID) }
    func unifiedFingerprint(for peerID: PeerID) -> String? { fingerprintsByPeerID[peerID] }
    func unifiedPeerID(forNickname nickname: String) -> PeerID? { peerIDsByNickname[nickname] }
    func ephemeralPeerID(forNoiseKey noiseKey: Data) -> PeerID? { ephemeralPeerIDsByNoiseKey[noiseKey] }

    // Mesh & Noise sessions
    var nicknamesByPeerID: [PeerID: String] = [:]
    var noiseSessionStates: [PeerID: LazyHandshakeState] = [:]
    var establishedNoiseSessions: Set<PeerID> = []
    var activeNoiseSessions: Set<PeerID> = []
    var myNoiseFingerprint = "my-fingerprint"
    private(set) var triggeredHandshakes: [PeerID] = []

    func peerNickname(for peerID: PeerID) -> String? { nicknamesByPeerID[peerID] }
    func meshPeerNicknames() -> [PeerID: String] { nicknamesByPeerID }
    func noiseSessionState(for peerID: PeerID) -> LazyHandshakeState {
        noiseSessionStates[peerID] ?? .none
    }
    func triggerHandshake(with peerID: PeerID) { triggeredHandshakes.append(peerID) }
    func hasEstablishedNoiseSession(with peerID: PeerID) -> Bool {
        establishedNoiseSessions.contains(peerID)
    }
    func hasNoiseSession(with peerID: PeerID) -> Bool { activeNoiseSessions.contains(peerID) }
    func noiseIdentityFingerprint() -> String { myNoiseFingerprint }

    // Identity store (fingerprints & encryption status)
    var verifiedFingerprintSet: Set<String> = []
    var socialIdentitiesByFingerprint: [String: SocialIdentity] = [:]
    private(set) var storedFingerprints: [(fingerprint: String, peerID: PeerID)] = []
    private(set) var encryptionStatuses: [PeerID: EncryptionStatus?] = [:]
    private(set) var cachedEncryptionStatuses: [PeerID: EncryptionStatus] = [:]
    private(set) var invalidatedEncryptionCachePeers: [PeerID?] = []

    func setStoredFingerprint(_ fingerprint: String, for peerID: PeerID) {
        storedFingerprints.append((fingerprint, peerID))
        fingerprintsByPeerID[peerID] = fingerprint
    }

    func migrateFingerprintMapping(from oldPeerID: PeerID, to newPeerID: PeerID, fallback: String?) -> String? {
        let fingerprint = fingerprintsByPeerID.removeValue(forKey: oldPeerID) ?? fallback
        if let fingerprint {
            fingerprintsByPeerID[newPeerID] = fingerprint
        }
        return fingerprint
    }

    func isVerifiedFingerprint(_ fingerprint: String) -> Bool {
        verifiedFingerprintSet.contains(fingerprint)
    }

    func setEncryptionStatus(_ status: EncryptionStatus?, for peerID: PeerID) {
        encryptionStatuses[peerID] = status
    }

    func cachedEncryptionStatus(for peerID: PeerID) -> EncryptionStatus? {
        cachedEncryptionStatuses[peerID]
    }

    func setCachedEncryptionStatus(_ status: EncryptionStatus, for peerID: PeerID) {
        cachedEncryptionStatuses[peerID] = status
    }

    func invalidateStoredEncryptionCache(for peerID: PeerID?) {
        invalidatedEncryptionCachePeers.append(peerID)
        if let peerID {
            cachedEncryptionStatuses.removeValue(forKey: peerID)
        } else {
            cachedEncryptionStatuses.removeAll()
        }
    }

    func socialIdentity(forFingerprint fingerprint: String) -> SocialIdentity? {
        socialIdentitiesByFingerprint[fingerprint]
    }

    // Geohash & Nostr
    var geoNicknames: [String: String] = [:]
    var geohashPeople: [GeoPerson] = []
    private(set) var registeredNostrKeyMappings: [(pubkey: String, peerID: PeerID)] = []
    private(set) var nostrFavoriteNotifications: [(noisePublicKey: Data, isFavorite: Bool)] = []
    var bridgedNostrKeysByNoiseKey: [Data: String] = [:]

    func visibleGeohashPeople() -> [GeoPerson] { geohashPeople }

    func registerNostrKeyMapping(_ pubkey: String, for peerID: PeerID) {
        registeredNostrKeyMappings.append((pubkey, peerID))
    }

    func bridgedNostrPublicKey(for noiseKey: Data) -> String? {
        bridgedNostrKeysByNoiseKey[noiseKey]
    }

    func sendFavoriteNotificationViaNostr(noisePublicKey: Data, isFavorite: Bool) {
        nostrFavoriteNotifications.append((noisePublicKey, isFavorite))
    }
}

// MARK: - Helpers

@MainActor
private func makePrivateMessage(
    id: String,
    sender: String = "alice",
    timestamp: Date = Date(),
    senderPeerID: PeerID? = nil
) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: sender,
        content: "hello",
        timestamp: timestamp,
        isRelay: false,
        isPrivate: true,
        recipientNickname: "me",
        senderPeerID: senderPeerID
    )
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatPeerIdentityCoordinator` against
/// `MockChatPeerIdentityContext` with no `ChatViewModel`.
struct ChatPeerIdentityCoordinatorContextTests {

    @Test @MainActor
    func startPrivateChat_runsFullSessionSetupSequence() async {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        context.nicknamesByPeerID[peerID] = "alice"
        context.fingerprintsByPeerID[peerID] = "fp-alice"

        // Chatting with ourselves is a no-op.
        coordinator.startPrivateChat(with: context.myPeerID)
        #expect(context.begunChatSessions.isEmpty)

        coordinator.startPrivateChat(with: peerID)

        #expect(context.consolidatedPeers.map(\.peerID) == [peerID])
        #expect(context.consolidatedPeers.first?.peerNickname == "alice")
        // No Noise session yet -> handshake triggered.
        #expect(context.triggeredHandshakes == [peerID])
        #expect(context.syncedReadReceiptPeers == [peerID])
        #expect(context.storedFingerprints.map(\.fingerprint) == ["fp-alice"])
        #expect(context.selectedPrivateChatFingerprint == "fp-alice")
        #expect(context.begunChatSessions == [peerID])
        #expect(context.privateStoreSyncCount == 1)
        #expect(context.selectionStoreSyncCount == 1)
        #expect(context.markedReadPeers == [peerID])

        // Established session: no second handshake.
        context.noiseSessionStates[peerID] = .established
        coordinator.startPrivateChat(with: peerID)
        #expect(context.triggeredHandshakes == [peerID])
    }

    @Test @MainActor
    func startPrivateChat_blockedPeerOnlyGetsSystemMessage() async {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")
        context.blockedPeers = [peerID]

        coordinator.startPrivateChat(with: peerID)

        #expect(context.systemMessages.count == 1)
        #expect(context.begunChatSessions.isEmpty)
        #expect(context.consolidatedPeers.isEmpty)
        #expect(context.markedReadPeers.isEmpty)
    }

    @Test @MainActor
    func updatePrivateChatPeerIfNeeded_migratesChatStateByFingerprint() async {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        let oldPeerID = PeerID(str: "1111111111111111")
        let newPeerID = PeerID(str: "2222222222222222")

        context.selectedPrivateChatFingerprint = "fp"
        context.selectedPrivateChatPeer = oldPeerID
        context.connectedPeers = [newPeerID]
        context.fingerprintsByPeerID[newPeerID] = "fp"
        let earlier = makePrivateMessage(id: "m1", timestamp: Date(timeIntervalSince1970: 1))
        let later = makePrivateMessage(id: "m2", timestamp: Date(timeIntervalSince1970: 2))
        context.privateChats[oldPeerID] = [later]
        context.privateChats[newPeerID] = [earlier, later] // duplicate id "m2"
        context.unreadPrivateMessages = [oldPeerID]

        coordinator.updatePrivateChatPeerIfNeeded()

        // Old chat is merged into the new peer's chat, deduplicated by id and
        // sorted by timestamp; old keys are dropped.
        #expect(context.privateChats[oldPeerID] == nil)
        #expect(context.privateChats[newPeerID]?.map(\.id) == ["m1", "m2"])
        #expect(context.selectedPrivateChatPeer == newPeerID)
        // Unread moved to the new peer, then cleared for the now-open chat.
        #expect(context.unreadPrivateMessages.isEmpty)
    }

    @Test @MainActor
    func getEncryptionStatus_computesVerifiedStatusAndCachesIt() async {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        let peerID = PeerID(str: "1122334455667788")

        // Unknown peer with no fingerprint or session: no handshake yet.
        #expect(coordinator.getEncryptionStatus(for: peerID) == .noHandshake)
        #expect(context.cachedEncryptionStatuses[peerID] == .noHandshake)

        // Cache hit short-circuits recomputation.
        context.noiseSessionStates[peerID] = .established
        #expect(coordinator.getEncryptionStatus(for: peerID) == .noHandshake)

        // After invalidation, an established session with a verified
        // fingerprint resolves (and re-caches) as verified.
        coordinator.invalidateEncryptionCache(for: peerID)
        context.fingerprintsByPeerID[peerID] = "fp"
        context.verifiedFingerprintSet = ["fp"]
        #expect(coordinator.getEncryptionStatus(for: peerID) == .noiseVerified)
        #expect(context.cachedEncryptionStatuses[peerID] == .noiseVerified)

        // updateEncryptionStatus publishes to the store and invalidates the cache.
        context.establishedNoiseSessions = [peerID]
        coordinator.updateEncryptionStatus(for: peerID)
        #expect(context.encryptionStatuses[peerID] == .noiseVerified)
        #expect(context.cachedEncryptionStatuses[peerID] == nil)
    }

    @Test @MainActor
    func resolveNickname_walksMeshIdentityAndAnonFallbacks() async {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        let meshPeer = PeerID(str: "aabbccddeeff0011")
        let identityPeer = PeerID(str: "1234567890abcdef")
        let unknownPeer = PeerID(str: "feedfacefeedface")

        context.nicknamesByPeerID[meshPeer] = "alice"
        #expect(coordinator.resolveNickname(for: meshPeer) == "alice")

        context.fingerprintsByPeerID[identityPeer] = "fp"
        context.socialIdentitiesByFingerprint["fp"] = SocialIdentity(
            fingerprint: "fp",
            localPetname: "bob!",
            claimedNickname: "bob",
            trustLevel: .casual,
            isFavorite: false,
            isBlocked: false,
            notes: nil
        )
        #expect(coordinator.resolveNickname(for: identityPeer) == "bob!")

        #expect(coordinator.resolveNickname(for: unknownPeer) == "anonfeed")
        #expect(coordinator.getMyFingerprint() == "my-fingerprint")
    }

    @Test @MainActor
    func getPeerIDForNickname_inGeohashChannel_registersNostrMapping() async {
        let context = MockChatPeerIdentityContext()
        let coordinator = ChatPeerIdentityCoordinator(context: context)
        let pubkey = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789".lowercased()
        context.activeChannel = .location(GeohashChannel(level: .city, geohash: "u4pruy"))
        context.geohashPeople = [GeoPerson(id: pubkey, displayName: "alice#6789", lastSeen: Date())]
        context.geoNicknames[pubkey] = "alice"

        // Suffixed display-name match.
        let bySuffix = coordinator.getPeerIDForNickname("alice#6789")
        #expect(bySuffix == PeerID(nostr_: pubkey))
        // Base-nickname match via geoNicknames.
        let byBase = coordinator.getPeerIDForNickname("ALICE")
        #expect(byBase == PeerID(nostr_: pubkey))
        #expect(context.registeredNostrKeyMappings.count == 2)
        #expect(context.registeredNostrKeyMappings.allSatisfy { $0.pubkey == pubkey })

        // Mesh channel falls through to the unified peer service.
        context.activeChannel = .mesh
        let meshPeer = PeerID(str: "1122334455667788")
        context.peerIDsByNickname["carol"] = meshPeer
        #expect(coordinator.getPeerIDForNickname("carol") == meshPeer)
    }
}
