import BitFoundation
import BitLogger
import Foundation

/// The narrow surface `ChatDeliveryCoordinator` needs from its owner.
///
/// Coordinators should depend on the minimal context they actually use rather
/// than holding an `unowned` back-reference to the whole `ChatViewModel`. This
/// keeps the coordinator independently testable (see
/// `ChatDeliveryCoordinatorContextTests`) and makes its true dependencies
/// explicit. This protocol is the exemplar for migrating the other
/// coordinators off their `unowned let viewModel: ChatViewModel` back-refs.
@MainActor
protocol ChatDeliveryContext: AnyObject {
    var messages: [BitchatMessage] { get set }
    var privateChats: [PeerID: [BitchatMessage]] { get }
    var isStartupPhase: Bool { get }
    /// Applies a delivery status to a private message by ID (single-writer
    /// store intent; full delivery migration is step 4). Returns `false`
    /// when the message is unknown or the update would downgrade the status.
    @discardableResult
    func setPrivateDeliveryStatus(_ status: DeliveryStatus, forMessageID messageID: String, peerID: PeerID) -> Bool
    /// Drops every recorded read receipt whose message ID is not in `validMessageIDs`.
    /// Returns the number of receipts removed. (Single mutation path for the
    /// owner's `sentReadReceipts`; this coordinator never reads the raw set.)
    func pruneSentReadReceipts(keeping validMessageIDs: Set<String>) -> Int
    /// Signals that message state changed so observers refresh (e.g. `objectWillChange.send()`).
    func notifyUIChanged()
    /// Confirms receipt so the message router stops retaining the message for resend.
    func markMessageDelivered(_ messageID: String)
}

extension ChatViewModel: ChatDeliveryContext {
    func notifyUIChanged() {
        objectWillChange.send()
    }

    func markMessageDelivered(_ messageID: String) {
        messageRouter.markDelivered(messageID)
    }
}

final class ChatDeliveryCoordinator {
    private unowned let context: any ChatDeliveryContext
    private var messageLocationIndex: [String: Set<MessageLocation>] = [:]
    private var indexedPublicMessageCount = 0
    private var indexedPublicTailMessageID: String?
    private var indexedPrivateMessageCounts: [PeerID: Int] = [:]
    private var indexedPrivateTailMessageIDs: [PeerID: String] = [:]
    private var hasBuiltMessageLocationIndex = false

    init(context: any ChatDeliveryContext) {
        self.context = context
    }

    @MainActor
    func cleanupOldReadReceipts() {
        guard !context.isStartupPhase, !context.privateChats.isEmpty else {
            return
        }

        let validMessageIDs = Set(
            context.privateChats.values.flatMap { messages in
                messages.map(\.id)
            }
        )

        let removedCount = context.pruneSentReadReceipts(keeping: validMessageIDs)
        if removedCount > 0 {
            SecureLogger.debug("🧹 Cleaned up \(removedCount) old read receipts", category: .session)
        }
    }

    @MainActor
    func didReceiveReadReceipt(_ receipt: ReadReceipt) {
        updateMessageDeliveryStatus(
            receipt.originalMessageID,
            status: .read(by: receipt.readerNickname, at: receipt.timestamp)
        )
    }

    @MainActor
    func didUpdateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) {
        updateMessageDeliveryStatus(messageID, status: status)
    }

    @MainActor
    func deliveryStatus(for messageID: String) -> DeliveryStatus? {
        withValidLocations(for: messageID) { locations in
            locations.lazy.compactMap { self.deliveryStatus(at: $0) }.first
        }
    }

    @MainActor
    @discardableResult
    func updateMessageDeliveryStatus(_ messageID: String, status: DeliveryStatus) -> Bool {
        switch status {
        case .delivered, .read:
            // Confirmed receipt — stop retaining the message for resend.
            context.markMessageDelivered(messageID)
        default:
            break
        }

        var didUpdateStatus = false
        let locations = withValidLocations(for: messageID) { $0 }
        guard !locations.isEmpty else { return false }

        for location in locations {
            guard case .publicTimeline(let index) = location,
                  index < context.messages.count,
                  context.messages[index].id == messageID else {
                continue
            }

            let currentStatus = context.messages[index].deliveryStatus
            if !shouldSkipUpdate(currentStatus: currentStatus, newStatus: status) {
                context.messages[index].deliveryStatus = status
                didUpdateStatus = true
            }
        }

        for location in locations {
            guard case .privateChat(let peerID, let index) = location,
                  let chatMessages = context.privateChats[peerID],
                  index < chatMessages.count,
                  chatMessages[index].id == messageID else {
                continue
            }

            let currentStatus = chatMessages[index].deliveryStatus
            guard !shouldSkipUpdate(currentStatus: currentStatus, newStatus: status) else { continue }

            if context.setPrivateDeliveryStatus(status, forMessageID: messageID, peerID: peerID) {
                didUpdateStatus = true
            }
        }

        if didUpdateStatus {
            context.notifyUIChanged()
        }

        return didUpdateStatus
    }
}

private extension ChatDeliveryCoordinator {
    enum MessageLocation: Hashable {
        case publicTimeline(index: Int)
        case privateChat(peerID: PeerID, index: Int)
    }

    func shouldSkipUpdate(currentStatus: DeliveryStatus?, newStatus: DeliveryStatus) -> Bool {
        guard let currentStatus else { return false }
        if currentStatus == newStatus { return true }

        switch (currentStatus, newStatus) {
        case (.read, .delivered), (.read, .sent):
            return true
        default:
            return false
        }
    }

    @MainActor
    func withValidLocations<T>(
        for messageID: String,
        _ body: (Set<MessageLocation>) -> T
    ) -> T {
        let didRebuildIndex = refreshMessageLocationIndexForGrowth()

        if let locations = messageLocationIndex[messageID],
           locations.allSatisfy({ isLocation($0, validFor: messageID) }) {
            return body(locations)
        }

        guard !didRebuildIndex else {
            return body(messageLocationIndex[messageID] ?? [])
        }

        if messageLocationIndex[messageID] == nil {
            return body([])
        }

        rebuildMessageLocationIndex()
        return body(messageLocationIndex[messageID] ?? [])
    }

    @MainActor
    func deliveryStatus(at location: MessageLocation) -> DeliveryStatus? {
        switch location {
        case .publicTimeline(let index):
            guard index < context.messages.count else { return nil }
            return context.messages[index].deliveryStatus
        case .privateChat(let peerID, let index):
            guard let messages = context.privateChats[peerID],
                  index < messages.count else {
                return nil
            }
            return messages[index].deliveryStatus
        }
    }

    @MainActor
    func isLocation(_ location: MessageLocation, validFor messageID: String) -> Bool {
        switch location {
        case .publicTimeline(let index):
            return index < context.messages.count
                && context.messages[index].id == messageID
        case .privateChat(let peerID, let index):
            guard let messages = context.privateChats[peerID],
                  index < messages.count else {
                return false
            }
            return messages[index].id == messageID
        }
    }

    @MainActor
    @discardableResult
    func refreshMessageLocationIndexForGrowth() -> Bool {
        guard hasBuiltMessageLocationIndex else {
            rebuildMessageLocationIndex()
            return true
        }

        if context.messages.count < indexedPublicMessageCount {
            rebuildMessageLocationIndex()
            return true
        }

        if context.messages.count == indexedPublicMessageCount,
           context.messages.last?.id != indexedPublicTailMessageID {
            rebuildMessageLocationIndex()
            return true
        }

        if context.messages.count > indexedPublicMessageCount {
            // Growth is only a pure append if the previously indexed tail kept
            // its position; a middle insertion (out-of-order timestamp arrival)
            // shifts it and invalidates every indexed location after the
            // insertion point.
            if indexedPublicMessageCount > 0,
               context.messages[indexedPublicMessageCount - 1].id != indexedPublicTailMessageID {
                rebuildMessageLocationIndex()
                return true
            }
            for index in indexedPublicMessageCount..<context.messages.count {
                add(.publicTimeline(index: index), for: context.messages[index].id)
            }
            indexedPublicMessageCount = context.messages.count
            indexedPublicTailMessageID = context.messages.last?.id
        }

        let currentPeerIDs = Set(context.privateChats.keys)
        if !Set(indexedPrivateMessageCounts.keys).isSubset(of: currentPeerIDs) {
            rebuildMessageLocationIndex()
            return true
        }

        for (peerID, messages) in context.privateChats {
            let indexedCount = indexedPrivateMessageCounts[peerID] ?? 0
            if messages.count < indexedCount {
                rebuildMessageLocationIndex()
                return true
            }

            if messages.count == indexedCount,
               messages.last?.id != indexedPrivateTailMessageIDs[peerID] {
                rebuildMessageLocationIndex()
                return true
            }

            guard messages.count > indexedCount else { continue }
            // Same append-only check as the public timeline above.
            if indexedCount > 0,
               messages[indexedCount - 1].id != indexedPrivateTailMessageIDs[peerID] {
                rebuildMessageLocationIndex()
                return true
            }
            for index in indexedCount..<messages.count {
                add(.privateChat(peerID: peerID, index: index), for: messages[index].id)
            }
            indexedPrivateMessageCounts[peerID] = messages.count
            if let tailID = messages.last?.id {
                indexedPrivateTailMessageIDs[peerID] = tailID
            } else {
                indexedPrivateTailMessageIDs.removeValue(forKey: peerID)
            }
        }

        return false
    }

    @MainActor
    func rebuildMessageLocationIndex() {
        messageLocationIndex.removeAll(keepingCapacity: true)

        for (index, message) in context.messages.enumerated() {
            add(.publicTimeline(index: index), for: message.id)
        }
        indexedPublicMessageCount = context.messages.count
        indexedPublicTailMessageID = context.messages.last?.id

        indexedPrivateMessageCounts.removeAll(keepingCapacity: true)
        indexedPrivateTailMessageIDs.removeAll(keepingCapacity: true)
        for (peerID, messages) in context.privateChats {
            for (index, message) in messages.enumerated() {
                add(.privateChat(peerID: peerID, index: index), for: message.id)
            }
            indexedPrivateMessageCounts[peerID] = messages.count
            if let tailID = messages.last?.id {
                indexedPrivateTailMessageIDs[peerID] = tailID
            }
        }

        hasBuiltMessageLocationIndex = true
    }

    func add(_ location: MessageLocation, for messageID: String) {
        messageLocationIndex[messageID, default: []].insert(location)
    }
}
