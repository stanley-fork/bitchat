//
// ConversationStoreTests.swift
// bitchatTests
//
// Tests for the new single-source-of-truth ConversationStore
// (docs/CONVERSATION-STORE-DESIGN.md): intent API, ordered insertion,
// dedup, caps, delivery-status rules, migration, unread state, change
// emission, and per-conversation publish isolation.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Combine
import Foundation
import Testing
@testable import bitchat

@MainActor
private func makeMessage(
    id: String,
    timestamp: TimeInterval,
    content: String? = nil,
    isPrivate: Bool = false,
    deliveryStatus: DeliveryStatus? = nil
) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: "alice",
        content: content ?? "message \(id)",
        timestamp: Date(timeIntervalSince1970: timestamp),
        isRelay: false,
        isPrivate: isPrivate,
        recipientNickname: isPrivate ? "bob" : nil,
        senderPeerID: PeerID(str: "peer-a"),
        deliveryStatus: deliveryStatus
    )
}

private func makeDirectConversationID(_ suffix: String) -> ConversationID {
    .direct(PeerHandle(
        id: "noise:\(suffix)",
        routingPeerID: PeerID(str: "peer-\(suffix)"),
        displayName: "peer \(suffix)",
        noisePublicKeyHex: suffix,
        nostrPublicKey: nil
    ))
}

@Suite("ConversationStore")
struct ConversationStoreTests {

    // MARK: - Append, dedup, ordering

    @Test("append dedups by message ID and reports duplicates")
    @MainActor
    func appendDedupsByMessageID() {
        let store = ConversationStore()
        var received: [ConversationChange] = []
        let cancellable = store.changes.sink { received.append($0) }
        defer { cancellable.cancel() }

        #expect(store.append(makeMessage(id: "m1", timestamp: 1), to: .mesh))
        #expect(!store.append(makeMessage(id: "m1", timestamp: 2, content: "dup"), to: .mesh))

        let conversation = store.conversation(for: .mesh)
        #expect(conversation.messages.count == 1)
        #expect(conversation.messages.first?.content == "message m1")
        #expect(conversation.containsMessage(withID: "m1"))
        #expect(received.count == 1)
        guard case .appended(.mesh, let message) = received.first else {
            Issue.record("expected a single .appended change, got \(received)")
            return
        }
        #expect(message.id == "m1")
    }

    @Test("out-of-order appends are inserted in timestamp order")
    @MainActor
    func outOfOrderInsertKeepsTimestampOrder() {
        let store = ConversationStore()

        store.append(makeMessage(id: "m1", timestamp: 10), to: .mesh)
        store.append(makeMessage(id: "m3", timestamp: 30), to: .mesh)
        store.append(makeMessage(id: "m2", timestamp: 20), to: .mesh)
        store.append(makeMessage(id: "m0", timestamp: 5), to: .mesh)

        let conversation = store.conversation(for: .mesh)
        #expect(conversation.messages.map(\.id) == ["m0", "m1", "m2", "m3"])

        // The ID index must survive middle inserts: lookups by ID still
        // resolve to the right message.
        #expect(conversation.message(withID: "m2")?.timestamp == Date(timeIntervalSince1970: 20))
        #expect(conversation.message(withID: "m0")?.timestamp == Date(timeIntervalSince1970: 5))
    }

    @Test("equal timestamps preserve arrival order")
    @MainActor
    func equalTimestampsPreserveArrivalOrder() {
        let store = ConversationStore()

        store.append(makeMessage(id: "first", timestamp: 10), to: .mesh)
        store.append(makeMessage(id: "second", timestamp: 10), to: .mesh)
        // A late message with an equal timestamp lands after existing peers.
        store.append(makeMessage(id: "late-tail", timestamp: 20), to: .mesh)
        store.append(makeMessage(id: "third", timestamp: 10), to: .mesh)

        let conversation = store.conversation(for: .mesh)
        #expect(conversation.messages.map(\.id) == ["first", "second", "third", "late-tail"])
    }

    // MARK: - Caps

    @Test("cap trims oldest messages and keeps the ID index valid")
    @MainActor
    func capTrimsOldestAndKeepsIndexValid() {
        let store = ConversationStore()
        let conversation = store.conversation(for: .mesh)
        let cap = conversation.cap
        #expect(cap == TransportConfig.meshTimelineCap)

        let overflow = 3
        for i in 0..<(cap + overflow) {
            store.append(makeMessage(id: "m\(i)", timestamp: TimeInterval(i)), to: .mesh)
        }

        #expect(conversation.messages.count == cap)
        #expect(conversation.messages.first?.id == "m\(overflow)")
        #expect(conversation.messages.last?.id == "m\(cap + overflow - 1)")

        // Trimmed messages left the index entirely…
        for i in 0..<overflow {
            #expect(!conversation.containsMessage(withID: "m\(i)"))
        }
        // …and re-appending a trimmed ID is allowed (no stale index entry).
        #expect(store.append(makeMessage(id: "m0", timestamp: TimeInterval(cap + overflow)), to: .mesh))

        // Surviving entries still resolve correctly after the trim reindex.
        let probeID = "m\(cap / 2 + overflow)"
        #expect(conversation.message(withID: probeID)?.id == probeID)
        #expect(store.setDeliveryStatus(.sent, forMessageID: probeID, in: .mesh))
        #expect(conversation.message(withID: probeID)?.deliveryStatus == .sent)
    }

    // MARK: - Upsert

    @Test("upsertByID replaces in place and appends when absent")
    @MainActor
    func upsertReplacesOrAppends() {
        let store = ConversationStore()
        var received: [ConversationChange] = []
        let cancellable = store.changes.sink { received.append($0) }
        defer { cancellable.cancel() }

        store.upsertByID(makeMessage(id: "m1", timestamp: 10), in: .mesh)
        store.append(makeMessage(id: "m2", timestamp: 20), to: .mesh)
        store.upsertByID(makeMessage(id: "m1", timestamp: 10, content: "edited"), in: .mesh)

        let conversation = store.conversation(for: .mesh)
        #expect(conversation.messages.map(\.id) == ["m1", "m2"])
        #expect(conversation.message(withID: "m1")?.content == "edited")

        #expect(received.count == 3)
        guard case .appended(.mesh, let first) = received[0], first.id == "m1",
              case .appended(.mesh, let second) = received[1], second.id == "m2",
              case .updated(.mesh, let updatedID) = received[2], updatedID == "m1" else {
            Issue.record("unexpected change sequence: \(received)")
            return
        }
    }

    // MARK: - Delivery status

    @Test("setDeliveryStatus never downgrades read and skips equal statuses")
    @MainActor
    func deliveryStatusNoDowngrade() {
        let store = ConversationStore()
        let id = makeDirectConversationID("aa")
        store.append(makeMessage(id: "m1", timestamp: 1, isPrivate: true, deliveryStatus: .sending), to: id)
        var statusChanges: [DeliveryStatus] = []
        let cancellable = store.changes.sink { change in
            if case .statusChanged(_, _, let status) = change {
                statusChanges.append(status)
            }
        }
        defer { cancellable.cancel() }

        let conversation = store.conversation(for: id)
        let readStatus = DeliveryStatus.read(by: "bob", at: Date(timeIntervalSince1970: 100))

        #expect(store.setDeliveryStatus(.sent, forMessageID: "m1", in: id))
        // Equal status is a no-op.
        #expect(!store.setDeliveryStatus(.sent, forMessageID: "m1", in: id))
        #expect(store.setDeliveryStatus(readStatus, forMessageID: "m1", in: id))
        // Read beats delivered and sent: both downgrades are refused.
        #expect(!store.setDeliveryStatus(.delivered(to: "bob", at: Date()), forMessageID: "m1", in: id))
        #expect(!store.setDeliveryStatus(.sent, forMessageID: "m1", in: id))
        #expect(conversation.message(withID: "m1")?.deliveryStatus == readStatus)

        // Unknown message or conversation: refused, nothing emitted.
        #expect(!store.setDeliveryStatus(.sent, forMessageID: "nope", in: id))
        #expect(!store.setDeliveryStatus(.sent, forMessageID: "m1", in: .mesh))

        #expect(statusChanges == [.sent, readStatus])
    }

    // MARK: - Unread state

    @Test("markUnread and markRead keep the set and conversation flag consistent")
    @MainActor
    func unreadStateConsistency() {
        let store = ConversationStore()
        let id = makeDirectConversationID("bb")
        var unreadChanges: [(ConversationID, Bool)] = []
        let cancellable = store.changes.sink { change in
            if case .unreadChanged(let conversationID, let isUnread) = change {
                unreadChanges.append((conversationID, isUnread))
            }
        }
        defer { cancellable.cancel() }

        // markRead on a never-unread conversation is a no-op.
        store.markRead(id)
        #expect(unreadChanges.isEmpty)

        store.markUnread(id)
        #expect(store.unreadConversations == [id])
        #expect(store.conversation(for: id).isUnread)
        // Idempotent: marking unread twice emits once.
        store.markUnread(id)

        store.markRead(id)
        #expect(store.unreadConversations.isEmpty)
        #expect(!store.conversation(for: id).isUnread)

        #expect(unreadChanges.count == 2)
        #expect(unreadChanges[0].0 == id && unreadChanges[0].1 == true)
        #expect(unreadChanges[1].0 == id && unreadChanges[1].1 == false)
    }

    // MARK: - Selection

    @Test("select creates the conversation and clears with nil")
    @MainActor
    func selectTracksConversation() {
        let store = ConversationStore()
        let id = makeDirectConversationID("cc")

        store.select(id)
        #expect(store.selectedConversationID == id)
        #expect(store.conversationsByID[id] != nil)
        #expect(store.conversationIDs == [id])

        store.select(nil)
        #expect(store.selectedConversationID == nil)
    }

    // MARK: - Migration

    @Test("migrateConversation moves messages, dedups, and preserves order")
    @MainActor
    func migrationMovesAndDedups() {
        let store = ConversationStore()
        let ephemeral = makeDirectConversationID("old")
        let stable = makeDirectConversationID("new")

        store.append(makeMessage(id: "m1", timestamp: 10), to: ephemeral)
        store.append(makeMessage(id: "m3", timestamp: 30), to: ephemeral)
        store.append(makeMessage(id: "m2", timestamp: 20), to: stable)
        store.append(makeMessage(id: "m3", timestamp: 30, content: "already there"), to: stable)

        var received: [ConversationChange] = []
        let cancellable = store.changes.sink { received.append($0) }
        defer { cancellable.cancel() }

        store.migrateConversation(from: ephemeral, to: stable)

        let destination = store.conversation(for: stable)
        #expect(destination.messages.map(\.id) == ["m1", "m2", "m3"])
        // Existing copy wins the dedup.
        #expect(destination.message(withID: "m3")?.content == "already there")
        #expect(store.conversationsByID[ephemeral] == nil)
        #expect(!store.conversationIDs.contains(ephemeral))

        #expect(received.count == 1)
        guard case .migrated(let from, let to) = received.first, from == ephemeral, to == stable else {
            Issue.record("expected a single .migrated change, got \(received)")
            return
        }
    }

    @Test("migrateConversation hands off unread state and selection")
    @MainActor
    func migrationMovesUnreadAndSelection() {
        let store = ConversationStore()
        let ephemeral = makeDirectConversationID("old")
        let stable = makeDirectConversationID("new")

        store.append(makeMessage(id: "m1", timestamp: 10), to: ephemeral)
        store.markUnread(ephemeral)
        store.select(ephemeral)

        store.migrateConversation(from: ephemeral, to: stable)

        #expect(store.unreadConversations == [stable])
        #expect(store.conversation(for: stable).isUnread)
        #expect(store.selectedConversationID == stable)

        // Migrating from a missing source or onto itself is a no-op.
        store.migrateConversation(from: ephemeral, to: stable)
        store.migrateConversation(from: stable, to: stable)
        #expect(store.conversation(for: stable).messages.map(\.id) == ["m1"])
    }

    // MARK: - Clear / remove

    @Test("clear empties the timeline but keeps the conversation")
    @MainActor
    func clearKeepsConversation() {
        let store = ConversationStore()
        let id = makeDirectConversationID("dd")
        store.append(makeMessage(id: "m1", timestamp: 1), to: id)
        store.markUnread(id)
        var received: [ConversationChange] = []
        let cancellable = store.changes.sink { received.append($0) }
        defer { cancellable.cancel() }

        store.clear(id)

        let conversation = store.conversation(for: id)
        #expect(conversation.messages.isEmpty)
        #expect(!conversation.containsMessage(withID: "m1"))
        #expect(store.conversationIDs.contains(id))
        #expect(store.unreadConversations.contains(id))
        // The ID index was cleared too: the same message can return.
        #expect(store.append(makeMessage(id: "m1", timestamp: 2), to: id))

        guard case .cleared(id) = received.first else {
            Issue.record("expected .cleared first, got \(received)")
            return
        }
    }

    @Test("removeConversation drops messages, unread state, and selection")
    @MainActor
    func removeConversationDropsEverything() {
        let store = ConversationStore()
        let id = makeDirectConversationID("ee")
        store.append(makeMessage(id: "m1", timestamp: 1), to: id)
        store.markUnread(id)
        store.select(id)
        var received: [ConversationChange] = []
        let cancellable = store.changes.sink { received.append($0) }
        defer { cancellable.cancel() }

        store.removeConversation(id)

        #expect(store.conversationsByID[id] == nil)
        #expect(store.conversationIDs.isEmpty)
        #expect(store.unreadConversations.isEmpty)
        #expect(store.selectedConversationID == nil)
        #expect(received.count == 1)
        guard case .removed(id) = received.first else {
            Issue.record("expected .removed, got \(received)")
            return
        }

        // Removing again is a no-op.
        store.removeConversation(id)
        #expect(received.count == 1)
    }

    @Test("clearAll removes every conversation and emits removals")
    @MainActor
    func clearAllRemovesEverything() {
        let store = ConversationStore()
        let direct = makeDirectConversationID("ff")
        store.append(makeMessage(id: "m1", timestamp: 1), to: .mesh)
        store.append(makeMessage(id: "m2", timestamp: 2), to: direct)
        store.markUnread(direct)
        store.select(direct)
        var removed: [ConversationID] = []
        let cancellable = store.changes.sink { change in
            if case .removed(let id) = change { removed.append(id) }
        }
        defer { cancellable.cancel() }

        store.clearAll()

        #expect(store.conversationsByID.isEmpty)
        #expect(store.conversationIDs.isEmpty)
        #expect(store.unreadConversations.isEmpty)
        #expect(store.selectedConversationID == nil)
        #expect(removed == [.mesh, direct])
    }

    // MARK: - Change emission

    @Test("changes are emitted after state is consistent")
    @MainActor
    func changesEmittedAfterStateIsConsistent() {
        let store = ConversationStore()
        var observedCountsAtEmission: [Int] = []
        var observedUnreadAtEmission: [Bool] = []
        let cancellable = store.changes.sink { change in
            switch change {
            case .appended(let id, let message):
                // The appended message must already be visible at emission.
                observedCountsAtEmission.append(store.conversation(for: id).messages.count)
                #expect(store.conversation(for: id).containsMessage(withID: message.id))
            case .unreadChanged(let id, let isUnread):
                #expect(store.unreadConversations.contains(id) == isUnread)
                observedUnreadAtEmission.append(isUnread)
            default:
                break
            }
        }
        defer { cancellable.cancel() }

        store.append(makeMessage(id: "m1", timestamp: 1), to: .mesh)
        store.append(makeMessage(id: "m2", timestamp: 2), to: .mesh)
        store.markUnread(.mesh)
        store.markRead(.mesh)

        #expect(observedCountsAtEmission == [1, 2])
        #expect(observedUnreadAtEmission == [true, false])
    }

    @Test("cap policy follows the conversation kind")
    @MainActor
    func capPolicyByKind() {
        let store = ConversationStore()
        #expect(store.conversation(for: .mesh).cap == TransportConfig.meshTimelineCap)
        #expect(store.conversation(for: .geohash("u4pruyd")).cap == TransportConfig.geoTimelineCap)
        #expect(store.conversation(for: makeDirectConversationID("gg")).cap == TransportConfig.privateChatCap)
    }

    // MARK: - Publish isolation

    @Test("appending to one conversation does not publish another")
    @MainActor
    func perConversationPublishIsolation() {
        let store = ConversationStore()
        let a = makeDirectConversationID("aa")
        let b = makeDirectConversationID("bb")
        let conversationA = store.conversation(for: a)
        let conversationB = store.conversation(for: b)

        var aWillChangeCount = 0
        var bWillChangeCount = 0
        var cancellables = Set<AnyCancellable>()
        conversationA.objectWillChange
            .sink { aWillChangeCount += 1 }
            .store(in: &cancellables)
        conversationB.objectWillChange
            .sink { bWillChangeCount += 1 }
            .store(in: &cancellables)

        store.append(makeMessage(id: "m1", timestamp: 1), to: a)
        store.append(makeMessage(id: "m2", timestamp: 2), to: a)
        store.setDeliveryStatus(.sent, forMessageID: "m1", in: a)
        store.markUnread(a)

        #expect(aWillChangeCount >= 4)
        #expect(bWillChangeCount == 0)

        store.append(makeMessage(id: "m3", timestamp: 3), to: b)
        #expect(bWillChangeCount > 0)
    }
}
