//
// ChatPublicConversationCoordinatorContextTests.swift
// bitchatTests
//
// Exercises `ChatPublicConversationCoordinator` against a mock
// `ChatPublicConversationContext` — proving the coordinator works without a
// `ChatViewModel`, following the `ChatDeliveryCoordinatorContextTests` /
// `ChatPrivateConversationCoordinatorContextTests` exemplars.
//
// Scope note: haptics (UIApplication) and the geohash branch of
// `sendPublicRaw` (NostrRelayManager.shared, GeoRelayDirectory.shared) are
// intentionally not exercised here. `checkForMentions` posts through the
// injected context (`notifyMention(from:message:)`) and is covered, as are
// the mesh branch of `sendPublicRaw` and all timeline/store/blocking flows.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Mock Context

/// Lightweight stand-in for `ChatPublicConversationContext` proving that
/// `ChatPublicConversationCoordinator` is testable without a `ChatViewModel`.
@MainActor
private final class MockChatPublicConversationContext: ChatPublicConversationContext {
    // Channel & visible timeline state
    var messages: [BitchatMessage] = []
    var activeChannel: ChannelID = .mesh
    var currentGeohash: String?
    var nickname = "me"
    var myPeerID = PeerID(str: "0011223344556677")
    private(set) var isBatchingPublic = false
    private(set) var notifyUIChangedCount = 0
    private(set) var trimMessagesCount = 0

    func setPublicBatching(_ isBatching: Bool) {
        isBatchingPublic = isBatching
    }

    func notifyUIChanged() {
        notifyUIChangedCount += 1
    }

    func trimMessagesIfNeeded() {
        trimMessagesCount += 1
    }

    // Public timeline store
    var meshTimeline: [BitchatMessage] = []
    var geoTimelines: [String: [BitchatMessage]] = [:]
    private(set) var queuedGeohashSystemMessages: [String] = []

    func timelineMessages(for channel: ChannelID) -> [BitchatMessage] {
        switch channel {
        case .mesh: return meshTimeline
        case .location(let channel): return geoTimelines[channel.geohash] ?? []
        }
    }

    func appendTimelineMessage(_ message: BitchatMessage, to channel: ChannelID) {
        switch channel {
        case .mesh: meshTimeline.append(message)
        case .location(let channel): geoTimelines[channel.geohash, default: []].append(message)
        }
    }

    func appendGeohashMessageIfAbsent(_ message: BitchatMessage, toGeohash geohash: String) -> Bool {
        if geoTimelines[geohash]?.contains(where: { $0.id == message.id }) == true {
            return false
        }
        geoTimelines[geohash, default: []].append(message)
        return true
    }

    func removeTimelineMessage(withID id: String) -> BitchatMessage? {
        if let index = meshTimeline.firstIndex(where: { $0.id == id }) {
            return meshTimeline.remove(at: index)
        }
        for (geohash, timeline) in geoTimelines {
            guard let index = timeline.firstIndex(where: { $0.id == id }) else { continue }
            var updated = timeline
            let removed = updated.remove(at: index)
            geoTimelines[geohash] = updated
            return removed
        }
        return nil
    }

    func removeGeohashTimelineMessages(in geohash: String, where predicate: (BitchatMessage) -> Bool) {
        geoTimelines[geohash]?.removeAll(where: predicate)
    }

    func clearTimeline(for channel: ChannelID) {
        switch channel {
        case .mesh: meshTimeline.removeAll()
        case .location(let channel): geoTimelines[channel.geohash] = []
        }
    }

    func timelineGeohashKeys() -> [String] {
        Array(geoTimelines.keys)
    }

    func queueGeohashSystemMessage(_ content: String) {
        queuedGeohashSystemMessages.append(content)
    }

    // Conversation stores
    private(set) var conversationActiveChannels: [ChannelID] = []
    private(set) var replacedChannelMessages: [(channel: ChannelID, messageIDs: [String])] = []
    private(set) var replacedConversationMessages: [(conversation: ConversationID, messageIDs: [String])] = []
    private(set) var privateStoreSyncCount = 0
    private(set) var selectionStoreSyncCount = 0

    func setConversationActiveChannel(_ channel: ChannelID) {
        conversationActiveChannels.append(channel)
    }

    func replaceConversationMessages(_ messages: [BitchatMessage], for channelID: ChannelID) {
        replacedChannelMessages.append((channelID, messages.map(\.id)))
    }

    func replaceConversationMessages(_ messages: [BitchatMessage], for conversationID: ConversationID) {
        replacedConversationMessages.append((conversationID, messages.map(\.id)))
    }

    func synchronizePrivateConversationStore() {
        privateStoreSyncCount += 1
    }

    func synchronizeConversationSelectionStore() {
        selectionStoreSyncCount += 1
    }

    // Private chats
    var privateChats: [PeerID: [BitchatMessage]] = [:]
    var unreadPrivateMessages: Set<PeerID> = []
    private(set) var cleanedUpFileMessageIDs: [String] = []

    func cleanupLocalFile(forMessage message: BitchatMessage) {
        cleanedUpFileMessageIDs.append(message.id)
    }

    // Geohash participants & presence
    var geoNicknames: [String: String] = [:]
    var isTeleported = false
    var nostrKeyMapping: [PeerID: String] = [:]
    var geoPeople: [GeoPerson] = []
    var geoParticipantCounts: [String: Int] = [:]
    private(set) var removedGeoParticipants: [String] = []

    func removeNostrKeyMappings(matchingPubkeyHexLowercased hex: String) {
        for (key, value) in nostrKeyMapping where value.lowercased() == hex {
            nostrKeyMapping.removeValue(forKey: key)
        }
    }

    func visibleGeoPeople() -> [GeoPerson] {
        geoPeople
    }

    func geoParticipantCount(for geohash: String) -> Int {
        geoParticipantCounts[geohash] ?? 0
    }

    func removeGeoParticipant(pubkeyHex: String) {
        removedGeoParticipants.append(pubkeyHex)
    }

    // Nostr identity & blocking
    var blockedNostrPubkeys: Set<String> = []

    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity {
        Self.dummyIdentity
    }

    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool {
        blockedNostrPubkeys.contains(pubkeyHexLowercased)
    }

    func setNostrBlocked(_ pubkeyHexLowercased: String, isBlocked: Bool) {
        if isBlocked {
            blockedNostrPubkeys.insert(pubkeyHexLowercased)
        } else {
            blockedNostrPubkeys.remove(pubkeyHexLowercased)
        }
    }

    // Mesh transport
    var meshNicknames: [PeerID: String] = [:]
    private(set) var sentMeshMessages: [(content: String, messageID: String)] = []

    func meshPeerNicknames() -> [PeerID: String] {
        meshNicknames
    }

    func sendMeshMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date) {
        sentMeshMessages.append((content, messageID))
    }

    // Inbound public message processing
    var blockedMessageIDs: Set<String> = []
    var rateLimitAllowed = true
    private(set) var rateLimitChecks: [(senderKey: String, contentKey: String)] = []
    private(set) var enqueuedMessageIDs: [String] = []
    var stablePeerIDs: [PeerID: PeerID] = [:]

    func processActionMessage(_ message: BitchatMessage) -> BitchatMessage {
        message
    }

    func isMessageBlocked(_ message: BitchatMessage) -> Bool {
        blockedMessageIDs.contains(message.id)
    }

    func allowPublicMessage(senderKey: String, contentKey: String) -> Bool {
        rateLimitChecks.append((senderKey, contentKey))
        return rateLimitAllowed
    }

    func enqueuePublicMessage(_ message: BitchatMessage) {
        enqueuedMessageIDs.append(message.id)
    }

    func cachedStablePeerID(for shortPeerID: PeerID) -> PeerID? {
        stablePeerIDs[shortPeerID]
    }

    // Content dedup & formatting
    var contentTimestamps: [String: Date] = [:]
    private(set) var recordedContentKeys: [(key: String, timestamp: Date)] = []
    private(set) var prewarmedMessageIDs: [String] = []

    func normalizedContentKey(_ content: String) -> String {
        content.lowercased()
    }

    func contentTimestamp(forKey key: String) -> Date? {
        contentTimestamps[key]
    }

    func recordContentKey(_ key: String, timestamp: Date) {
        recordedContentKeys.append((key, timestamp))
    }

    func prewarmMessageFormatting(_ message: BitchatMessage) {
        prewarmedMessageIDs.append(message.id)
    }

    // Notifications
    private(set) var mentionNotifications: [(sender: String, message: String)] = []

    func notifyMention(from sender: String, message: String) {
        mentionNotifications.append((sender, message))
    }

    static let dummyIdentity = NostrIdentity(
        privateKey: Data(repeating: 0x11, count: 32),
        publicKey: Data(repeating: 0x22, count: 32),
        npub: "npub1mock",
        createdAt: Date(timeIntervalSince1970: 0)
    )
}

// MARK: - Helpers

@MainActor
private func makePublicMessage(
    id: String = UUID().uuidString,
    sender: String = "alice",
    content: String = "hello world",
    senderPeerID: PeerID? = PeerID(str: "aabbccddeeff0011")
) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: sender,
        content: content,
        timestamp: Date(),
        isRelay: false,
        isPrivate: false,
        senderPeerID: senderPeerID
    )
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatPublicConversationCoordinator` against
/// `MockChatPublicConversationContext` — no `ChatViewModel` involved.
struct ChatPublicConversationCoordinatorContextTests {

    @Test @MainActor
    func handlePublicMessage_meshMessage_appendsSyncsStoreAndEnqueues() async {
        let context = MockChatPublicConversationContext()
        let coordinator = ChatPublicConversationCoordinator(context: context)
        let message = makePublicMessage(id: "mesh-msg-1", content: "Hello Mesh")

        coordinator.handlePublicMessage(message)

        #expect(context.meshTimeline.map(\.id) == ["mesh-msg-1"])
        #expect(context.replacedChannelMessages.count == 1)
        #expect(context.replacedChannelMessages.first?.channel == .mesh)
        #expect(context.replacedChannelMessages.first?.messageIDs == ["mesh-msg-1"])
        #expect(context.rateLimitChecks.count == 1)
        #expect(context.rateLimitChecks.first?.senderKey == "mesh:aabbccddeeff0011")
        #expect(context.rateLimitChecks.first?.contentKey == "hello mesh")
        #expect(context.enqueuedMessageIDs == ["mesh-msg-1"])

        // Already visible in the timeline: stored again, but not re-enqueued.
        context.messages = [message]
        coordinator.handlePublicMessage(message)
        #expect(context.enqueuedMessageIDs == ["mesh-msg-1"])
    }

    @Test @MainActor
    func handlePublicMessage_blockedOrRateLimited_dropsMessage() async {
        let context = MockChatPublicConversationContext()
        let coordinator = ChatPublicConversationCoordinator(context: context)

        // Blocked sender: dropped before rate limiting and storage.
        context.blockedMessageIDs = ["blocked-msg"]
        coordinator.handlePublicMessage(makePublicMessage(id: "blocked-msg"))
        #expect(context.rateLimitChecks.isEmpty)
        #expect(context.meshTimeline.isEmpty)
        #expect(context.enqueuedMessageIDs.isEmpty)

        // Rate limited: consulted, then dropped before storage.
        context.rateLimitAllowed = false
        coordinator.handlePublicMessage(makePublicMessage(id: "limited-msg"))
        #expect(context.rateLimitChecks.count == 1)
        #expect(context.meshTimeline.isEmpty)
        #expect(context.enqueuedMessageIDs.isEmpty)
    }

    @Test @MainActor
    func handlePublicMessage_geoMessage_respectsActiveChannel() async {
        let context = MockChatPublicConversationContext()
        let coordinator = ChatPublicConversationCoordinator(context: context)
        let geohash = "u4pruy"
        context.currentGeohash = geohash
        let senderHex = String(repeating: "ab", count: 32)
        let geoMessage = makePublicMessage(
            id: "geo-msg-1",
            content: "geo hello",
            senderPeerID: PeerID(nostr: senderHex)
        )

        // On mesh channel: stored in the geohash timeline but not enqueued.
        context.activeChannel = .mesh
        coordinator.handlePublicMessage(geoMessage)
        #expect(context.geoTimelines[geohash]?.map(\.id) == ["geo-msg-1"])
        #expect(context.replacedConversationMessages.count == 1)
        #expect(context.replacedConversationMessages.first?.conversation == .geohash(geohash))
        #expect(context.meshTimeline.isEmpty)
        #expect(context.enqueuedMessageIDs.isEmpty)

        // On the matching location channel: enqueued for display.
        context.activeChannel = .location(GeohashChannel(level: .city, geohash: geohash))
        let second = makePublicMessage(
            id: "geo-msg-2",
            content: "geo again",
            senderPeerID: PeerID(nostr: senderHex)
        )
        coordinator.handlePublicMessage(second)
        #expect(context.enqueuedMessageIDs == ["geo-msg-2"])
    }

    @Test @MainActor
    func blockGeohashUser_purgesMessagesMappingsAndPrivateChats() async {
        let context = MockChatPublicConversationContext()
        let coordinator = ChatPublicConversationCoordinator(context: context)
        let geohash = "u4pruy"
        let hex = String(repeating: "cd", count: 32)
        let senderPeerID = PeerID(nostr: hex)
        let convKey = PeerID(nostr_: hex)
        let geoMessage = makePublicMessage(id: "geo-bad-1", sender: "rude", senderPeerID: senderPeerID)

        context.currentGeohash = geohash
        context.activeChannel = .location(GeohashChannel(level: .city, geohash: geohash))
        context.geoTimelines[geohash] = [geoMessage]
        context.messages = [geoMessage]
        context.nostrKeyMapping = [senderPeerID: hex, convKey: hex]
        context.privateChats[convKey] = [geoMessage]
        context.unreadPrivateMessages = [convKey]

        coordinator.blockGeohashUser(pubkeyHexLowercased: hex, displayName: "rude#abcd")

        #expect(context.blockedNostrPubkeys.contains(hex))
        #expect(context.removedGeoParticipants == [hex])
        #expect(context.geoTimelines[geohash]?.isEmpty == true)
        #expect(context.privateChats[convKey] == nil)
        #expect(context.unreadPrivateMessages.isEmpty)
        #expect(context.nostrKeyMapping.isEmpty)
        // The blocked user's visible message is gone; a system notice was added.
        #expect(!context.messages.contains(where: { $0.id == "geo-bad-1" }))
        #expect(context.messages.last?.sender == "system")

        coordinator.unblockGeohashUser(pubkeyHexLowercased: hex, displayName: "rude#abcd")
        #expect(!context.blockedNostrPubkeys.contains(hex))
    }

    @Test @MainActor
    func removeMessage_removesEverywhereAndCleansUpFile() async {
        let context = MockChatPublicConversationContext()
        let coordinator = ChatPublicConversationCoordinator(context: context)
        let peerID = PeerID(str: "0102030405060708")
        let message = makePublicMessage(id: "doomed-msg")
        context.messages = [message]
        context.meshTimeline = [message]
        context.privateChats[peerID] = [message]

        coordinator.removeMessage(withID: "doomed-msg", cleanupFile: true)

        #expect(context.messages.isEmpty)
        #expect(context.meshTimeline.isEmpty)
        #expect(context.privateChats[peerID] == nil)
        #expect(context.cleanedUpFileMessageIDs == ["doomed-msg"])
        #expect(context.notifyUIChangedCount == 1)
        // Timeline removal triggers a full conversation-store resync.
        #expect(context.replacedChannelMessages.contains(where: { $0.channel == .mesh && $0.messageIDs.isEmpty }))
    }

    @Test @MainActor
    func addPublicSystemMessage_appendsRefreshesAndRecordsContentKey() async {
        let context = MockChatPublicConversationContext()
        let coordinator = ChatPublicConversationCoordinator(context: context)

        coordinator.addPublicSystemMessage("Tor Ready")

        #expect(context.meshTimeline.count == 1)
        #expect(context.meshTimeline.first?.sender == "system")
        // refreshVisibleMessages mirrors the timeline into the visible list.
        #expect(context.messages.map(\.id) == context.meshTimeline.map(\.id))
        #expect(context.recordedContentKeys.map(\.key) == ["tor ready"])
        #expect(context.trimMessagesCount == 1)
        #expect(context.notifyUIChangedCount == 1)
        #expect(context.conversationActiveChannels == [.mesh])

        // On mesh, geohash-only system messages are queued for the next geo visit.
        coordinator.addGeohashOnlySystemMessage("geo notice")
        #expect(context.queuedGeohashSystemMessages == ["geo notice"])
    }

    @Test @MainActor
    func sendPublicRaw_onMeshChannel_sendsViaMeshTransport() async {
        let context = MockChatPublicConversationContext()
        let coordinator = ChatPublicConversationCoordinator(context: context)

        coordinator.sendPublicRaw("raw mesh payload")

        #expect(context.sentMeshMessages.count == 1)
        #expect(context.sentMeshMessages.first?.content == "raw mesh payload")
    }

    @Test @MainActor
    func pipelineDelegate_readsAndWritesContextState() async {
        let context = MockChatPublicConversationContext()
        let coordinator = ChatPublicConversationCoordinator(context: context)
        let pipeline = PublicMessagePipeline()
        let message = makePublicMessage(id: "pipeline-msg")
        context.messages = [message]
        context.contentTimestamps["key-1"] = Date(timeIntervalSince1970: 42)

        #expect(coordinator.pipelineCurrentMessages(pipeline).map(\.id) == ["pipeline-msg"])
        #expect(coordinator.pipeline(pipeline, normalizeContent: "HeLLo") == "hello")
        #expect(coordinator.pipeline(pipeline, contentTimestampForKey: "key-1") == Date(timeIntervalSince1970: 42))

        coordinator.pipeline(pipeline, setMessages: [])
        #expect(context.messages.isEmpty)

        coordinator.pipeline(pipeline, recordContentKey: "key-2", timestamp: Date(timeIntervalSince1970: 7))
        #expect(context.recordedContentKeys.map(\.key) == ["key-2"])

        coordinator.pipelineTrimMessages(pipeline)
        #expect(context.trimMessagesCount == 1)

        coordinator.pipelinePrewarmMessage(pipeline, message: message)
        #expect(context.prewarmedMessageIDs == ["pipeline-msg"])

        coordinator.pipelineSetBatchingState(pipeline, isBatching: true)
        #expect(context.isBatchingPublic)
    }

    @Test @MainActor
    func currentPublicSenderAndDisplayName_deriveGeoSuffixedIdentity() async {
        let context = MockChatPublicConversationContext()
        let coordinator = ChatPublicConversationCoordinator(context: context)
        let identityHex = MockChatPublicConversationContext.dummyIdentity.publicKeyHex
        let suffix = String(identityHex.suffix(4))

        // Mesh: plain nickname and mesh peer ID.
        let meshSender = coordinator.currentPublicSender()
        #expect(meshSender.name == "me")
        #expect(meshSender.peerID == context.myPeerID)

        // Location channel: suffixed nickname and nostr peer ID.
        context.activeChannel = .location(GeohashChannel(level: .city, geohash: "u4pruy"))
        let geoSender = coordinator.currentPublicSender()
        #expect(geoSender.name == "me#\(suffix)")
        #expect(geoSender.peerID == PeerID(nostr: identityHex))

        // Display names: own geo identity, known nickname, and anon fallback.
        context.currentGeohash = "u4pruy"
        #expect(coordinator.displayNameForNostrPubkey(identityHex) == "me#\(suffix)")
        let otherHex = String(repeating: "ef", count: 32)
        context.geoNicknames[otherHex] = "bob"
        #expect(coordinator.displayNameForNostrPubkey(otherHex) == "bob#" + otherHex.suffix(4))
        let unknownHex = String(repeating: "12", count: 32)
        #expect(coordinator.displayNameForNostrPubkey(unknownHex) == "anon#" + unknownHex.suffix(4))
    }
    @Test @MainActor
    func checkForMentions_postsMentionNotificationOnlyForOthersMentioningMe() async {
        let context = MockChatPublicConversationContext()
        let coordinator = ChatPublicConversationCoordinator(context: context)

        // A mention of my nickname from someone else notifies.
        coordinator.checkForMentions(
            BitchatMessage(
                id: "mention-1",
                sender: "alice",
                content: "hey @me",
                timestamp: Date(),
                isRelay: false,
                mentions: ["me"]
            )
        )
        #expect(context.mentionNotifications.count == 1)
        #expect(context.mentionNotifications.first?.sender == "alice")
        #expect(context.mentionNotifications.first?.message == "hey @me")

        // Mentioning someone else does not notify.
        coordinator.checkForMentions(
            BitchatMessage(
                id: "mention-2",
                sender: "alice",
                content: "hey @bob",
                timestamp: Date(),
                isRelay: false,
                mentions: ["bob"]
            )
        )
        #expect(context.mentionNotifications.count == 1)

        // My own message mentioning myself does not notify.
        coordinator.checkForMentions(
            BitchatMessage(
                id: "mention-3",
                sender: "me",
                content: "talking about @me",
                timestamp: Date(),
                isRelay: false,
                mentions: ["me"]
            )
        )
        #expect(context.mentionNotifications.count == 1)
    }

}
