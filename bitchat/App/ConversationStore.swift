//
// ConversationStore.swift
// bitchat
//
// Single source of truth for conversation message state (see
// docs/CONVERSATION-STORE-DESIGN.md). One `Conversation` object per
// `ConversationID`; all mutations flow through the store's intent API and
// every mutation emits a `ConversationChange` after state is consistent.
//
// During migration the previous replace-based store lives on as
// `LegacyConversationStore` (AppArchitecture.swift) and is deleted in the
// final migration step.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Combine
import Foundation

// MARK: - Conversation

/// A single conversation timeline (`.mesh`, `.geohash`, or `.direct`).
///
/// Publishing granularity is per conversation: views observe ONE
/// `Conversation` object, so an append to chat A never invalidates observers
/// of chat B.
///
/// Mutations are `fileprivate` by design — only `ConversationStore`'s intent
/// API may mutate a conversation, keeping the store the sole writer.
@MainActor
final class Conversation: ObservableObject, Identifiable {
    let id: ConversationID
    /// Maximum retained messages; oldest are trimmed on overflow.
    let cap: Int

    @Published private(set) var messages: [BitchatMessage] = []
    @Published private(set) var isUnread: Bool = false

    /// Incrementally-maintained message-ID → index map for O(1) dedup and
    /// delivery-status lookup. Kept in sync on every mutation:
    /// - tail append: single insert
    /// - out-of-order insert: suffix reindex from the insertion point
    /// - trim: full rebuild — `removeFirst(k)` is already O(n), so the
    ///   rebuild does not change the asymptotics, and trim only happens once
    ///   the cap (1337) is reached. Simple and correct beats the
    ///   offset-tracking alternative here.
    private var indexByMessageID: [String: Int] = [:]

    fileprivate init(id: ConversationID, cap: Int) {
        self.id = id
        self.cap = max(1, cap)
    }

    // MARK: Reads

    func containsMessage(withID messageID: String) -> Bool {
        indexByMessageID[messageID] != nil
    }

    func message(withID messageID: String) -> BitchatMessage? {
        guard let index = indexByMessageID[messageID] else { return nil }
        return messages[index]
    }

    // MARK: Store-internal mutations

    fileprivate enum UpsertOutcome {
        case appended
        case updated
    }

    /// Inserts a message in timestamp order, deduplicating by message ID.
    /// Fast path appends when the timestamp is >= the current tail;
    /// otherwise a binary search finds the upper-bound insertion point so
    /// arrival order is preserved among equal timestamps.
    /// Returns `false` if a message with the same ID already exists.
    fileprivate func insert(_ message: BitchatMessage) -> Bool {
        guard indexByMessageID[message.id] == nil else { return false }

        if let last = messages.last, message.timestamp < last.timestamp {
            let index = insertionIndex(for: message.timestamp)
            messages.insert(message, at: index)
            reindex(from: index)
        } else {
            messages.append(message)
            indexByMessageID[message.id] = messages.count - 1
        }

        trimIfNeeded()
        return true
    }

    /// Replace-or-append by message ID. An existing message keeps its
    /// timeline position (in-place updates like media progress reuse the
    /// original timestamp); a new message goes through ordered insertion.
    fileprivate func upsert(_ message: BitchatMessage) -> UpsertOutcome {
        if let index = indexByMessageID[message.id] {
            messages[index] = message
            return .updated
        }
        _ = insert(message)
        return .appended
    }

    /// Applies a delivery status keyed by message ID, honoring the
    /// no-downgrade rule (mirrors `ChatDeliveryCoordinator.shouldSkipUpdate`):
    /// equal statuses are skipped, and `.read` is never downgraded to
    /// `.delivered` or `.sent`.
    /// Returns `true` when the status was applied.
    fileprivate func applyDeliveryStatus(_ status: DeliveryStatus, forMessageID messageID: String) -> Bool {
        guard let index = indexByMessageID[messageID] else { return false }
        let message = messages[index]
        guard !Self.shouldSkipStatusUpdate(current: message.deliveryStatus, new: status) else { return false }

        message.deliveryStatus = status
        // BitchatMessage is a reference type; write back through the
        // subscript so the @Published wrapper emits.
        messages[index] = message
        return true
    }

    @discardableResult
    fileprivate func setUnread(_ unread: Bool) -> Bool {
        guard isUnread != unread else { return false }
        isUnread = unread
        return true
    }

    /// Removes a single message by ID. Returns the removed message, or
    /// `nil` when no message with that ID exists.
    fileprivate func remove(messageID: String) -> BitchatMessage? {
        guard let index = indexByMessageID[messageID] else { return nil }
        let removed = messages.remove(at: index)
        indexByMessageID.removeValue(forKey: messageID)
        reindex(from: index)
        return removed
    }

    fileprivate func clearMessages() {
        messages.removeAll()
        indexByMessageID.removeAll()
    }

    // MARK: Internals

    static func shouldSkipStatusUpdate(current: DeliveryStatus?, new: DeliveryStatus) -> Bool {
        guard let current else { return false }
        if current == new { return true }

        switch (current, new) {
        case (.read, .delivered), (.read, .sent):
            return true
        default:
            return false
        }
    }

    /// Upper-bound binary search: first index whose timestamp is strictly
    /// greater than `timestamp`, so equal-timestamp messages keep arrival
    /// order.
    private func insertionIndex(for timestamp: Date) -> Int {
        var low = 0
        var high = messages.count
        while low < high {
            let mid = (low + high) / 2
            if messages[mid].timestamp <= timestamp {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private func reindex(from start: Int) {
        for index in start..<messages.count {
            indexByMessageID[messages[index].id] = index
        }
    }

    private func trimIfNeeded() {
        guard messages.count > cap else { return }
        let overflow = messages.count - cap
        for message in messages.prefix(overflow) {
            indexByMessageID.removeValue(forKey: message.id)
        }
        messages.removeFirst(overflow)
        reindex(from: 0)
    }
}

// MARK: - ConversationChange

/// Typed mutation events for non-UI consumers (delivery tracking,
/// notifications, sync) that need "something changed in conversation X"
/// without subscribing to whole message arrays. Emitted on the store's
/// `changes` subject AFTER the corresponding state is consistent.
enum ConversationChange {
    case appended(ConversationID, BitchatMessage)
    case updated(ConversationID, messageID: String)
    case statusChanged(ConversationID, messageID: String, DeliveryStatus)
    case messageRemoved(ConversationID, messageID: String)
    case cleared(ConversationID)
    case removed(ConversationID)
    case migrated(from: ConversationID, to: ConversationID)
    case unreadChanged(ConversationID, isUnread: Bool)
}

// MARK: - ConversationStore

/// Sole writer and sole holder of conversation message state. All mutations
/// go through the intent API below; backing collections are `private(set)`.
/// Reads are synchronous — writers and readers share the main actor, so
/// after an intent returns every observer sees the result.
@MainActor
final class ConversationStore: ObservableObject {
    /// Conversation creation order; published so list-style consumers can
    /// observe conversations appearing/disappearing without rebuilding from
    /// the dictionary.
    @Published private(set) var conversationIDs: [ConversationID] = []
    @Published private(set) var selectedConversationID: ConversationID?
    @Published private(set) var unreadConversations: Set<ConversationID> = []

    private(set) var conversationsByID: [ConversationID: Conversation] = [:]

    let changes = PassthroughSubject<ConversationChange, Never>()

    // MARK: Intent API

    /// Returns the conversation for `id`, creating it (with the cap policy
    /// for its kind) on first access.
    @discardableResult
    func conversation(for id: ConversationID) -> Conversation {
        if let existing = conversationsByID[id] {
            return existing
        }
        let conversation = Conversation(id: id, cap: Self.cap(for: id))
        conversationsByID[id] = conversation
        conversationIDs.append(id)
        return conversation
    }

    /// Appends a message in timestamp order. Returns `false` (and emits
    /// nothing) if a message with the same ID is already present.
    @discardableResult
    func append(_ message: BitchatMessage, to id: ConversationID) -> Bool {
        let conversation = conversation(for: id)
        guard conversation.insert(message) else { return false }
        changes.send(.appended(id, message))
        return true
    }

    /// Replace-or-append by message ID (media progress, edits).
    func upsertByID(_ message: BitchatMessage, in id: ConversationID) {
        let conversation = conversation(for: id)
        switch conversation.upsert(message) {
        case .appended:
            changes.send(.appended(id, message))
        case .updated:
            changes.send(.updated(id, messageID: message.id))
        }
    }

    /// Applies a delivery status keyed by message ID. Returns `false` when
    /// the message is unknown or the update would downgrade the status
    /// (read beats delivered beats sent).
    @discardableResult
    func setDeliveryStatus(_ status: DeliveryStatus, forMessageID messageID: String, in id: ConversationID) -> Bool {
        guard let conversation = conversationsByID[id],
              conversation.applyDeliveryStatus(status, forMessageID: messageID) else {
            return false
        }
        changes.send(.statusChanged(id, messageID: messageID, status))
        return true
    }

    func markRead(_ id: ConversationID) {
        guard unreadConversations.contains(id) else { return }
        unreadConversations.remove(id)
        conversationsByID[id]?.setUnread(false)
        changes.send(.unreadChanged(id, isUnread: false))
    }

    func markUnread(_ id: ConversationID) {
        guard !unreadConversations.contains(id) else { return }
        let conversation = conversation(for: id)
        unreadConversations.insert(id)
        conversation.setUnread(true)
        changes.send(.unreadChanged(id, isUnread: true))
    }

    /// Selects a conversation (creating it if needed) or clears the
    /// selection with `nil`.
    func select(_ id: ConversationID?) {
        if let id {
            conversation(for: id)
        }
        guard selectedConversationID != id else { return }
        selectedConversationID = id
    }

    /// Moves all messages from `source` into `destination` (the
    /// ephemeral↔stable peer-ID handoff): dedups by message ID, preserves
    /// timestamp order, carries unread state over, and hands off the
    /// selection — mirroring `ChatPrivateConversationCoordinator`'s
    /// migration semantics. The source conversation is removed. Emits a
    /// single `.migrated(from:to:)` once the whole move is consistent.
    func migrateConversation(from source: ConversationID, to destination: ConversationID) {
        guard source != destination, let sourceConversation = conversationsByID[source] else { return }

        let destinationConversation = conversation(for: destination)
        for message in sourceConversation.messages {
            _ = destinationConversation.insert(message)
        }

        let wasUnread = unreadConversations.contains(source)
        let wasSelected = selectedConversationID == source

        conversationsByID.removeValue(forKey: source)
        conversationIDs.removeAll { $0 == source }
        unreadConversations.remove(source)

        if wasUnread, !unreadConversations.contains(destination) {
            unreadConversations.insert(destination)
            destinationConversation.setUnread(true)
        }
        if wasSelected {
            selectedConversationID = destination
        }

        changes.send(.migrated(from: source, to: destination))
    }

    /// Removes a single message by ID from a conversation. Returns the
    /// removed message, or `nil` (emitting nothing) when the conversation or
    /// message is unknown.
    @discardableResult
    func removeMessage(withID messageID: String, from id: ConversationID) -> BitchatMessage? {
        guard let conversation = conversationsByID[id],
              let removed = conversation.remove(messageID: messageID) else {
            return nil
        }
        changes.send(.messageRemoved(id, messageID: messageID))
        return removed
    }

    /// Empties a conversation's timeline but keeps the conversation (and
    /// its unread/selection state) alive.
    func clear(_ id: ConversationID) {
        guard let conversation = conversationsByID[id] else { return }
        conversation.clearMessages()
        changes.send(.cleared(id))
    }

    /// Removes a conversation entirely, including unread state; clears the
    /// selection if it pointed at the removed conversation.
    func removeConversation(_ id: ConversationID) {
        guard conversationsByID.removeValue(forKey: id) != nil else { return }
        conversationIDs.removeAll { $0 == id }
        unreadConversations.remove(id)
        if selectedConversationID == id {
            selectedConversationID = nil
        }
        changes.send(.removed(id))
    }

    func clearAll() {
        let removedIDs = conversationIDs
        guard !removedIDs.isEmpty || selectedConversationID != nil else { return }

        conversationsByID.removeAll()
        conversationIDs.removeAll()
        unreadConversations.removeAll()
        if selectedConversationID != nil {
            selectedConversationID = nil
        }

        for id in removedIDs {
            changes.send(.removed(id))
        }
    }

    // MARK: Internals

    private static func cap(for id: ConversationID) -> Int {
        switch id {
        case .mesh:
            return TransportConfig.meshTimelineCap
        case .geohash:
            return TransportConfig.geoTimelineCap
        case .direct:
            return TransportConfig.privateChatCap
        }
    }
}

// MARK: - Migration step 2 compatibility (raw per-peer keying + derived views)

extension ConversationID {
    /// Direct-conversation ID keyed by the *raw* routing peer ID.
    ///
    /// Migration step 2 keeps one conversation per `PeerID` — exactly the
    /// buckets the legacy `privateChats` dictionary had — so the
    /// ephemeral/stable mirroring and consolidation coordinators keep their
    /// current semantics. Step 5 canonicalizes direct conversations through
    /// `IdentityResolver` and this helper goes away.
    static func directPeer(_ peerID: PeerID) -> ConversationID {
        .direct(PeerHandle(
            id: "peer:\(peerID.id)",
            routingPeerID: peerID,
            displayName: nil,
            noisePublicKeyHex: nil,
            nostrPublicKey: nil
        ))
    }
}

extension ConversationStore {
    /// All direct conversations' messages keyed by routing peer ID — the
    /// compat shape of the legacy `privateChats` dictionary. Values are the
    /// conversations' backing arrays (COW), so building this is
    /// O(#conversations), not O(#messages).
    func directMessagesByRoutingPeerID() -> [PeerID: [BitchatMessage]] {
        var messagesByPeerID: [PeerID: [BitchatMessage]] = [:]
        messagesByPeerID.reserveCapacity(conversationsByID.count)
        for (id, conversation) in conversationsByID {
            guard case .direct(let handle) = id else { continue }
            messagesByPeerID[handle.routingPeerID] = conversation.messages
        }
        return messagesByPeerID
    }

    /// Unread direct conversations as routing peer IDs — the compat shape of
    /// the legacy `unreadPrivateMessages` set.
    func unreadDirectRoutingPeerIDs() -> Set<PeerID> {
        var peerIDs = Set<PeerID>()
        for id in unreadConversations {
            guard case .direct(let handle) = id else { continue }
            peerIDs.insert(handle.routingPeerID)
        }
        return peerIDs
    }

    /// `true` when any direct conversation contains a message with `messageID`
    /// (O(1) per conversation via the incremental ID index).
    func directConversationsContainMessage(withID messageID: String) -> Bool {
        for (id, conversation) in conversationsByID {
            guard case .direct = id else { continue }
            if conversation.containsMessage(withID: messageID) { return true }
        }
        return false
    }

    /// Removes every direct conversation (panic clear).
    func removeAllDirectConversations() {
        let directIDs = conversationIDs.filter { id in
            if case .direct = id { return true }
            return false
        }
        for id in directIDs {
            removeConversation(id)
        }
    }
}
