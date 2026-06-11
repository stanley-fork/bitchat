//
// PrivateChatManager.swift
// bitchat
//
// Manages private chat sessions and messages
// This is free and unencumbered software released into the public domain.
//

import BitLogger
import BitFoundation
import Foundation
import SwiftUI

/// Manages private chat session policy (selection, read receipts,
/// consolidation). Message storage lives in the single-writer
/// `ConversationStore` (docs/CONVERSATION-STORE-DESIGN.md); the
/// `privateChats` / `unreadMessages` properties below are read-only compat
/// views derived from it (migration step 2 — the manager shrinks to
/// read-receipt policy in step 5).
final class PrivateChatManager: ObservableObject {
    @Published var selectedPeer: PeerID? = nil

    private var selectedPeerFingerprint: String? = nil
    var sentReadReceipts: Set<String> = []  // Made accessible for ChatViewModel

    weak var meshService: Transport?
    // Route acks/receipts via MessageRouter (chooses mesh or Nostr)
    weak var messageRouter: MessageRouter?
    // Peer service for looking up peer info during consolidation
    weak var unifiedPeerService: UnifiedPeerService?
    /// Single source of truth for message state; injected by the
    /// bootstrapper (`wireServiceGraph`).
    var conversationStore: ConversationStore?

    init(meshService: Transport? = nil, conversationStore: ConversationStore? = nil) {
        self.meshService = meshService
        self.conversationStore = conversationStore
    }

    // MARK: - Derived message state (read-only compat views)

    /// All private chats keyed by routing peer ID, derived from the store.
    /// Mutations go through the store's intent API only.
    @MainActor
    var privateChats: [PeerID: [BitchatMessage]] {
        conversationStore?.directMessagesByRoutingPeerID() ?? [:]
    }

    /// Unread chats, derived from the store's unread state.
    @MainActor
    var unreadMessages: Set<PeerID> {
        conversationStore?.unreadDirectRoutingPeerIDs() ?? []
    }

    @MainActor
    private func messages(for peerID: PeerID) -> [BitchatMessage] {
        conversationStore?.conversationsByID[.directPeer(peerID)]?.messages ?? []
    }

    // MARK: - Message Consolidation

    /// Consolidates messages from different peer ID representations into a single chat.
    /// This ensures messages from stable Noise keys and temporary Nostr peer IDs are merged.
    /// - Parameters:
    ///   - peerID: The target peer ID to consolidate messages into
    ///   - peerNickname: The peer's display name (lowercased for matching)
    ///   - persistedReadReceipts: The persisted read receipts set from ChatViewModel (UserDefaults-backed)
    /// - Returns: True if any unread messages were found during consolidation
    @MainActor
    func consolidateMessages(for peerID: PeerID, peerNickname: String, persistedReadReceipts: Set<String>) -> Bool {
        guard let meshService = meshService, let store = conversationStore else { return false }
        var hasUnreadMessages = false

        // 1. Consolidate from stable Noise key (64-char hex)
        if let peer = unifiedPeerService?.getPeer(by: peerID) {
            let noiseKeyHex = PeerID(hexData: peer.noisePublicKey)
            let nostrMessages = messages(for: noiseKeyHex)

            if noiseKeyHex != peerID, !nostrMessages.isEmpty {
                for message in nostrMessages {
                    // Update senderPeerID for correct read receipts
                    let updatedMessage = BitchatMessage(
                        id: message.id,
                        sender: message.sender,
                        content: message.content,
                        timestamp: message.timestamp,
                        isRelay: message.isRelay,
                        originalSender: message.originalSender,
                        isPrivate: message.isPrivate,
                        recipientNickname: message.recipientNickname,
                        senderPeerID: message.senderPeerID == meshService.myPeerID ? meshService.myPeerID : peerID,
                        mentions: message.mentions,
                        deliveryStatus: message.deliveryStatus
                    )
                    // Store append dedups by message ID (skips ones the
                    // target chat already has).
                    guard store.append(updatedMessage, to: .directPeer(peerID)) else { continue }

                    // Check for recent unread messages (< 60s, not sent by us, not already read)
                    // Use persistedReadReceipts to correctly identify already-read messages after app restart
                    if message.senderPeerID != meshService.myPeerID {
                        let messageAge = Date().timeIntervalSince(message.timestamp)
                        if messageAge < 60 && !persistedReadReceipts.contains(message.id) {
                            hasUnreadMessages = true
                        }
                    }
                }

                if hasUnreadMessages {
                    store.markUnread(.directPeer(peerID))
                } else {
                    store.markRead(.directPeer(noiseKeyHex))
                }

                store.removeConversation(.directPeer(noiseKeyHex))
            }
        }

        // 2. Consolidate from temporary Nostr peer IDs (nostr_* prefixed)
        let normalizedNickname = peerNickname.lowercased()
        var tempPeerIDsToConsolidate: [PeerID] = []

        for (storedPeerID, messages) in privateChats {
            if storedPeerID.isGeoDM && storedPeerID != peerID {
                let nicknamesMatch = messages.allSatisfy { $0.sender.lowercased() == normalizedNickname }
                if nicknamesMatch && !messages.isEmpty {
                    tempPeerIDsToConsolidate.append(storedPeerID)
                }
            }
        }

        if !tempPeerIDsToConsolidate.isEmpty {
            var consolidatedCount = 0
            var hadUnreadTemp = false
            let unreadPeerIDs = unreadMessages

            for tempPeerID in tempPeerIDsToConsolidate {
                if unreadPeerIDs.contains(tempPeerID) {
                    hadUnreadTemp = true
                }

                for message in messages(for: tempPeerID) {
                    let updatedMessage = BitchatMessage(
                        id: message.id,
                        sender: message.sender,
                        content: message.content,
                        timestamp: message.timestamp,
                        isRelay: message.isRelay,
                        originalSender: message.originalSender,
                        isPrivate: message.isPrivate,
                        recipientNickname: message.recipientNickname,
                        senderPeerID: peerID,
                        mentions: message.mentions,
                        deliveryStatus: message.deliveryStatus
                    )
                    if store.append(updatedMessage, to: .directPeer(peerID)) {
                        consolidatedCount += 1
                    }
                }
                store.removeConversation(.directPeer(tempPeerID))
            }

            if hadUnreadTemp {
                store.markUnread(.directPeer(peerID))
                hasUnreadMessages = true
                SecureLogger.debug("📬 Transferred unread status from temp peer IDs to \(peerID)", category: .session)
            }

            if consolidatedCount > 0 {
                SecureLogger.info("📥 Consolidated \(consolidatedCount) Nostr messages from temporary peer IDs to \(peerNickname)", category: .session)
            }
        }

        return hasUnreadMessages
    }

    /// Syncs the read receipt tracking between manager and view model for sent messages
    @MainActor
    func syncReadReceiptsForSentMessages(peerID: PeerID, nickname: String, externalReceipts: inout Set<String>) {
        for message in messages(for: peerID) {
            if message.sender == nickname {
                if let status = message.deliveryStatus {
                    switch status {
                    case .read, .delivered:
                        externalReceipts.insert(message.id)
                        sentReadReceipts.insert(message.id)
                    case .failed, .partiallyDelivered, .sending, .sent:
                        break
                    }
                }
            }
        }
    }

    /// Start a private chat with a peer
    @MainActor
    func startChat(with peerID: PeerID) {
        selectedPeer = peerID

        // Store fingerprint for persistence across reconnections
        if let fingerprint = meshService?.getFingerprint(for: peerID) {
            selectedPeerFingerprint = fingerprint
        }

        // Mark messages as read
        markAsRead(from: peerID)

        // Initialize chat if needed
        conversationStore?.conversation(for: .directPeer(peerID))
    }

    /// End the current private chat
    func endChat() {
        selectedPeer = nil
        selectedPeerFingerprint = nil
    }

    /// No-op since the `ConversationStore` cutover: the store maintains
    /// chronological order and dedups by message ID on every insert, so the
    /// per-append re-sort/dedup sweep this performed is no longer needed.
    /// Kept only for API compatibility until step 5 removes the callers.
    func sanitizeChat(for peerID: PeerID) {}

    /// Mark messages from a peer as read
    @MainActor
    func markAsRead(from peerID: PeerID) {
        conversationStore?.markRead(.directPeer(peerID))

        // Send read receipts for unread messages that haven't been sent yet
        for message in messages(for: peerID) {
            if message.senderPeerID == peerID && !message.isRelay && !sentReadReceipts.contains(message.id) {
                sendReadReceipt(for: message)
            }
        }
    }

    // MARK: - Private Methods

    private func sendReadReceipt(for message: BitchatMessage) {
        guard !sentReadReceipts.contains(message.id),
              let senderPeerID = message.senderPeerID else {
            return
        }

        sentReadReceipts.insert(message.id)

        // Create read receipt using the simplified method
        let receipt = ReadReceipt(
            originalMessageID: message.id,
            readerID: meshService?.myPeerID ?? PeerID(str: ""),
            readerNickname: meshService?.myNickname ?? ""
        )

        // Route via MessageRouter to avoid handshakeRequired spam when session isn't established
        if let router = messageRouter {
            SecureLogger.debug("PrivateChatManager: sending READ ack for \(message.id.prefix(8))… to \(senderPeerID.id.prefix(8))… via router", category: .session)
            Task { @MainActor in
                router.sendReadReceipt(receipt, to: senderPeerID)
            }
        } else {
            // Fallback: preserve previous behavior
            meshService?.sendReadReceipt(receipt, to: senderPeerID)
        }
    }
}
