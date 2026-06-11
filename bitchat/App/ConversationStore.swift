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

    /// All message IDs currently in this conversation (unordered).
    var messageIDs: Dictionary<String, Int>.Keys {
        indexByMessageID.keys
    }

    // MARK: Store-internal mutations

    /// Result of an ordered insert. `trimmedMessageIDs` reports messages
    /// evicted by the cap so the store can keep its message-ID →
    /// conversation map exact.
    fileprivate struct InsertResult {
        let inserted: Bool
        let trimmedMessageIDs: [String]

        static let duplicate = InsertResult(inserted: false, trimmedMessageIDs: [])
    }

    fileprivate enum UpsertOutcome {
        case appended(trimmedMessageIDs: [String])
        case updated
    }

    /// Inserts a message in timestamp order, deduplicating by message ID.
    /// Fast path appends when the timestamp is >= the current tail;
    /// otherwise a binary search finds the upper-bound insertion point so
    /// arrival order is preserved among equal timestamps.
    /// Reports `inserted: false` if a message with the same ID already exists.
    fileprivate func insert(_ message: BitchatMessage) -> InsertResult {
        guard indexByMessageID[message.id] == nil else { return .duplicate }

        if let last = messages.last, message.timestamp < last.timestamp {
            let index = insertionIndex(for: message.timestamp)
            messages.insert(message, at: index)
            reindex(from: index)
        } else {
            messages.append(message)
            indexByMessageID[message.id] = messages.count - 1
        }

        return InsertResult(inserted: true, trimmedMessageIDs: trimIfNeeded())
    }

    /// Replace-or-append by message ID. An existing message keeps its
    /// timeline position (in-place updates like media progress reuse the
    /// original timestamp); a new message goes through ordered insertion.
    fileprivate func upsert(_ message: BitchatMessage) -> UpsertOutcome {
        if let index = indexByMessageID[message.id] {
            messages[index] = message
            return .updated
        }
        let result = insert(message)
        return .appended(trimmedMessageIDs: result.trimmedMessageIDs)
    }

    /// Applies a delivery status keyed by message ID, honoring the
    /// no-downgrade rule (the SOLE enforcement point — every delivery
    /// update flows through the store): equal statuses are skipped, and
    /// `.read` is never downgraded to `.delivered` or `.sent`.
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

    /// Removes every message matching `predicate`. Returns the removed
    /// message IDs (empty when nothing matched).
    fileprivate func removeAll(where predicate: (BitchatMessage) -> Bool) -> [String] {
        var removedIDs: [String] = []
        messages.removeAll { message in
            guard predicate(message) else { return false }
            removedIDs.append(message.id)
            return true
        }
        guard !removedIDs.isEmpty else { return [] }
        for id in removedIDs {
            indexByMessageID.removeValue(forKey: id)
        }
        reindex(from: 0)
        return removedIDs
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

    /// Trims oldest messages over the cap; returns the trimmed message IDs.
    private func trimIfNeeded() -> [String] {
        guard messages.count > cap else { return [] }
        let overflow = messages.count - cap
        let trimmedIDs = messages.prefix(overflow).map(\.id)
        for id in trimmedIDs {
            indexByMessageID.removeValue(forKey: id)
        }
        messages.removeFirst(overflow)
        reindex(from: 0)
        return trimmedIDs
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

    /// Store-level message-ID → conversation-membership map for ID-only
    /// lookups (delivery receipts arrive with a message ID, not a
    /// conversation). Maintained incrementally at every mutation point —
    /// all mutation is centralized in the intent API below, so the map is
    /// exact, never scanned or rebuilt.
    ///
    /// The value is a `Set` because a private message can legitimately live
    /// in TWO direct conversations: step 2's raw per-peer keying mirrors a
    /// message into both the stable-key and ephemeral-peer chats
    /// (`mirrorToEphemeralIfNeeded`). A delivery update must reach both
    /// copies.
    private var conversationIDsByMessageID: [String: Set<ConversationID>] = [:]

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
        let result = conversation.insert(message)
        guard result.inserted else { return false }
        registerMessageID(message.id, in: id)
        unregisterMessageIDs(result.trimmedMessageIDs, from: id)
        changes.send(.appended(id, message))
        return true
    }

    /// Replace-or-append by message ID (media progress, edits).
    func upsertByID(_ message: BitchatMessage, in id: ConversationID) {
        let conversation = conversation(for: id)
        switch conversation.upsert(message) {
        case .appended(let trimmedMessageIDs):
            registerMessageID(message.id, in: id)
            unregisterMessageIDs(trimmedMessageIDs, from: id)
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

    /// Applies a delivery status to EVERY conversation containing
    /// `messageID` (ID-only — delivery receipts don't know conversations;
    /// mirrored private copies live in two direct chats). Returns `false`
    /// when the message is unknown or no copy changed (equal status or
    /// downgrade — read beats delivered beats sent).
    ///
    /// `BitchatMessage` is a reference type, so mirrored copies sharing one
    /// instance are updated by the first apply; subsequent conversations
    /// skip as already-equal (state stays correct everywhere, the
    /// `.statusChanged` event fires for the conversation that applied).
    @discardableResult
    func setDeliveryStatus(_ status: DeliveryStatus, forMessageID messageID: String) -> Bool {
        guard let ids = conversationIDsByMessageID[messageID] else { return false }
        var applied = false
        for id in ids where setDeliveryStatus(status, forMessageID: messageID, in: id) {
            applied = true
        }
        return applied
    }

    /// Current delivery status of `messageID` in whichever conversation
    /// holds it (mirrored copies share status — see `setDeliveryStatus`).
    func deliveryStatus(forMessageID messageID: String) -> DeliveryStatus? {
        guard let ids = conversationIDsByMessageID[messageID] else { return nil }
        for id in ids {
            if let status = conversationsByID[id]?.message(withID: messageID)?.deliveryStatus {
                return status
            }
        }
        return nil
    }

    /// Every conversation currently containing `messageID` (empty when the
    /// message is unknown).
    func conversationIDs(forMessageID messageID: String) -> Set<ConversationID> {
        conversationIDsByMessageID[messageID] ?? []
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
            let result = destinationConversation.insert(message)
            guard result.inserted else { continue }
            registerMessageID(message.id, in: destination)
            unregisterMessageIDs(result.trimmedMessageIDs, from: destination)
        }
        for messageID in sourceConversation.messageIDs {
            unregisterMessageID(messageID, from: source)
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
        unregisterMessageID(messageID, from: id)
        changes.send(.messageRemoved(id, messageID: messageID))
        return removed
    }

    /// Removes every message matching `predicate` from a conversation,
    /// emitting one `.messageRemoved` per removed message after the
    /// conversation is consistent. No-op for unknown conversations.
    func removeMessages(from id: ConversationID, where predicate: (BitchatMessage) -> Bool) {
        guard let conversation = conversationsByID[id] else { return }
        let removedIDs = conversation.removeAll(where: predicate)
        unregisterMessageIDs(removedIDs, from: id)
        for messageID in removedIDs {
            changes.send(.messageRemoved(id, messageID: messageID))
        }
    }

    /// Empties a conversation's timeline but keeps the conversation (and
    /// its unread/selection state) alive.
    func clear(_ id: ConversationID) {
        guard let conversation = conversationsByID[id] else { return }
        for messageID in conversation.messageIDs {
            unregisterMessageID(messageID, from: id)
        }
        conversation.clearMessages()
        changes.send(.cleared(id))
    }

    /// Removes a conversation entirely, including unread state; clears the
    /// selection if it pointed at the removed conversation.
    func removeConversation(_ id: ConversationID) {
        guard let conversation = conversationsByID.removeValue(forKey: id) else { return }
        for messageID in conversation.messageIDs {
            unregisterMessageID(messageID, from: id)
        }
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
        conversationIDsByMessageID.removeAll()
        if selectedConversationID != nil {
            selectedConversationID = nil
        }

        for id in removedIDs {
            changes.send(.removed(id))
        }
    }

    // MARK: Internals

    private func registerMessageID(_ messageID: String, in id: ConversationID) {
        conversationIDsByMessageID[messageID, default: []].insert(id)
    }

    private func unregisterMessageID(_ messageID: String, from id: ConversationID) {
        guard var ids = conversationIDsByMessageID[messageID] else { return }
        ids.remove(id)
        if ids.isEmpty {
            conversationIDsByMessageID.removeValue(forKey: messageID)
        } else {
            conversationIDsByMessageID[messageID] = ids
        }
    }

    private func unregisterMessageIDs(_ messageIDs: [String], from id: ConversationID) {
        for messageID in messageIDs {
            unregisterMessageID(messageID, from: id)
        }
    }

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
    /// (O(1) via the store-level message-ID → conversation map).
    func directConversationsContainMessage(withID messageID: String) -> Bool {
        conversationIDs(forMessageID: messageID).contains { id in
            if case .direct = id { return true }
            return false
        }
    }

    /// Message IDs across all direct conversations (read-receipt pruning
    /// keeps only receipts whose messages still exist).
    func directMessageIDs() -> Set<String> {
        var messageIDs = Set<String>()
        for (id, conversation) in conversationsByID {
            guard case .direct = id else { continue }
            messageIDs.formUnion(conversation.messageIDs)
        }
        return messageIDs
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

// MARK: - Migration step 3 compatibility (public timeline derived views)

extension ConversationStore {
    /// Removes a message by ID from whichever public (mesh/geohash)
    /// conversation contains it — the compat shape of the legacy
    /// `PublicTimelineStore.removeMessage(withID:)`. Returns the removed
    /// message, if any.
    @discardableResult
    func removePublicMessage(withID messageID: String) -> BitchatMessage? {
        for id in conversationIDs(forMessageID: messageID) {
            switch id {
            case .mesh, .geohash:
                return removeMessage(withID: messageID, from: id)
            case .direct:
                continue
            }
        }
        return nil
    }
}
