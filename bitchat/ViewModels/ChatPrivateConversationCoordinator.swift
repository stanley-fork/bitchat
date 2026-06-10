import BitFoundation
import BitLogger
import Foundation

/// The narrow surface `ChatPrivateConversationCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of holding an `unowned` back-ref
/// to the whole `ChatViewModel`. This keeps the coordinator independently
/// testable (see `ChatPrivateConversationCoordinatorContextTests`) and makes
/// its true dependencies explicit. The surface is intentionally large — it
/// documents the coordinator's real coupling to private-chat state, peer
/// identity, and the routing/ack transports.
@MainActor
protocol ChatPrivateConversationContext: AnyObject {
    // MARK: Conversation state
    var privateChats: [PeerID: [BitchatMessage]] { get set }
    var sentReadReceipts: Set<String> { get set }
    var sentGeoDeliveryAcks: Set<String> { get set }
    var unreadPrivateMessages: Set<PeerID> { get set }
    var selectedPrivateChatPeer: PeerID? { get set }
    var nickname: String { get }
    var activeChannel: ChannelID { get }
    var nostrKeyMapping: [PeerID: String] { get }
    /// Signals that message state changed so observers refresh (e.g. `objectWillChange.send()`).
    func notifyUIChanged()

    // MARK: Peers & identity
    var myPeerID: PeerID { get }
    func peerNickname(for peerID: PeerID) -> String?
    func isPeerConnected(_ peerID: PeerID) -> Bool
    func isPeerReachable(_ peerID: PeerID) -> Bool
    func isPeerBlocked(_ peerID: PeerID) -> Bool
    func noisePublicKey(for peerID: PeerID) -> Data?
    /// Resolves the ephemeral (short) peer ID for a known Noise public key, if connected.
    func ephemeralPeerID(forNoiseKey noiseKey: Data) -> PeerID?
    func getPeerIDForNickname(_ nickname: String) -> PeerID?
    func getFingerprint(for peerID: PeerID) -> String?
    func storedFingerprint(for peerID: PeerID) -> String?
    func clearStoredFingerprint(for peerID: PeerID)

    // MARK: Nostr identity
    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool
    func displayNameForNostrPubkey(_ pubkeyHex: String) -> String
    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity
    func currentNostrIdentity() -> NostrIdentity?

    // MARK: Routing & acknowledgements
    func routePrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String)
    func routeReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID)
    func routeFavoriteNotification(to peerID: PeerID, isFavorite: Bool)
    func sendMeshReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID)
    func sendGeohashPrivateMessage(_ content: String, toRecipientHex recipientHex: String, from identity: NostrIdentity, messageID: String)
    func sendGeohashDeliveryAck(for messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity)
    func sendGeohashReadReceipt(_ messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity)
    func sendDeliveryAckViaNostrEmbedded(_ message: BitchatMessage, wasReadBefore: Bool, senderPubkey: String, key: Data?)

    // MARK: System messages & chat hygiene
    func addSystemMessage(_ content: String)
    func addMeshOnlySystemMessage(_ content: String)
    func sanitizeChat(for peerID: PeerID)
}

extension ChatViewModel: ChatPrivateConversationContext {
    // `privateChats`, `sentReadReceipts`, and `notifyUIChanged()` are shared
    // requirements with `ChatDeliveryContext`; the remaining state members are
    // satisfied by existing `ChatViewModel` properties and methods.

    var myPeerID: PeerID { meshService.myPeerID }

    func peerNickname(for peerID: PeerID) -> String? {
        meshService.peerNickname(peerID: peerID)
    }

    func isPeerConnected(_ peerID: PeerID) -> Bool {
        meshService.isPeerConnected(peerID)
    }

    func isPeerReachable(_ peerID: PeerID) -> Bool {
        meshService.isPeerReachable(peerID)
    }

    func noisePublicKey(for peerID: PeerID) -> Data? {
        unifiedPeerService.getPeer(by: peerID)?.noisePublicKey
    }

    func ephemeralPeerID(forNoiseKey noiseKey: Data) -> PeerID? {
        unifiedPeerService.peers.first(where: { $0.noisePublicKey == noiseKey })?.peerID
    }

    func storedFingerprint(for peerID: PeerID) -> String? {
        peerIDToPublicKeyFingerprint[peerID]
    }

    func clearStoredFingerprint(for peerID: PeerID) {
        peerIdentityStore.setFingerprint(nil, for: peerID)
    }

    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool {
        identityManager.isNostrBlocked(pubkeyHexLowercased: pubkeyHexLowercased)
    }

    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity {
        try idBridge.deriveIdentity(forGeohash: geohash)
    }

    func currentNostrIdentity() -> NostrIdentity? {
        try? idBridge.getCurrentNostrIdentity()
    }

    func routePrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        messageRouter.sendPrivate(content, to: peerID, recipientNickname: recipientNickname, messageID: messageID)
    }

    func routeReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        messageRouter.sendReadReceipt(receipt, to: peerID)
    }

    func routeFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        messageRouter.sendFavoriteNotification(to: peerID, isFavorite: isFavorite)
    }

    func sendMeshReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {
        meshService.sendReadReceipt(receipt, to: peerID)
    }

    func sendGeohashPrivateMessage(_ content: String, toRecipientHex recipientHex: String, from identity: NostrIdentity, messageID: String) {
        makeGeohashNostrTransport().sendPrivateMessageGeohash(
            content: content,
            toRecipientHex: recipientHex,
            from: identity,
            messageID: messageID
        )
    }

    func sendGeohashDeliveryAck(for messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        makeGeohashNostrTransport().sendDeliveryAckGeohash(for: messageID, toRecipientHex: recipientHex, from: identity)
    }

    func sendGeohashReadReceipt(_ messageID: String, toRecipientHex recipientHex: String, from identity: NostrIdentity) {
        makeGeohashNostrTransport().sendReadReceiptGeohash(messageID, toRecipientHex: recipientHex, from: identity)
    }

    func addSystemMessage(_ content: String) {
        addSystemMessage(content, timestamp: Date())
    }

    func sanitizeChat(for peerID: PeerID) {
        privateChatManager.sanitizeChat(for: peerID)
    }

    private func makeGeohashNostrTransport() -> NostrTransport {
        let transport = NostrTransport(keychain: keychain, idBridge: idBridge)
        transport.senderPeerID = meshService.myPeerID
        return transport
    }
}

@MainActor
final class ChatPrivateConversationCoordinator {
    private unowned let context: any ChatPrivateConversationContext

    init(context: any ChatPrivateConversationContext) {
        self.context = context
    }

    func sendPrivateMessage(_ content: String, to peerID: PeerID) {
        guard !content.isEmpty else { return }

        if context.isPeerBlocked(peerID) {
            let nickname = context.peerNickname(for: peerID) ?? "user"
            context.addSystemMessage(
                String(
                    format: String(localized: "system.dm.blocked_recipient", comment: "System message when attempting to message a blocked user"),
                    locale: .current,
                    nickname
                )
            )
            return
        }

        if peerID.isGeoDM {
            sendGeohashDM(content, to: peerID)
            return
        }

        guard let noiseKey = Data(hexString: peerID.id) else { return }
        let isConnected = context.isPeerConnected(peerID)
        let isReachable = context.isPeerReachable(peerID)
        let favoriteStatus = FavoritesPersistenceService.shared.getFavoriteStatus(for: noiseKey)
        let isMutualFavorite = favoriteStatus?.isMutual ?? false
        let hasNostrKey = favoriteStatus?.peerNostrPublicKey != nil

        var recipientNickname = context.peerNickname(for: peerID)
        if recipientNickname == nil && favoriteStatus != nil {
            recipientNickname = favoriteStatus?.peerNickname
        }
        recipientNickname = recipientNickname ?? "user"

        let messageID = UUID().uuidString
        let message = BitchatMessage(
            id: messageID,
            sender: context.nickname,
            content: content,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: recipientNickname,
            senderPeerID: context.myPeerID,
            mentions: nil,
            deliveryStatus: .sending
        )

        if context.privateChats[peerID] == nil {
            context.privateChats[peerID] = []
        }
        context.privateChats[peerID]?.append(message)
        context.notifyUIChanged()

        if isConnected || isReachable || (isMutualFavorite && hasNostrKey) {
            context.routePrivateMessage(
                content,
                to: peerID,
                recipientNickname: recipientNickname ?? "user",
                messageID: messageID
            )
            if let idx = context.privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                context.privateChats[peerID]?[idx].deliveryStatus = .sent
            }
        } else {
            if let index = context.privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                context.privateChats[peerID]?[index].deliveryStatus = .failed(
                    reason: String(localized: "content.delivery.reason.unreachable", comment: "Failure reason when a peer is unreachable")
                )
            }
            let name = recipientNickname ?? "user"
            context.addSystemMessage(
                String(
                    format: String(localized: "system.dm.unreachable", comment: "System message when a recipient is unreachable"),
                    locale: .current,
                    name
                )
            )
        }
    }

    func sendGeohashDM(_ content: String, to peerID: PeerID) {
        guard case .location(let channel) = context.activeChannel else {
            context.addSystemMessage(
                String(localized: "system.location.not_in_channel", comment: "System message when attempting to send without being in a location channel")
            )
            return
        }

        let messageID = UUID().uuidString
        let message = BitchatMessage(
            id: messageID,
            sender: context.nickname,
            content: content,
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: context.nickname,
            senderPeerID: context.myPeerID,
            deliveryStatus: .sending
        )

        if context.privateChats[peerID] == nil {
            context.privateChats[peerID] = []
        }

        context.privateChats[peerID]?.append(message)
        context.notifyUIChanged()

        guard let recipientHex = context.nostrKeyMapping[peerID] else {
            if let msgIdx = context.privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                context.privateChats[peerID]?[msgIdx].deliveryStatus = .failed(
                    reason: String(localized: "content.delivery.reason.unknown_recipient", comment: "Failure reason when the recipient is unknown")
                )
            }
            return
        }

        if context.isNostrBlocked(pubkeyHexLowercased: recipientHex) {
            if let msgIdx = context.privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                context.privateChats[peerID]?[msgIdx].deliveryStatus = .failed(
                    reason: String(localized: "content.delivery.reason.blocked", comment: "Failure reason when the user is blocked")
                )
            }
            context.addSystemMessage(
                String(localized: "system.dm.blocked_generic", comment: "System message when sending fails because user is blocked")
            )
            return
        }

        do {
            let identity = try context.deriveNostrIdentity(forGeohash: channel.geohash)
            if recipientHex.lowercased() == identity.publicKeyHex.lowercased() {
                if let idx = context.privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                    context.privateChats[peerID]?[idx].deliveryStatus = .failed(
                        reason: String(localized: "content.delivery.reason.self", comment: "Failure reason when attempting to message yourself")
                    )
                }
                return
            }

            SecureLogger.debug(
                "GeoDM: local send mid=\(messageID.prefix(8))… to=\(recipientHex.prefix(8))… conv=\(peerID)",
                category: .session
            )
            context.sendGeohashPrivateMessage(
                content,
                toRecipientHex: recipientHex,
                from: identity,
                messageID: messageID
            )
            if let msgIdx = context.privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                context.privateChats[peerID]?[msgIdx].deliveryStatus = .sent
            }
        } catch {
            if let idx = context.privateChats[peerID]?.firstIndex(where: { $0.id == messageID }) {
                context.privateChats[peerID]?[idx].deliveryStatus = .failed(
                    reason: String(localized: "content.delivery.reason.send_error", comment: "Failure reason for a generic send error")
                )
            }
        }
    }

    func handlePrivateMessage(
        _ payload: NoisePayload,
        senderPubkey: String,
        convKey: PeerID,
        id: NostrIdentity,
        messageTimestamp: Date
    ) {
        guard let pm = PrivateMessagePacket.decode(from: payload.data) else { return }
        let messageId = pm.messageID

        SecureLogger.info("GeoDM: recv PM <- sender=\(senderPubkey.prefix(8))… mid=\(messageId.prefix(8))…", category: .session)

        sendDeliveryAckIfNeeded(to: messageId, senderPubKey: senderPubkey, from: id)

        if context.isNostrBlocked(pubkeyHexLowercased: senderPubkey) {
            return
        }

        if context.privateChats[convKey]?.contains(where: { $0.id == messageId }) == true { return }
        for (_, arr) in context.privateChats where arr.contains(where: { $0.id == messageId }) {
            return
        }

        let senderName = context.displayNameForNostrPubkey(senderPubkey)
        let message = BitchatMessage(
            id: messageId,
            sender: senderName,
            content: pm.content,
            timestamp: messageTimestamp,
            isRelay: false,
            isPrivate: true,
            recipientNickname: context.nickname,
            senderPeerID: convKey,
            deliveryStatus: .delivered(to: context.nickname, at: Date())
        )

        if context.privateChats[convKey] == nil {
            context.privateChats[convKey] = []
        }
        context.privateChats[convKey]?.append(message)

        let isViewing = context.selectedPrivateChatPeer == convKey
        let wasReadBefore = context.sentReadReceipts.contains(messageId)
        let isRecentMessage = Date().timeIntervalSince(messageTimestamp) < 30
        let shouldMarkUnread = !wasReadBefore && !isViewing && isRecentMessage
        if shouldMarkUnread {
            context.unreadPrivateMessages.insert(convKey)
        }

        if isViewing {
            sendReadReceiptIfNeeded(to: messageId, senderPubKey: senderPubkey, from: id)
        }

        if !isViewing && shouldMarkUnread {
            NotificationService.shared.sendPrivateMessageNotification(
                from: senderName,
                message: pm.content,
                peerID: convKey
            )
        }

        context.notifyUIChanged()
    }

    func handleDelivered(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {
        guard let messageID = String(data: payload.data, encoding: .utf8) else { return }

        if let idx = context.privateChats[convKey]?.firstIndex(where: { $0.id == messageID }) {
            context.privateChats[convKey]?[idx].deliveryStatus = .delivered(
                to: context.displayNameForNostrPubkey(senderPubkey),
                at: Date()
            )
            context.notifyUIChanged()
            SecureLogger.info(
                "GeoDM: recv DELIVERED for mid=\(messageID.prefix(8))… from=\(senderPubkey.prefix(8))…",
                category: .session
            )
        } else {
            SecureLogger.warning("GeoDM: delivered ack for unknown mid=\(messageID.prefix(8))… conv=\(convKey)", category: .session)
        }
    }

    func handleReadReceipt(_ payload: NoisePayload, senderPubkey: String, convKey: PeerID) {
        guard let messageID = String(data: payload.data, encoding: .utf8) else { return }

        if let idx = context.privateChats[convKey]?.firstIndex(where: { $0.id == messageID }) {
            context.privateChats[convKey]?[idx].deliveryStatus = .read(
                by: context.displayNameForNostrPubkey(senderPubkey),
                at: Date()
            )
            context.notifyUIChanged()
            SecureLogger.info("GeoDM: recv READ for mid=\(messageID.prefix(8))… from=\(senderPubkey.prefix(8))…", category: .session)
        } else {
            SecureLogger.warning("GeoDM: read ack for unknown mid=\(messageID.prefix(8))… conv=\(convKey)", category: .session)
        }
    }

    func sendDeliveryAckIfNeeded(to messageId: String, senderPubKey: String, from id: NostrIdentity) {
        guard !context.sentGeoDeliveryAcks.contains(messageId) else { return }
        context.sendGeohashDeliveryAck(for: messageId, toRecipientHex: senderPubKey, from: id)
        context.sentGeoDeliveryAcks.insert(messageId)
    }

    func sendReadReceiptIfNeeded(to messageId: String, senderPubKey: String, from id: NostrIdentity) {
        guard !context.sentReadReceipts.contains(messageId) else { return }
        context.sendGeohashReadReceipt(messageId, toRecipientHex: senderPubKey, from: id)
        context.sentReadReceipts.insert(messageId)
    }

    func handlePrivateMessage(
        _ payload: NoisePayload,
        actualSenderNoiseKey: Data?,
        senderNickname: String,
        targetPeerID: PeerID,
        messageTimestamp: Date,
        senderPubkey: String
    ) {
        guard let pm = PrivateMessagePacket.decode(from: payload.data) else { return }
        let messageId = pm.messageID
        let messageContent = pm.content

        if messageContent.hasPrefix("[FAVORITED]") || messageContent.hasPrefix("[UNFAVORITED]") {
            if let key = actualSenderNoiseKey {
                handleFavoriteNotificationFromMesh(
                    messageContent,
                    from: PeerID(hexData: key),
                    senderNickname: senderNickname
                )
            }
            return
        }

        if isDuplicateMessage(messageId, targetPeerID: targetPeerID) {
            return
        }

        let wasReadBefore = context.sentReadReceipts.contains(messageId)

        var isViewingThisChat = false
        if context.selectedPrivateChatPeer == targetPeerID {
            isViewingThisChat = true
        } else if let selectedPeer = context.selectedPrivateChatPeer,
                  let selectedPeerNoiseKey = context.noisePublicKey(for: selectedPeer),
                  let key = actualSenderNoiseKey,
                  selectedPeerNoiseKey == key {
            isViewingThisChat = true
        }

        let isRecentMessage = Date().timeIntervalSince(messageTimestamp) < 30
        let shouldMarkAsUnread = !wasReadBefore && !isViewingThisChat && isRecentMessage

        let message = BitchatMessage(
            id: messageId,
            sender: senderNickname,
            content: messageContent,
            timestamp: messageTimestamp,
            isRelay: false,
            isPrivate: true,
            recipientNickname: context.nickname,
            senderPeerID: targetPeerID,
            deliveryStatus: .delivered(to: context.nickname, at: Date())
        )

        addMessageToPrivateChatsIfNeeded(message, targetPeerID: targetPeerID)
        mirrorToEphemeralIfNeeded(message, targetPeerID: targetPeerID, key: actualSenderNoiseKey)

        context.sendDeliveryAckViaNostrEmbedded(
            message,
            wasReadBefore: wasReadBefore,
            senderPubkey: senderPubkey,
            key: actualSenderNoiseKey
        )

        if wasReadBefore {
            // No-op.
        } else if isViewingThisChat {
            handleViewingThisChat(
                message,
                targetPeerID: targetPeerID,
                key: actualSenderNoiseKey,
                senderPubkey: senderPubkey
            )
        } else {
            markAsUnreadIfNeeded(
                shouldMarkAsUnread: shouldMarkAsUnread,
                targetPeerID: targetPeerID,
                key: actualSenderNoiseKey,
                isRecentMessage: isRecentMessage,
                senderNickname: senderNickname,
                messageContent: messageContent
            )
        }

        context.notifyUIChanged()
    }

    func handlePrivateMessage(_ message: BitchatMessage) {
        SecureLogger.debug("📥 handlePrivateMessage called for message from \(message.sender)", category: .session)
        let senderPeerID = message.senderPeerID ?? context.getPeerIDForNickname(message.sender)

        guard let peerID = senderPeerID else {
            SecureLogger.warning("⚠️ Could not get peer ID for sender \(message.sender)", category: .session)
            return
        }

        if message.content.hasPrefix("[FAVORITED]") || message.content.hasPrefix("[UNFAVORITED]") {
            handleFavoriteNotificationFromMesh(message.content, from: peerID, senderNickname: message.sender)
            return
        }

        migratePrivateChatsIfNeeded(for: peerID, senderNickname: message.sender)

        if peerID.id.count == 16, let peerNoiseKey = context.noisePublicKey(for: peerID) {
            let stableKeyHex = PeerID(hexData: peerNoiseKey)
            if stableKeyHex != peerID,
               let nostrMessages = context.privateChats[stableKeyHex],
               !nostrMessages.isEmpty {
                if context.privateChats[peerID] == nil {
                    context.privateChats[peerID] = []
                }

                let existingMessageIds = Set(context.privateChats[peerID]?.map { $0.id } ?? [])
                for nostrMessage in nostrMessages where !existingMessageIds.contains(nostrMessage.id) {
                    context.privateChats[peerID]?.append(nostrMessage)
                }

                context.privateChats[peerID]?.sort { $0.timestamp < $1.timestamp }
                context.privateChats.removeValue(forKey: stableKeyHex)

                SecureLogger.info(
                    "📥 Consolidated \(nostrMessages.count) Nostr messages from stable key to ephemeral peer \(peerID)",
                    category: .session
                )
            }
        }

        if isDuplicateMessage(message.id, targetPeerID: peerID) {
            return
        }

        addMessageToPrivateChatsIfNeeded(message, targetPeerID: peerID)
        let noiseKey = peerID.noiseKey ?? context.noisePublicKey(for: peerID)
        mirrorToEphemeralIfNeeded(message, targetPeerID: peerID, key: noiseKey)

        let isViewing = context.selectedPrivateChatPeer == peerID
        if isViewing {
            let receipt = ReadReceipt(
                originalMessageID: message.id,
                readerID: context.myPeerID,
                readerNickname: context.nickname
            )
            context.sendMeshReadReceipt(receipt, to: peerID)
            context.sentReadReceipts.insert(message.id)
        } else {
            context.unreadPrivateMessages.insert(peerID)
            NotificationService.shared.sendPrivateMessageNotification(
                from: message.sender,
                message: message.content,
                peerID: peerID
            )
        }

        context.notifyUIChanged()
    }

    func isDuplicateMessage(_ messageId: String, targetPeerID: PeerID) -> Bool {
        if context.privateChats[targetPeerID]?.contains(where: { $0.id == messageId }) == true {
            return true
        }
        for (_, messages) in context.privateChats where messages.contains(where: { $0.id == messageId }) {
            return true
        }
        return false
    }

    func addMessageToPrivateChatsIfNeeded(_ message: BitchatMessage, targetPeerID: PeerID) {
        if context.privateChats[targetPeerID] == nil {
            context.privateChats[targetPeerID] = []
        }
        if let idx = context.privateChats[targetPeerID]?.firstIndex(where: { $0.id == message.id }) {
            context.privateChats[targetPeerID]?[idx] = message
        } else {
            context.privateChats[targetPeerID]?.append(message)
        }
        context.sanitizeChat(for: targetPeerID)
    }

    func mirrorToEphemeralIfNeeded(_ message: BitchatMessage, targetPeerID: PeerID, key: Data?) {
        guard let key,
              let ephemeralPeerID = context.ephemeralPeerID(forNoiseKey: key),
              ephemeralPeerID != targetPeerID
        else {
            return
        }

        if context.privateChats[ephemeralPeerID] == nil {
            context.privateChats[ephemeralPeerID] = []
        }
        if let idx = context.privateChats[ephemeralPeerID]?.firstIndex(where: { $0.id == message.id }) {
            context.privateChats[ephemeralPeerID]?[idx] = message
        } else {
            context.privateChats[ephemeralPeerID]?.append(message)
        }
        context.sanitizeChat(for: ephemeralPeerID)
    }

    func handleViewingThisChat(
        _ message: BitchatMessage,
        targetPeerID: PeerID,
        key: Data?,
        senderPubkey: String
    ) {
        context.unreadPrivateMessages.remove(targetPeerID)
        if let key,
           let ephemeralPeerID = context.ephemeralPeerID(forNoiseKey: key) {
            context.unreadPrivateMessages.remove(ephemeralPeerID)
        }
        guard !context.sentReadReceipts.contains(message.id) else { return }

        if let key {
            let receipt = ReadReceipt(
                originalMessageID: message.id,
                readerID: context.myPeerID,
                readerNickname: context.nickname
            )
            SecureLogger.debug("Viewing chat; sending READ ack for \(message.id.prefix(8))… via router", category: .session)
            context.routeReadReceipt(receipt, to: PeerID(hexData: key))
            context.sentReadReceipts.insert(message.id)
        } else if let identity = context.currentNostrIdentity() {
            context.sendGeohashReadReceipt(message.id, toRecipientHex: senderPubkey, from: identity)
            context.sentReadReceipts.insert(message.id)
            SecureLogger.debug(
                "Viewing chat; sent READ ack directly to Nostr pub=\(senderPubkey.prefix(8))… for mid=\(message.id.prefix(8))…",
                category: .session
            )
        }
    }

    func markAsUnreadIfNeeded(
        shouldMarkAsUnread: Bool,
        targetPeerID: PeerID,
        key: Data?,
        isRecentMessage: Bool,
        senderNickname: String,
        messageContent: String
    ) {
        guard shouldMarkAsUnread else { return }

        context.unreadPrivateMessages.insert(targetPeerID)
        if let key,
           let ephemeralPeerID = context.ephemeralPeerID(forNoiseKey: key),
           ephemeralPeerID != targetPeerID {
            context.unreadPrivateMessages.insert(ephemeralPeerID)
        }
        if isRecentMessage {
            NotificationService.shared.sendPrivateMessageNotification(
                from: senderNickname,
                message: messageContent,
                peerID: targetPeerID
            )
        }
    }

    func handleFavoriteNotificationFromMesh(_ content: String, from peerID: PeerID, senderNickname: String) {
        let isFavorite = content.hasPrefix("[FAVORITED]")
        let parts = content.split(separator: ":")

        var nostrPubkey: String?
        if parts.count > 1 {
            nostrPubkey = String(parts[1])
            SecureLogger.info("📝 Received Nostr npub in favorite notification: \(nostrPubkey ?? "none")", category: .session)
        }

        let noiseKey = peerID.noiseKey ?? context.noisePublicKey(for: peerID)
        guard let finalNoiseKey = noiseKey else {
            SecureLogger.warning("⚠️ Cannot get Noise key for peer \(peerID)", category: .session)
            return
        }

        let prior = FavoritesPersistenceService.shared.getFavoriteStatus(for: finalNoiseKey)?.theyFavoritedUs ?? false
        FavoritesPersistenceService.shared.updatePeerFavoritedUs(
            peerNoisePublicKey: finalNoiseKey,
            favorited: isFavorite,
            peerNickname: senderNickname,
            peerNostrPublicKey: nostrPubkey
        )

        if isFavorite && nostrPubkey != nil {
            SecureLogger.info(
                "💾 Storing Nostr key association for \(senderNickname): \(nostrPubkey!.prefix(16))...",
                category: .session
            )
        }

        if prior != isFavorite {
            let action = isFavorite ? "favorited" : "unfavorited"
            context.addMeshOnlySystemMessage("\(senderNickname) \(action) you")
        }
    }

    func processActionMessage(_ message: BitchatMessage) -> BitchatMessage {
        let isActionMessage = message.content.hasPrefix("* ")
            && message.content.hasSuffix(" *")
            && (message.content.contains("🫂")
                || message.content.contains("🐟")
                || message.content.contains("took a screenshot"))

        guard isActionMessage else { return message }

        return BitchatMessage(
            id: message.id,
            sender: "system",
            content: String(message.content.dropFirst(2).dropLast(2)),
            timestamp: message.timestamp,
            isRelay: message.isRelay,
            originalSender: message.originalSender,
            isPrivate: message.isPrivate,
            recipientNickname: message.recipientNickname,
            senderPeerID: message.senderPeerID,
            mentions: message.mentions,
            deliveryStatus: message.deliveryStatus
        )
    }

    func migratePrivateChatsIfNeeded(for peerID: PeerID, senderNickname: String) {
        let currentFingerprint = context.getFingerprint(for: peerID)

        if context.privateChats[peerID] == nil || context.privateChats[peerID]?.isEmpty == true {
            var migratedMessages: [BitchatMessage] = []
            var oldPeerIDsToRemove: [PeerID] = []
            let cutoffTime = Date().addingTimeInterval(-TransportConfig.uiMigrationCutoffSeconds)

            for (oldPeerID, messages) in context.privateChats where oldPeerID != peerID {
                let oldFingerprint = context.storedFingerprint(for: oldPeerID)
                let recentMessages = messages.filter { $0.timestamp > cutoffTime }
                guard !recentMessages.isEmpty else { continue }

                if let currentFp = currentFingerprint,
                   let oldFp = oldFingerprint,
                   currentFp == oldFp {
                    migratedMessages.append(contentsOf: recentMessages)
                    if recentMessages.count == messages.count {
                        oldPeerIDsToRemove.append(oldPeerID)
                    } else {
                        SecureLogger.info(
                            "📦 Partially migrating \(recentMessages.count) of \(messages.count) messages from \(oldPeerID)",
                            category: .session
                        )
                    }

                    SecureLogger.info(
                        "📦 Migrating \(recentMessages.count) recent messages from old peer ID \(oldPeerID) to \(peerID) (fingerprint match)",
                        category: .session
                    )
                } else if currentFingerprint == nil || oldFingerprint == nil {
                    let isRelevantChat = recentMessages.contains { msg in
                        (msg.sender == senderNickname && msg.sender != context.nickname)
                            || (msg.sender == context.nickname && msg.recipientNickname == senderNickname)
                    }

                    if isRelevantChat {
                        migratedMessages.append(contentsOf: recentMessages)
                        if recentMessages.count == messages.count {
                            oldPeerIDsToRemove.append(oldPeerID)
                        }

                        SecureLogger.warning(
                            "📦 Migrating \(recentMessages.count) recent messages from old peer ID \(oldPeerID) to \(peerID) (nickname match)",
                            category: .session
                        )
                    }
                }
            }

            if !oldPeerIDsToRemove.isEmpty {
                let needsSelectedUpdate = oldPeerIDsToRemove.contains { context.selectedPrivateChatPeer == $0 }

                for oldID in oldPeerIDsToRemove {
                    context.privateChats.removeValue(forKey: oldID)
                    context.unreadPrivateMessages.remove(oldID)
                    context.clearStoredFingerprint(for: oldID)
                }

                if needsSelectedUpdate {
                    context.selectedPrivateChatPeer = peerID
                }
            }

            if !migratedMessages.isEmpty {
                if context.privateChats[peerID] == nil {
                    context.privateChats[peerID] = []
                }
                context.privateChats[peerID]?.append(contentsOf: migratedMessages)
                context.privateChats[peerID]?.sort { $0.timestamp < $1.timestamp }
                context.sanitizeChat(for: peerID)
                context.notifyUIChanged()
            }
        }
    }

    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {
        var noiseKey: Data?

        if let hexKey = Data(hexString: peerID.id) {
            noiseKey = hexKey
        } else if let peerNoiseKey = context.noisePublicKey(for: peerID) {
            noiseKey = peerNoiseKey
        }

        if context.isPeerConnected(peerID) {
            context.routeFavoriteNotification(to: peerID, isFavorite: isFavorite)
            SecureLogger.debug("📤 Sent favorite notification via BLE to \(peerID)", category: .session)
        } else if let key = noiseKey {
            context.routeFavoriteNotification(to: PeerID(hexData: key), isFavorite: isFavorite)
        } else {
            SecureLogger.warning("⚠️ Cannot send favorite notification - peer not connected and no Nostr pubkey", category: .session)
        }
    }

    func isMessageBlocked(_ message: BitchatMessage) -> Bool {
        if let peerID = message.senderPeerID ?? context.getPeerIDForNickname(message.sender) {
            if context.isPeerBlocked(peerID) { return true }
            if peerID.isGeoChat || peerID.isGeoDM,
               let full = context.nostrKeyMapping[peerID]?.lowercased(),
               context.isNostrBlocked(pubkeyHexLowercased: full) {
                return true
            }
        }
        return false
    }
}
