//
// LegacyConversationStoreBridge.swift
// bitchat
//
// Migration step 2 adapter (DELETE IN STEP 5, see
// docs/CONVERSATION-STORE-DESIGN.md §4).
//
// The new `ConversationStore` is the single writer for private (direct) AND
// public (mesh/geohash) message state; the feature models
// (`PrivateInboxModel`, `PrivateConversationModel`, `ConversationUIModel`,
// `PeerListModel`, `PublicChatModel`) still read the replace-based
// `LegacyConversationStore` until step 5. This bridge keeps Legacy fed from
// the new store's `changes` subject: per-message changes mark the affected
// conversation dirty and a `Task.yield`-coalesced flush mirrors only the
// dirty conversations — a burst of N appends costs ONE Legacy replace (like
// the old debounced sync) without the full-dict pass. Structural direct
// changes (migration/removal) resynchronize immediately; public removals
// mirror an empty timeline. Legacy is therefore eventually consistent within
// one run-loop tick — the same visibility the old sinks and per-message
// public syncs provided — while the new store stays synchronously
// authoritative.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Combine
import Foundation

@MainActor
final class LegacyConversationStoreBridge {
    private let store: ConversationStore
    private let legacyStore: LegacyConversationStore
    private let identityResolver: IdentityResolver
    private var cancellable: AnyCancellable?

    private var dirtyConversations: Set<ConversationID> = []
    private var pendingFlushTask: Task<Void, Never>?

    init(
        store: ConversationStore,
        legacyStore: LegacyConversationStore,
        identityResolver: IdentityResolver
    ) {
        self.store = store
        self.legacyStore = legacyStore
        self.identityResolver = identityResolver

        cancellable = store.changes.sink { [weak self] change in
            self?.apply(change)
        }
    }

    /// Full resynchronization of every direct conversation into Legacy.
    ///
    /// Needed when `IdentityResolver` learns new peer associations (the
    /// canonical handle for an existing conversation can change, re-keying
    /// it in Legacy) and after structural store changes. This is the old
    /// `synchronizePrivateChats` full pass — acceptable because it only runs
    /// on peer-list changes and rare migrations, never per message.
    func resynchronizeAll() {
        // The full pass covers every direct conversation; pending direct
        // per-conversation work is redundant. Dirty public conversations
        // keep their scheduled mirror.
        dirtyConversations = dirtyConversations.filter { !isDirect($0) }
        legacyStore.synchronizePrivateChats(
            store.directMessagesByRoutingPeerID(),
            unreadPeerIDs: store.unreadDirectRoutingPeerIDs(),
            identityResolver: identityResolver
        )
    }
}

private extension LegacyConversationStoreBridge {
    func apply(_ change: ConversationChange) {
        switch change {
        case .appended(let id, _),
             .updated(let id, _),
             .statusChanged(let id, _, _),
             .messageRemoved(let id, _),
             .cleared(let id):
            markDirty(id)

        case .unreadChanged(let id, let isUnread):
            guard case .direct(let handle) = id else { return }
            if isUnread {
                legacyStore.markUnread(peerID: handle.routingPeerID, identityResolver: identityResolver)
            } else {
                legacyStore.markRead(peerID: handle.routingPeerID, identityResolver: identityResolver)
            }

        case .migrated(let source, let destination):
            guard isDirect(source) || isDirect(destination) else { return }
            resynchronizeAll()

        case .removed(let id):
            if isDirect(id) {
                resynchronizeAll()
            } else {
                // Public conversation removed (panic clear): mirror an empty
                // timeline immediately so Legacy readers never show stale
                // messages.
                dirtyConversations.remove(id)
                legacyStore.replaceMessages([], for: id)
            }
        }
    }

    func markDirty(_ id: ConversationID) {
        dirtyConversations.insert(id)
        scheduleFlush()
    }

    /// One pending flush at a time, exactly like the old
    /// `schedulePrivateConversationStoreSynchronization` debounce: a
    /// synchronous burst of mutations coalesces into a single flush on the
    /// next main-actor turn.
    func scheduleFlush() {
        guard pendingFlushTask == nil else { return }
        pendingFlushTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.pendingFlushTask = nil
            self.flushDirtyConversations()
        }
    }

    func flushDirtyConversations() {
        guard !dirtyConversations.isEmpty else { return }
        let dirty = dirtyConversations
        dirtyConversations.removeAll()
        for id in dirty {
            mirrorConversation(id)
        }
    }

    func mirrorConversation(_ id: ConversationID) {
        guard let conversation = store.conversationsByID[id] else {
            // Removed while dirty; the removal already resynchronized
            // (direct) or mirrored an empty timeline (public).
            return
        }
        switch id {
        case .direct(let handle):
            legacyStore.replaceDirectMessages(
                conversation.messages,
                for: handle.routingPeerID,
                identityResolver: identityResolver
            )
        case .mesh, .geohash:
            legacyStore.replaceMessages(conversation.messages, for: id)
        }
    }

    func isDirect(_ id: ConversationID) -> Bool {
        if case .direct = id { return true }
        return false
    }
}
