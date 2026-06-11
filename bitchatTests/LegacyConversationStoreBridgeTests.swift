//
// LegacyConversationStoreBridgeTests.swift
// bitchatTests
//
// Focused tests for migration step 2 (docs/CONVERSATION-STORE-DESIGN.md §4):
// the private write path goes through the single-writer `ConversationStore`
// intents, and `LegacyConversationStoreBridge` keeps the replace-based
// `LegacyConversationStore` consistent — per-message changes via a
// `Task.yield`-coalesced per-conversation mirror, unread flips and
// structural changes (migration/removal) synchronously — until the feature
// models cut over in step 5.
//
// DELETE IN STEP 5 together with the bridge.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

@MainActor
private func makeBridgedFixture() -> (
    viewModel: ChatViewModel,
    store: ConversationStore,
    legacy: LegacyConversationStore,
    transport: MockTransport
) {
    let keychain = MockKeychain()
    let idBridge = NostrIdentityBridge(keychain: MockKeychainHelper())
    let identityManager = MockIdentityManager(keychain)
    let transport = MockTransport()
    let legacy = LegacyConversationStore()
    let store = ConversationStore()
    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: identityManager,
        transport: transport,
        conversationStore: legacy,
        conversations: store
    )
    return (viewModel, store, legacy, transport)
}

@MainActor
private func makeInboundPrivateMessage(
    id: String,
    from peerID: PeerID,
    sender: String = "alice",
    content: String = "hello",
    timestamp: Date = Date()
) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: sender,
        content: content,
        timestamp: timestamp,
        isRelay: false,
        isPrivate: true,
        recipientNickname: "me",
        senderPeerID: peerID,
        deliveryStatus: .delivered(to: "me", at: timestamp)
    )
}

@Suite("LegacyConversationStoreBridge")
struct LegacyConversationStoreBridgeTests {

    @Test("inbound private message lands in the store and is mirrored into Legacy")
    @MainActor
    func inboundPrivateMessageLandsInStoreAndLegacy() async {
        let (viewModel, store, legacy, _) = makeBridgedFixture()
        // Stable Noise-key peer ID, like the perf pipeline fixture.
        let peerID = PeerID(str: String(repeating: "ab", count: 32))
        let message = makeInboundPrivateMessage(id: "bridge-pm-1", from: peerID)

        viewModel.handlePrivateMessage(message)

        // New store is the synchronous source of truth.
        #expect(store.conversation(for: .directPeer(peerID)).messages.map(\.id) == ["bridge-pm-1"])
        #expect(viewModel.privateChats[peerID]?.map(\.id) == ["bridge-pm-1"])
        // Unread flips mirror into Legacy synchronously.
        #expect(viewModel.unreadPrivateMessages.contains(peerID))
        #expect(legacy.unreadDirectPeerIDs().contains(peerID))

        // Message arrays mirror via the bridge's coalesced flush
        // (one Legacy replace per burst, on the next main-actor turn).
        let mirrored = await TestHelpers.waitUntil(
            { legacy.directMessagesByPeerID()[peerID]?.map(\.id) == ["bridge-pm-1"] },
            timeout: 1.0
        )
        #expect(mirrored)
    }

    @Test("store dedups a private message delivered twice")
    @MainActor
    func storeDedupsDuplicateInboundMessage() async {
        let (viewModel, store, legacy, _) = makeBridgedFixture()
        let peerID = PeerID(str: String(repeating: "cd", count: 32))
        let message = makeInboundPrivateMessage(id: "bridge-dup-1", from: peerID)

        viewModel.handlePrivateMessage(message)
        viewModel.handlePrivateMessage(message)

        #expect(store.conversation(for: .directPeer(peerID)).messages.count == 1)
        #expect(viewModel.privateChats[peerID]?.count == 1)

        // The intent itself reports the duplicate.
        #expect(!viewModel.appendPrivateMessage(message, to: peerID))

        let mirrored = await TestHelpers.waitUntil(
            { legacy.directMessagesByPeerID()[peerID]?.count == 1 },
            timeout: 1.0
        )
        #expect(mirrored)
    }

    @Test("peer-ID migration through store intents keeps Legacy consistent")
    @MainActor
    func migrationThroughStoreIntentsKeepsLegacyConsistent() {
        let (viewModel, store, legacy, _) = makeBridgedFixture()
        let oldPeerID = PeerID(str: "aaaaaaaaaaaaaaaa")
        let newPeerID = PeerID(str: "bbbbbbbbbbbbbbbb")

        viewModel.seedPrivateChat(
            [
                makeInboundPrivateMessage(id: "mig-1", from: oldPeerID, timestamp: Date().addingTimeInterval(-60)),
                makeInboundPrivateMessage(id: "mig-2", from: oldPeerID, timestamp: Date().addingTimeInterval(-30)),
            ],
            for: oldPeerID
        )
        viewModel.markPrivateChatUnread(oldPeerID)

        viewModel.migratePrivateChat(from: oldPeerID, to: newPeerID)

        // Store: messages moved in order, old chat gone, unread carried.
        #expect(store.conversationsByID[.directPeer(oldPeerID)] == nil)
        #expect(store.conversation(for: .directPeer(newPeerID)).messages.map(\.id) == ["mig-1", "mig-2"])
        #expect(viewModel.unreadPrivateMessages == [newPeerID])

        // Legacy: structural changes resynchronize immediately (stale
        // messages removed, destination present, unread re-keyed). The old
        // peer may linger as a registered-but-empty handle — Legacy has
        // always kept handle registrations from markRead/selection around.
        let legacyChats = legacy.directMessagesByPeerID()
        #expect(legacyChats[oldPeerID] ?? [] == [])
        #expect(legacyChats[newPeerID]?.map(\.id) == ["mig-1", "mig-2"])
        #expect(legacy.unreadDirectPeerIDs() == [newPeerID])
    }

    @Test("coordinator chat migration uses the store migrate intent end to end")
    @MainActor
    func coordinatorMigrationFlowsThroughStore() {
        let (viewModel, store, legacy, _) = makeBridgedFixture()
        let oldPeerID = PeerID(str: "1111111111111111")
        let newPeerID = PeerID(str: "2222222222222222")

        // Recent messages from "alice" under the old peer ID; no fingerprints
        // on either side → nickname-match migration path.
        viewModel.seedPrivateChat(
            [makeInboundPrivateMessage(id: "coord-mig-1", from: oldPeerID, timestamp: Date().addingTimeInterval(-5))],
            for: oldPeerID
        )

        viewModel.migratePrivateChatsIfNeeded(for: newPeerID, senderNickname: "alice")

        #expect(store.conversationsByID[.directPeer(oldPeerID)] == nil)
        #expect(store.conversation(for: .directPeer(newPeerID)).messages.map(\.id) == ["coord-mig-1"])
        // Migration resynchronizes Legacy immediately (the old peer may
        // linger as a registered-but-empty handle, see above).
        #expect(legacy.directMessagesByPeerID()[oldPeerID] ?? [] == [])
        #expect(legacy.directMessagesByPeerID()[newPeerID]?.map(\.id) == ["coord-mig-1"])
    }

    // MARK: - Public mirroring (migration step 3)

    @Test("public messages mirror into Legacy via the coalesced flush")
    @MainActor
    func publicMessagesMirrorIntoLegacy() async {
        let (viewModel, store, legacy, _) = makeBridgedFixture()

        viewModel.appendPublicMessage(
            BitchatMessage(
                id: "bridge-pub-1",
                sender: "alice",
                content: "hello mesh",
                timestamp: Date(),
                isRelay: false
            ),
            to: .mesh
        )
        viewModel.appendGeohashMessageIfAbsent(
            BitchatMessage(
                id: "bridge-geo-1",
                sender: "bob#abcd",
                content: "hello geohash",
                timestamp: Date(),
                isRelay: false
            ),
            toGeohash: "U4PRUYD"
        )

        // The new store is synchronously authoritative (geohash keys are
        // normalized to lowercase).
        #expect(store.conversation(for: .mesh).messages.map(\.id) == ["bridge-pub-1"])
        #expect(store.conversation(for: .geohash("u4pruyd")).messages.map(\.id) == ["bridge-geo-1"])

        // Legacy catches up within one coalesced flush.
        let mirrored = await TestHelpers.waitUntil(
            {
                legacy.messages(for: .mesh).map(\.id) == ["bridge-pub-1"]
                    && legacy.messages(for: .geohash("u4pruyd")).map(\.id) == ["bridge-geo-1"]
            },
            timeout: 1.0
        )
        #expect(mirrored)
    }

    @Test("removing a public conversation empties its Legacy mirror immediately")
    @MainActor
    func publicConversationRemovalClearsLegacy() async {
        let (viewModel, store, legacy, _) = makeBridgedFixture()
        viewModel.appendPublicMessage(
            BitchatMessage(
                id: "bridge-pub-2",
                sender: "alice",
                content: "soon gone",
                timestamp: Date(),
                isRelay: false
            ),
            to: .mesh
        )
        let mirrored = await TestHelpers.waitUntil(
            { legacy.messages(for: .mesh).map(\.id) == ["bridge-pub-2"] },
            timeout: 1.0
        )
        #expect(mirrored)

        // Panic-style removal: Legacy must never show stale public messages.
        store.removeConversation(.mesh)
        #expect(legacy.messages(for: .mesh).isEmpty)
    }
}
