import BitFoundation
import BitLogger
import CoreBluetooth
import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The narrow surface `ChatPublicConversationCoordinator` needs from its owner.
///
/// Follows the `ChatDeliveryContext` exemplar: the coordinator depends on the
/// minimal context it actually uses instead of holding an `unowned` back-ref
/// to the whole `ChatViewModel`. This keeps the coordinator independently
/// testable (see `ChatPublicConversationCoordinatorContextTests`) and makes
/// its true dependencies explicit. The surface is intentionally large — it
/// documents the coordinator's real coupling to the public timeline, the
/// conversation stores, geohash participants, and the inbound public message
/// pipeline.
@MainActor
protocol ChatPublicConversationContext: AnyObject {
    // MARK: Channel & visible timeline state
    var messages: [BitchatMessage] { get set }
    var activeChannel: ChannelID { get }
    var currentGeohash: String? { get }
    var nickname: String { get }
    var myPeerID: PeerID { get }
    /// Publishes the public-timeline batching state (UI animation suppression).
    /// (Single mutation path for the owner's `isBatchingPublic`; this
    /// coordinator never reads it.)
    func setPublicBatching(_ isBatching: Bool)
    /// Signals that message state changed so observers refresh (e.g. `objectWillChange.send()`).
    func notifyUIChanged()
    func trimMessagesIfNeeded()

    // MARK: Public timeline store
    func timelineMessages(for channel: ChannelID) -> [BitchatMessage]
    func appendTimelineMessage(_ message: BitchatMessage, to channel: ChannelID)
    func appendGeohashMessageIfAbsent(_ message: BitchatMessage, toGeohash geohash: String) -> Bool
    func removeTimelineMessage(withID id: String) -> BitchatMessage?
    func removeGeohashTimelineMessages(in geohash: String, where predicate: (BitchatMessage) -> Bool)
    func clearTimeline(for channel: ChannelID)
    func timelineGeohashKeys() -> [String]
    /// Queues a system message for the next geohash channel visit.
    func queueGeohashSystemMessage(_ content: String)

    // MARK: Conversation stores
    func setConversationActiveChannel(_ channel: ChannelID)
    func replaceConversationMessages(_ messages: [BitchatMessage], for channelID: ChannelID)
    func replaceConversationMessages(_ messages: [BitchatMessage], for conversationID: ConversationID)
    func synchronizePrivateConversationStore()
    func synchronizeConversationSelectionStore()

    // MARK: Private chats (block cleanup & message removal)
    var privateChats: [PeerID: [BitchatMessage]] { get set }
    var unreadPrivateMessages: Set<PeerID> { get set }
    func cleanupLocalFile(forMessage message: BitchatMessage)

    // MARK: Geohash participants & presence
    var geoNicknames: [String: String] { get }
    var isTeleported: Bool { get }
    var nostrKeyMapping: [PeerID: String] { get }
    /// Drops every key mapping that resolves to the given (lowercased) Nostr pubkey.
    func removeNostrKeyMappings(matchingPubkeyHexLowercased hex: String)
    func visibleGeoPeople() -> [GeoPerson]
    func geoParticipantCount(for geohash: String) -> Int
    func removeGeoParticipant(pubkeyHex: String)

    // MARK: Nostr identity & blocking (shared with the other contexts)
    func deriveNostrIdentity(forGeohash geohash: String) throws -> NostrIdentity
    func isNostrBlocked(pubkeyHexLowercased: String) -> Bool
    func setNostrBlocked(_ pubkeyHexLowercased: String, isBlocked: Bool)

    // MARK: Mesh transport
    func meshPeerNicknames() -> [PeerID: String]
    func sendMeshMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date)

    // MARK: Inbound public message processing
    func processActionMessage(_ message: BitchatMessage) -> BitchatMessage
    func isMessageBlocked(_ message: BitchatMessage) -> Bool
    func allowPublicMessage(senderKey: String, contentKey: String) -> Bool
    func enqueuePublicMessage(_ message: BitchatMessage)
    func cachedStablePeerID(for shortPeerID: PeerID) -> PeerID?

    // MARK: Content dedup & formatting
    func normalizedContentKey(_ content: String) -> String
    func contentTimestamp(forKey key: String) -> Date?
    func recordContentKey(_ key: String, timestamp: Date)
    /// Pre-renders the message so the formatting cache is warm before display.
    func prewarmMessageFormatting(_ message: BitchatMessage)

    // MARK: Notifications
    /// Posts the you-were-mentioned local notification.
    func notifyMention(from sender: String, message: String)
}

extension ChatViewModel: ChatPublicConversationContext {
    // `messages`, `privateChats`, `unreadPrivateMessages`, `nostrKeyMapping`,
    // `nickname`, `activeChannel`, `currentGeohash`, `geoNicknames`,
    // `myPeerID`, `isTeleported`, `notifyUIChanged()`,
    // `geoParticipantCount(for:)`, `isNostrBlocked(pubkeyHexLowercased:)`,
    // `deriveNostrIdentity(forGeohash:)`, and
    // `appendGeohashMessageIfAbsent(_:toGeohash:)` are shared requirements
    // with `ChatDeliveryContext` / `ChatPrivateConversationContext` /
    // `ChatNostrContext`; their witnesses already exist. The members below
    // flatten nested service accesses into intent-named calls.

    func timelineMessages(for channel: ChannelID) -> [BitchatMessage] {
        timelineStore.messages(for: channel)
    }

    func appendTimelineMessage(_ message: BitchatMessage, to channel: ChannelID) {
        timelineStore.append(message, to: channel)
    }

    func removeTimelineMessage(withID id: String) -> BitchatMessage? {
        timelineStore.removeMessage(withID: id)
    }

    func removeGeohashTimelineMessages(in geohash: String, where predicate: (BitchatMessage) -> Bool) {
        timelineStore.removeMessages(in: geohash, where: predicate)
    }

    func clearTimeline(for channel: ChannelID) {
        timelineStore.clear(channel: channel)
    }

    func timelineGeohashKeys() -> [String] {
        timelineStore.geohashKeys()
    }

    func queueGeohashSystemMessage(_ content: String) {
        timelineStore.queueGeohashSystemMessage(content)
    }

    func setConversationActiveChannel(_ channel: ChannelID) {
        conversationStore.setActiveChannel(channel)
    }

    func replaceConversationMessages(_ messages: [BitchatMessage], for channelID: ChannelID) {
        conversationStore.replaceMessages(messages, for: channelID)
    }

    func replaceConversationMessages(_ messages: [BitchatMessage], for conversationID: ConversationID) {
        conversationStore.replaceMessages(messages, for: conversationID)
    }

    func visibleGeoPeople() -> [GeoPerson] {
        participantTracker.getVisiblePeople()
    }

    func removeGeoParticipant(pubkeyHex: String) {
        participantTracker.removeParticipant(pubkeyHex: pubkeyHex)
    }

    func setNostrBlocked(_ pubkeyHexLowercased: String, isBlocked: Bool) {
        identityManager.setNostrBlocked(pubkeyHexLowercased, isBlocked: isBlocked)
    }

    func meshPeerNicknames() -> [PeerID: String] {
        meshService.getPeerNicknames()
    }

    func sendMeshMessage(_ content: String, mentions: [String], messageID: String, timestamp: Date) {
        meshService.sendMessage(content, mentions: mentions, messageID: messageID, timestamp: timestamp)
    }

    func allowPublicMessage(senderKey: String, contentKey: String) -> Bool {
        publicRateLimiter.allow(senderKey: senderKey, contentKey: contentKey)
    }

    func enqueuePublicMessage(_ message: BitchatMessage) {
        publicMessagePipeline.enqueue(message)
    }

    func normalizedContentKey(_ content: String) -> String {
        deduplicationService.normalizedContentKey(content)
    }

    func contentTimestamp(forKey key: String) -> Date? {
        deduplicationService.contentTimestamp(forKey: key)
    }

    func recordContentKey(_ key: String, timestamp: Date) {
        deduplicationService.recordContentKey(key, timestamp: timestamp)
    }

    func prewarmMessageFormatting(_ message: BitchatMessage) {
        _ = formatMessageAsText(message, colorScheme: currentColorScheme)
    }

    func notifyMention(from sender: String, message: String) {
        NotificationService.shared.sendMentionNotification(from: sender, message: message)
    }
}

@MainActor
final class ChatPublicConversationCoordinator: PublicMessagePipelineDelegate {
    private unowned let context: any ChatPublicConversationContext

    init(context: any ChatPublicConversationContext) {
        self.context = context
    }

    func visibleGeohashPeople() -> [GeoPerson] {
        context.visibleGeoPeople()
    }

    func getVisibleGeoParticipants() -> [CommandGeoParticipant] {
        visibleGeohashPeople().map { CommandGeoParticipant(id: $0.id, displayName: $0.displayName) }
    }

    func geohashParticipantCount(for geohash: String) -> Int {
        context.geoParticipantCount(for: geohash)
    }

    func displayNameForPubkey(_ pubkeyHex: String) -> String {
        displayNameForNostrPubkey(pubkeyHex)
    }

    func isBlocked(_ pubkeyHexLowercased: String) -> Bool {
        context.isNostrBlocked(pubkeyHexLowercased: pubkeyHexLowercased)
    }

    func isGeohashUserBlocked(pubkeyHexLowercased: String) -> Bool {
        context.isNostrBlocked(pubkeyHexLowercased: pubkeyHexLowercased)
    }

    func blockGeohashUser(pubkeyHexLowercased: String, displayName: String) {
        let hex = pubkeyHexLowercased.lowercased()
        context.setNostrBlocked(hex, isBlocked: true)
        context.removeGeoParticipant(pubkeyHex: hex)

        if let gh = context.currentGeohash {
            let predicate: (BitchatMessage) -> Bool = { [unowned context] message in
                guard let senderPeerID = message.senderPeerID,
                      senderPeerID.isGeoDM || senderPeerID.isGeoChat else {
                    return false
                }
                if let full = context.nostrKeyMapping[senderPeerID]?.lowercased() {
                    return full == hex
                }
                return false
            }
            context.removeGeohashTimelineMessages(in: gh, where: predicate)
            synchronizePublicConversationStore(forGeohash: gh)
            if case .location = context.activeChannel {
                context.messages.removeAll(where: predicate)
            }
        }

        let conversationPeerID = PeerID(nostr_: hex)
        if context.privateChats[conversationPeerID] != nil {
            var privateChats = context.privateChats
            privateChats.removeValue(forKey: conversationPeerID)
            context.privateChats = privateChats

            var unread = context.unreadPrivateMessages
            unread.remove(conversationPeerID)
            context.unreadPrivateMessages = unread
        }

        context.removeNostrKeyMappings(matchingPubkeyHexLowercased: hex)

        addSystemMessage(
            String(
                format: String(
                    localized: "system.geohash.blocked",
                    comment: "System message shown when a user is blocked in geohash chats"
                ),
                locale: .current,
                displayName
            )
        )
    }

    func unblockGeohashUser(pubkeyHexLowercased: String, displayName: String) {
        context.setNostrBlocked(pubkeyHexLowercased, isBlocked: false)
        addSystemMessage(
            String(
                format: String(
                    localized: "system.geohash.unblocked",
                    comment: "System message shown when a user is unblocked in geohash chats"
                ),
                locale: .current,
                displayName
            )
        )
    }

    func displayNameForNostrPubkey(_ pubkeyHex: String) -> String {
        let suffix = String(pubkeyHex.suffix(4))
        if let geohash = context.currentGeohash,
           let myGeoIdentity = try? context.deriveNostrIdentity(forGeohash: geohash),
           myGeoIdentity.publicKeyHex.lowercased() == pubkeyHex.lowercased() {
            return context.nickname + "#" + suffix
        }
        if let nick = context.geoNicknames[pubkeyHex.lowercased()], !nick.isEmpty {
            return nick + "#" + suffix
        }
        return "anon#\(suffix)"
    }

    func currentPublicSender() -> (name: String, peerID: PeerID) {
        var displaySender = context.nickname
        var senderPeerID = context.myPeerID
        if case .location(let channel) = context.activeChannel,
           let identity = try? context.deriveNostrIdentity(forGeohash: channel.geohash) {
            let suffix = String(identity.publicKeyHex.suffix(4))
            displaySender = context.nickname + "#" + suffix
            senderPeerID = PeerID(nostr: identity.publicKeyHex)
        }
        return (displaySender, senderPeerID)
    }

    func removeMessage(withID messageID: String, cleanupFile: Bool = false) {
        var removedMessage: BitchatMessage?

        if let index = context.messages.firstIndex(where: { $0.id == messageID }) {
            removedMessage = context.messages.remove(at: index)
        }

        if let storeRemoved = context.removeTimelineMessage(withID: messageID) {
            removedMessage = removedMessage ?? storeRemoved
            synchronizeAllPublicConversationStores()
        }

        var chats = context.privateChats
        for (peerID, items) in chats {
            let filtered = items.filter { $0.id != messageID }
            if filtered.count != items.count {
                if filtered.isEmpty {
                    chats.removeValue(forKey: peerID)
                } else {
                    chats[peerID] = filtered
                }
                if removedMessage == nil {
                    removedMessage = items.first(where: { $0.id == messageID })
                }
            }
        }
        context.privateChats = chats

        if cleanupFile, let removedMessage {
            context.cleanupLocalFile(forMessage: removedMessage)
        }

        context.notifyUIChanged()
    }

    func initializeConversationStore() {
        context.setConversationActiveChannel(context.activeChannel)
        synchronizePublicConversationStore(for: context.activeChannel)
        context.synchronizePrivateConversationStore()
        context.synchronizeConversationSelectionStore()
    }

    func synchronizePublicConversationStore(for channel: ChannelID) {
        let publicMessages = context.timelineMessages(for: channel)
        context.replaceConversationMessages(publicMessages, for: channel)
        if channel == context.activeChannel {
            context.setConversationActiveChannel(context.activeChannel)
        }
    }

    func synchronizePublicConversationStore(forGeohash geohash: String) {
        let channel = ChannelID.location(GeohashChannel(level: .city, geohash: geohash))
        let publicMessages = context.timelineMessages(for: channel)
        context.replaceConversationMessages(publicMessages, for: .geohash(geohash.lowercased()))
    }

    func synchronizeAllPublicConversationStores() {
        synchronizePublicConversationStore(for: .mesh)
        for geohash in context.timelineGeohashKeys() {
            synchronizePublicConversationStore(forGeohash: geohash)
        }
    }

    func refreshVisibleMessages(from channel: ChannelID? = nil) {
        let target = channel ?? context.activeChannel
        context.messages = context.timelineMessages(for: target)
        context.replaceConversationMessages(context.messages, for: target)
        if target == context.activeChannel {
            context.setConversationActiveChannel(context.activeChannel)
        }
    }

    func clearCurrentPublicTimeline() {
        context.messages.removeAll()
        context.clearTimeline(for: context.activeChannel)

        Task.detached(priority: .utility) {
            do {
                let base = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let filesDir = base.appendingPathComponent("files", isDirectory: true)
                let outgoingDirs = [
                    filesDir.appendingPathComponent("voicenotes/outgoing", isDirectory: true),
                    filesDir.appendingPathComponent("images/outgoing", isDirectory: true),
                    filesDir.appendingPathComponent("files/outgoing", isDirectory: true)
                ]

                for dir in outgoingDirs {
                    if FileManager.default.fileExists(atPath: dir.path) {
                        try? FileManager.default.removeItem(at: dir)
                        try? FileManager.default.createDirectory(
                            at: dir,
                            withIntermediateDirectories: true,
                            attributes: nil
                        )
                    }
                }
            } catch {
                SecureLogger.error("Failed to clear media files: \(error)", category: .session)
            }
        }
    }

    func addSystemMessage(_ content: String, timestamp: Date = Date()) {
        let systemMessage = BitchatMessage(
            sender: "system",
            content: content,
            timestamp: timestamp,
            isRelay: false
        )
        context.messages.append(systemMessage)
    }

    func addMeshOnlySystemMessage(_ content: String) {
        let systemMessage = BitchatMessage(
            sender: "system",
            content: content,
            timestamp: Date(),
            isRelay: false
        )
        context.appendTimelineMessage(systemMessage, to: .mesh)
        synchronizePublicConversationStore(for: .mesh)
        refreshVisibleMessages()
        context.trimMessagesIfNeeded()
        context.notifyUIChanged()
    }

    func addPublicSystemMessage(_ content: String) {
        let systemMessage = BitchatMessage(
            sender: "system",
            content: content,
            timestamp: Date(),
            isRelay: false
        )
        context.appendTimelineMessage(systemMessage, to: context.activeChannel)
        refreshVisibleMessages(from: context.activeChannel)
        let contentKey = context.normalizedContentKey(systemMessage.content)
        context.recordContentKey(contentKey, timestamp: systemMessage.timestamp)
        context.trimMessagesIfNeeded()
        context.notifyUIChanged()
    }

    func addGeohashOnlySystemMessage(_ content: String) {
        if case .location = context.activeChannel {
            addPublicSystemMessage(content)
        } else {
            context.queueGeohashSystemMessage(content)
        }
    }

    func sendPublicRaw(_ content: String) {
        if case .location(let channel) = context.activeChannel {
            Task { @MainActor [weak context] in
                guard let context else { return }
                do {
                    let identity = try context.deriveNostrIdentity(forGeohash: channel.geohash)
                    let event = try NostrProtocol.createEphemeralGeohashEvent(
                        content: content,
                        geohash: channel.geohash,
                        senderIdentity: identity,
                        nickname: context.nickname,
                        teleported: context.isTeleported
                    )
                    let targetRelays = GeoRelayDirectory.shared.closestRelays(toGeohash: channel.geohash, count: 5)
                    if targetRelays.isEmpty {
                        NostrRelayManager.shared.sendEvent(event)
                    } else {
                        NostrRelayManager.shared.sendEvent(event, to: targetRelays)
                    }
                } catch {
                    SecureLogger.error("❌ Failed to send geohash raw message: \(error)", category: .session)
                }
            }
            return
        }

        context.sendMeshMessage(
            content,
            mentions: [],
            messageID: UUID().uuidString,
            timestamp: Date()
        )
    }

    func handlePublicMessage(_ message: BitchatMessage) {
        let finalMessage = context.processActionMessage(message)
        if context.isMessageBlocked(finalMessage) { return }

        let isGeo = finalMessage.senderPeerID?.isGeoChat == true
        let shouldRateLimit = finalMessage.sender != "system" || finalMessage.senderPeerID != nil
        if shouldRateLimit {
            let senderKey = normalizedSenderKey(for: finalMessage)
            let contentKey = context.normalizedContentKey(finalMessage.content)
            if !context.allowPublicMessage(senderKey: senderKey, contentKey: contentKey) {
                return
            }
        }

        if finalMessage.sender != "system" && finalMessage.content.count > 16000 { return }

        if !isGeo && finalMessage.sender != "system" {
            context.appendTimelineMessage(finalMessage, to: .mesh)
            synchronizePublicConversationStore(for: .mesh)
        }

        if isGeo && finalMessage.sender != "system",
           let geohash = context.currentGeohash,
           context.appendGeohashMessageIfAbsent(finalMessage, toGeohash: geohash) {
            synchronizePublicConversationStore(forGeohash: geohash)
        }

        let isSystem = finalMessage.sender == "system"
        let channelMatches: Bool = {
            switch context.activeChannel {
            case .mesh: return !isGeo || isSystem
            case .location: return isGeo || isSystem
            }
        }()

        guard channelMatches else { return }

        if !finalMessage.content.trimmed.isEmpty,
           !context.messages.contains(where: { $0.id == finalMessage.id }) {
            context.enqueuePublicMessage(finalMessage)
        }
    }

    func checkForMentions(_ message: BitchatMessage) {
        var myTokens: Set<String> = [context.nickname]
        let meshPeers = context.meshPeerNicknames()
        let collisions = meshPeers.values.filter { $0.hasPrefix(context.nickname + "#") }
        if !collisions.isEmpty {
            let suffix = "#" + String(context.myPeerID.id.prefix(4))
            myTokens = [context.nickname + suffix]
        }
        let isMentioned = message.mentions?.contains(where: myTokens.contains) ?? false

        if isMentioned && message.sender != context.nickname {
            SecureLogger.info("🔔 Mention from \(message.sender)", category: .session)
            context.notifyMention(from: message.sender, message: message.content)
        }
    }

    func sendHapticFeedback(for message: BitchatMessage) {
        #if os(iOS)
        guard UIApplication.shared.applicationState == .active else { return }

        var tokens: [String] = [context.nickname]
        switch context.activeChannel {
        case .location(let channel):
            if let identity = try? context.deriveNostrIdentity(forGeohash: channel.geohash) {
                tokens.append(context.nickname + "#" + String(identity.publicKeyHex.suffix(4)))
            }
        case .mesh:
            break
        }

        let hugsMe = tokens.contains { message.content.contains("hugs \($0)") } || message.content.contains("hugs you")
        let slapsMe = tokens.contains { message.content.contains("slaps \($0) around") } || message.content.contains("slaps you around")
        let isHugForMe = message.content.contains("🫂") && hugsMe
        let isSlapForMe = message.content.contains("🐟") && slapsMe

        if isHugForMe && message.sender != context.nickname {
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.prepare()

            for i in 0..<8 {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + Double(i) * TransportConfig.uiBatchDispatchStaggerSeconds
                ) {
                    impactFeedback.impactOccurred()
                }
            }
        } else if isSlapForMe && message.sender != context.nickname {
            let impactFeedback = UIImpactFeedbackGenerator(style: .heavy)
            impactFeedback.prepare()
            impactFeedback.impactOccurred()
        }
        #endif
    }

    func pipelineCurrentMessages(_ pipeline: PublicMessagePipeline) -> [BitchatMessage] {
        context.messages
    }

    func pipeline(_ pipeline: PublicMessagePipeline, setMessages messages: [BitchatMessage]) {
        context.messages = messages
    }

    func pipeline(_ pipeline: PublicMessagePipeline, normalizeContent content: String) -> String {
        context.normalizedContentKey(content)
    }

    func pipeline(_ pipeline: PublicMessagePipeline, contentTimestampForKey key: String) -> Date? {
        context.contentTimestamp(forKey: key)
    }

    func pipeline(_ pipeline: PublicMessagePipeline, recordContentKey key: String, timestamp: Date) {
        context.recordContentKey(key, timestamp: timestamp)
    }

    func pipelineTrimMessages(_ pipeline: PublicMessagePipeline) {
        context.trimMessagesIfNeeded()
    }

    func pipelinePrewarmMessage(_ pipeline: PublicMessagePipeline, message: BitchatMessage) {
        context.prewarmMessageFormatting(message)
    }

    func pipelineSetBatchingState(_ pipeline: PublicMessagePipeline, isBatching: Bool) {
        context.setPublicBatching(isBatching)
    }
}

private extension ChatPublicConversationCoordinator {
    func normalizedSenderKey(for message: BitchatMessage) -> String {
        if let senderPeerID = message.senderPeerID {
            if senderPeerID.isGeoChat || senderPeerID.isGeoDM {
                let full = (context.nostrKeyMapping[senderPeerID] ?? senderPeerID.bare).lowercased()
                return "nostr:" + full
            } else if senderPeerID.id.count == 16,
                      let full = context.cachedStablePeerID(for: senderPeerID)?.id.lowercased() {
                return "noise:" + full
            } else {
                return "mesh:" + senderPeerID.id.lowercased()
            }
        }
        return "name:" + message.sender.lowercased()
    }
}
