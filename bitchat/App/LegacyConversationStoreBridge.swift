//
// LegacyConversationStoreBridge.swift
// bitchat
//
// Migration step 2 adapter (DELETE IN STEP 5, see
// docs/CONVERSATION-STORE-DESIGN.md §4).
//
// The new `ConversationStore` is the single writer for private (direct)
// message state; the feature models (`PrivateInboxModel`,
// `PrivateConversationModel`, `ConversationUIModel`, `PeerListModel`) still
// read the replace-based `LegacyConversationStore` until step 5. This bridge
// keeps Legacy fed from the new store's `changes` subject: per-message
// changes mark the affected conversation dirty and a `Task.yield`-coalesced
// flush mirrors only the dirty conversations — a burst of N appends costs
// ONE Legacy replace (like the old debounced sync) without the full-dict
// pass. Structural changes (migration/removal) resynchronize immediately.
// Legacy is therefore eventually consistent within one run-loop tick — the
// same visibility the old `$privateChats` sink provided — while the new
// store stays synchronously authoritative.
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
        // The full pass covers every conversation; pending per-conversation
        // work is redundant.
        dirtyConversations.removeAll()
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
            guard isDirect(id) else { return }
            resynchronizeAll()
        }
    }

    func markDirty(_ id: ConversationID) {
        guard isDirect(id) else { return }
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
        guard case .direct(let handle) = id,
              let conversation = store.conversationsByID[id] else {
            // Removed while dirty; the removal already resynchronized.
            return
        }
        legacyStore.replaceDirectMessages(
            conversation.messages,
            for: handle.routingPeerID,
            identityResolver: identityResolver
        )
    }

    func isDirect(_ id: ConversationID) -> Bool {
        if case .direct = id { return true }
        return false
    }
}
