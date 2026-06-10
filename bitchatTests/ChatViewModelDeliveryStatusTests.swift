//
// ChatViewModelDeliveryStatusTests.swift
// bitchatTests
//
// Tests for ChatViewModel delivery status state machine.
//

import Testing
import Foundation
import BitFoundation
@testable import bitchat

// MARK: - Test Helpers

@MainActor
private func makeTestableViewModel() -> (viewModel: ChatViewModel, transport: MockTransport) {
    let keychain = MockKeychain()
    let keychainHelper = MockKeychainHelper()
    let idBridge = NostrIdentityBridge(keychain: keychainHelper)
    let identityManager = MockIdentityManager(keychain)
    let transport = MockTransport()

    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: idBridge,
        identityManager: identityManager,
        transport: transport
    )

    return (viewModel, transport)
}

// MARK: - Delivery Status Tests

struct ChatViewModelDeliveryStatusTests {

    // MARK: - Status Transition Tests

    @Test @MainActor
    func deliveryStatus_noDowngrade_readToDelivered() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060708")
        let messageID = "test-msg-1"

        // Setup: create a message with .read status
        let message = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: "Test message",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .read(by: "Peer", at: Date())
        )
        viewModel.privateChats[peerID] = [message]

        // Action: try to downgrade to .delivered
        viewModel.didUpdateMessageDeliveryStatus(messageID, status: .delivered(to: "Peer", at: Date()))

        // Assert: status should remain .read (no downgrade)
        let currentStatus = viewModel.privateChats[peerID]?.first?.deliveryStatus
        #expect({
            if case .read = currentStatus { return true }
            return false
        }())
    }

    @Test @MainActor
    func deliveryStatus_upgrade_sentToDelivered() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060708")
        let messageID = "test-msg-2"

        // Setup: create a message with .sent status
        let message = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: "Test message",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .sent
        )
        viewModel.privateChats[peerID] = [message]

        // Action: upgrade to .delivered
        viewModel.didUpdateMessageDeliveryStatus(messageID, status: .delivered(to: "Peer", at: Date()))

        // Assert: status should be .delivered
        let currentStatus = viewModel.privateChats[peerID]?.first?.deliveryStatus
        #expect({
            if case .delivered = currentStatus { return true }
            return false
        }())
    }

    @Test @MainActor
    func deliveryStatus_identicalUpdateIsNoop() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060708")
        let messageID = "test-msg-identical"
        let message = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: "Test message",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .sent
        )
        viewModel.privateChats[peerID] = [message]

        let didUpdate = viewModel.deliveryCoordinator.updateMessageDeliveryStatus(messageID, status: .sent)

        #expect(!didUpdate)
        #expect(isSent(viewModel.privateChats[peerID]?.first?.deliveryStatus))
    }

    @Test @MainActor
    func deliveryStatus_upgrade_deliveredToRead() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060708")
        let messageID = "test-msg-3"

        // Setup: create a message with .delivered status
        let message = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: "Test message",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .delivered(to: "Peer", at: Date().addingTimeInterval(-60))
        )
        viewModel.privateChats[peerID] = [message]

        // Action: upgrade to .read
        viewModel.didUpdateMessageDeliveryStatus(messageID, status: .read(by: "Peer", at: Date()))

        // Assert: status should be .read
        let currentStatus = viewModel.privateChats[peerID]?.first?.deliveryStatus
        #expect({
            if case .read = currentStatus { return true }
            return false
        }())
    }

    // MARK: - Read Receipt Handling

    @Test @MainActor
    func didReceiveReadReceipt_updatesMessageStatus() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060708")
        let messageID = "test-msg-4"

        // Setup: create a message with .sent status
        let message = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: "Test message",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .sent
        )
        viewModel.privateChats[peerID] = [message]

        // Action: receive read receipt
        let receipt = ReadReceipt(
            originalMessageID: messageID,
            readerID: peerID,
            readerNickname: "Peer"
        )
        viewModel.didReceiveReadReceipt(receipt)

        // Assert: status should be .read
        let currentStatus = viewModel.privateChats[peerID]?.first?.deliveryStatus
        #expect({
            if case .read = currentStatus { return true }
            return false
        }())
    }

    @Test @MainActor
    func cleanupOldReadReceipts_removesReceiptIDsWithoutMessages() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060709")

        let message = BitchatMessage(
            id: "keep-receipt",
            sender: viewModel.nickname,
            content: "Keep me",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .sent
        )
        viewModel.privateChats[peerID] = [message]
        viewModel.sentReadReceipts = ["keep-receipt", "drop-receipt"]
        viewModel.isStartupPhase = false

        viewModel.cleanupOldReadReceipts()

        #expect(viewModel.sentReadReceipts == ["keep-receipt"])
    }

    // MARK: - Public Timeline Status Tests

    @Test @MainActor
    func deliveryStatus_publicTimeline_updatesCorrectly() async {
        let (viewModel, _) = makeTestableViewModel()
        let messageID = "public-msg-1"

        // Setup: add a message to public timeline with .sending status
        let message = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: "Public message",
            timestamp: Date(),
            isRelay: false,
            isPrivate: false,
            deliveryStatus: .sending
        )
        viewModel.messages.append(message)

        // Action: update to .sent
        viewModel.didUpdateMessageDeliveryStatus(messageID, status: .sent)

        // Assert
        let updatedMessage = viewModel.messages.first(where: { $0.id == messageID })
        #expect({
            if case .sent = updatedMessage?.deliveryStatus { return true }
            return false
        }())
    }

    @Test @MainActor
    func deliveryStatus_updatesPublicAndMirroredPrivateMessages() async {
        let (viewModel, transport) = makeTestableViewModel()
        let messageID = "mirrored-msg-1"
        let firstPeerID = PeerID(str: "0102030405060708")
        let secondPeerID = PeerID(str: "1112131415161718")

        viewModel.messages = [
            BitchatMessage(
                id: messageID,
                sender: viewModel.nickname,
                content: "Public copy",
                timestamp: Date(),
                isRelay: false,
                isPrivate: false,
                senderPeerID: transport.myPeerID,
                deliveryStatus: .sent
            )
        ]
        viewModel.privateChats[firstPeerID] = [
            BitchatMessage(
                id: messageID,
                sender: viewModel.nickname,
                content: "Private copy A",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Peer A",
                senderPeerID: transport.myPeerID,
                deliveryStatus: .sent
            )
        ]
        viewModel.privateChats[secondPeerID] = [
            BitchatMessage(
                id: messageID,
                sender: viewModel.nickname,
                content: "Private copy B",
                timestamp: Date(),
                isRelay: false,
                isPrivate: true,
                recipientNickname: "Peer B",
                senderPeerID: transport.myPeerID,
                deliveryStatus: .sent
            )
        ]

        let didUpdate = viewModel.deliveryCoordinator.updateMessageDeliveryStatus(
            messageID,
            status: .delivered(to: "Peer", at: Date())
        )

        #expect(didUpdate)
        #expect(isDelivered(viewModel.messages.first?.deliveryStatus))
        #expect(isDelivered(viewModel.privateChats[firstPeerID]?.first?.deliveryStatus))
        #expect(isDelivered(viewModel.privateChats[secondPeerID]?.first?.deliveryStatus))
    }

    @Test @MainActor
    func deliveryStatus_indexRefreshesAfterPrivateChatReorder() async {
        let (viewModel, transport) = makeTestableViewModel()
        let peerID = PeerID(str: "0102030405060708")
        let messageID = "reordered-msg-1"
        let olderMessage = BitchatMessage(
            id: "older-msg",
            sender: viewModel.nickname,
            content: "Older message",
            timestamp: Date(timeIntervalSince1970: 1),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .sent
        )
        let targetMessage = BitchatMessage(
            id: messageID,
            sender: viewModel.nickname,
            content: "Target message",
            timestamp: Date(timeIntervalSince1970: 2),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "Peer",
            senderPeerID: transport.myPeerID,
            deliveryStatus: .sent
        )

        viewModel.privateChats[peerID] = [targetMessage, olderMessage]
        #expect(isSent(viewModel.deliveryCoordinator.deliveryStatus(for: messageID)))

        viewModel.privateChats[peerID] = [olderMessage, targetMessage]
        let didUpdate = viewModel.deliveryCoordinator.updateMessageDeliveryStatus(
            messageID,
            status: .read(by: "Peer", at: Date())
        )

        #expect(didUpdate)
        #expect(isRead(viewModel.privateChats[peerID]?.last?.deliveryStatus))
    }

    // MARK: - Status Rank Tests (for deduplication)

    @Test @MainActor
    func statusRank_orderingIsCorrect() async {
        // This tests the implicit ordering used in refreshVisibleMessages
        // failed < sending < sent < partiallyDelivered < delivered < read

        let statuses: [DeliveryStatus] = [
            .failed(reason: "test"),
            .sending,
            .sent,
            .partiallyDelivered(reached: 1, total: 3),
            .delivered(to: "B", at: Date()),
            .read(by: "C", at: Date())
        ]

        // Verify each status has a logical progression
        // This is more of a documentation test to ensure the ranking logic is understood
        for (index, status) in statuses.enumerated() {
            switch status {
            case .failed: #expect(index == 0)
            case .sending: #expect(index == 1)
            case .sent: #expect(index == 2)
            case .partiallyDelivered: #expect(index == 3)
            case .delivered: #expect(index == 4)
            case .read: #expect(index == 5)
            }
        }
    }
}

// MARK: - Mock Delivery Context

/// Lightweight stand-in for `ChatDeliveryContext` proving that
/// `ChatDeliveryCoordinator` is testable without constructing a `ChatViewModel`.
@MainActor
private final class MockChatDeliveryContext: ChatDeliveryContext {
    var messages: [BitchatMessage] = []
    var privateChats: [PeerID: [BitchatMessage]] = [:]
    var sentReadReceipts: Set<String> = []
    var isStartupPhase = false
    private(set) var notifyUIChangedCount = 0
    private(set) var markedDeliveredMessageIDs: [String] = []

    func notifyUIChanged() {
        notifyUIChangedCount += 1
    }

    func markMessageDelivered(_ messageID: String) {
        markedDeliveredMessageIDs.append(messageID)
    }
}

@MainActor
private func makePrivateMessage(id: String, status: DeliveryStatus) -> BitchatMessage {
    BitchatMessage(
        id: id,
        sender: "me",
        content: "Test message",
        timestamp: Date(),
        isRelay: false,
        isPrivate: true,
        recipientNickname: "Peer",
        senderPeerID: PeerID(str: "aabbccddeeff0011"),
        deliveryStatus: status
    )
}

// MARK: - Coordinator Tests Against Mock Context

/// Exercises `ChatDeliveryCoordinator` against `MockChatDeliveryContext` —
/// the exemplar for the narrow-dependency coordinator pattern.
struct ChatDeliveryCoordinatorContextTests {

    @Test @MainActor
    func updateDeliveryStatus_updatesPrivateChatNotifiesAndMarksDelivered() async {
        let context = MockChatDeliveryContext()
        let coordinator = ChatDeliveryCoordinator(context: context)
        let peerID = PeerID(str: "0102030405060708")
        let messageID = "mock-msg-1"
        context.privateChats[peerID] = [makePrivateMessage(id: messageID, status: .sent)]

        let didUpdate = coordinator.updateMessageDeliveryStatus(
            messageID,
            status: .delivered(to: "Peer", at: Date())
        )

        #expect(didUpdate)
        #expect(isDelivered(context.privateChats[peerID]?.first?.deliveryStatus))
        #expect(context.notifyUIChangedCount == 1)
        #expect(context.markedDeliveredMessageIDs == [messageID])
    }

    @Test @MainActor
    func readReceipt_marksDeliveredAndUpgradesStatus() async {
        let context = MockChatDeliveryContext()
        let coordinator = ChatDeliveryCoordinator(context: context)
        let peerID = PeerID(str: "0102030405060708")
        let messageID = "mock-msg-2"
        context.privateChats[peerID] = [makePrivateMessage(id: messageID, status: .delivered(to: "Peer", at: Date()))]

        coordinator.didReceiveReadReceipt(
            ReadReceipt(originalMessageID: messageID, readerID: peerID, readerNickname: "Peer")
        )

        #expect(isRead(context.privateChats[peerID]?.first?.deliveryStatus))
        #expect(context.notifyUIChangedCount == 1)
        #expect(context.markedDeliveredMessageIDs == [messageID])
    }

    @Test @MainActor
    func sentStatus_doesNotMarkDeliveredAndUnknownMessageDoesNotNotify() async {
        let context = MockChatDeliveryContext()
        let coordinator = ChatDeliveryCoordinator(context: context)
        context.messages = [
            BitchatMessage(
                id: "public-mock-1",
                sender: "me",
                content: "Public message",
                timestamp: Date(),
                isRelay: false,
                isPrivate: false,
                deliveryStatus: .sending
            )
        ]

        // .sent is not a confirmed receipt — must not reach markMessageDelivered.
        let didUpdate = coordinator.updateMessageDeliveryStatus("public-mock-1", status: .sent)
        #expect(didUpdate)
        #expect(isSent(context.messages.first?.deliveryStatus))
        #expect(context.markedDeliveredMessageIDs.isEmpty)
        #expect(context.notifyUIChangedCount == 1)

        // Unknown message: no state change, no extra UI notification.
        let didUpdateUnknown = coordinator.updateMessageDeliveryStatus("missing-msg", status: .sent)
        #expect(!didUpdateUnknown)
        #expect(context.notifyUIChangedCount == 1)
    }

    @Test @MainActor
    func middleInsertedMessage_isFoundAfterIndexWasBuilt() async {
        let context = MockChatDeliveryContext()
        let coordinator = ChatDeliveryCoordinator(context: context)
        let makePublic = { (id: String) in
            BitchatMessage(
                id: id,
                sender: "me",
                content: "Public message",
                timestamp: Date(),
                isRelay: false,
                isPrivate: false,
                deliveryStatus: .sending
            )
        }
        context.messages = [makePublic("public-a"), makePublic("public-b")]

        // Build the incremental index.
        #expect(coordinator.updateMessageDeliveryStatus("public-a", status: .sent))

        // Out-of-order arrival: PublicMessagePipeline inserts by timestamp,
        // so the count grows while the tail ID stays the same.
        context.messages.insert(makePublic("public-mid"), at: 1)

        // The inserted message must be locatable, and the shifted tail must
        // not be updated through a stale index entry.
        #expect(coordinator.updateMessageDeliveryStatus("public-mid", status: .sent))
        #expect(isSent(context.messages[1].deliveryStatus))
        #expect(coordinator.updateMessageDeliveryStatus("public-b", status: .sent))
        #expect(isSent(context.messages[2].deliveryStatus))
    }

    @Test @MainActor
    func middleInsertedPrivateMessage_isFoundAfterIndexWasBuilt() async {
        let context = MockChatDeliveryContext()
        let coordinator = ChatDeliveryCoordinator(context: context)
        let peerID = PeerID(str: "0102030405060708")
        context.privateChats[peerID] = [
            makePrivateMessage(id: "pm-a", status: .sending),
            makePrivateMessage(id: "pm-b", status: .sending)
        ]

        #expect(coordinator.updateMessageDeliveryStatus("pm-a", status: .sent))

        // Timestamp re-sort (sanitizeChat) can place a late arrival mid-array.
        context.privateChats[peerID]?.insert(makePrivateMessage(id: "pm-mid", status: .sending), at: 1)

        #expect(coordinator.updateMessageDeliveryStatus("pm-mid", status: .sent))
        #expect(isSent(context.privateChats[peerID]?[1].deliveryStatus))
        #expect(coordinator.updateMessageDeliveryStatus("pm-b", status: .sent))
        #expect(isSent(context.privateChats[peerID]?[2].deliveryStatus))
    }

    @Test @MainActor
    func cleanupOldReadReceipts_prunesReceiptsAgainstMockContext() async {
        let context = MockChatDeliveryContext()
        let coordinator = ChatDeliveryCoordinator(context: context)
        let peerID = PeerID(str: "0102030405060708")
        context.privateChats[peerID] = [makePrivateMessage(id: "keep-receipt", status: .sent)]
        context.sentReadReceipts = ["keep-receipt", "drop-receipt"]

        // Startup phase: cleanup must be a no-op.
        context.isStartupPhase = true
        coordinator.cleanupOldReadReceipts()
        #expect(context.sentReadReceipts == ["keep-receipt", "drop-receipt"])

        context.isStartupPhase = false
        coordinator.cleanupOldReadReceipts()
        #expect(context.sentReadReceipts == ["keep-receipt"])
    }
}

private func isSent(_ status: DeliveryStatus?) -> Bool {
    if case .sent = status { return true }
    return false
}

private func isDelivered(_ status: DeliveryStatus?) -> Bool {
    if case .delivered = status { return true }
    return false
}

private func isRead(_ status: DeliveryStatus?) -> Bool {
    if case .read = status { return true }
    return false
}
