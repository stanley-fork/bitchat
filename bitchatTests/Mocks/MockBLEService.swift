//
// MockBLEService.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import CoreBluetooth
@testable import bitchat

/// In-memory BLE test harness used by E2E/Integration tests.
///
/// Design:
/// - Global `registry` maps `peerID` -> service instance, and `adjacency` tracks
///   simulated connections between peers. Tests call `simulateConnectedPeer` /
///   `simulateDisconnectedPeer` to manage topology.
/// - `resetTestBus()` clears global state and is called in test `setUp()`.
/// - `messageDeliveryHandler` and `packetDeliveryHandler` let tests observe messages/packets
///   as they flow, enabling scenarios like manual encryption/relay.
/// - A thread-safe `seenMessageIDs` set prevents double-delivery races during flooding.
///
/// Flooding:
/// - `autoFloodEnabled` is disabled by default; Integration tests enable it in `setUp()` to
///   simulate broadcast propagation across the mesh. E2E tests keep it off and perform explicit
///   relays when needed.
final class MockBLEService: NSObject {
    private let bus: MockBLEBus
    
    // MARK: - Properties matching BLEService
    
    weak var delegate: BitchatDelegate?
    var myPeerID = PeerID(str: "MOCK1234")
    var myNickname: String = "MockUser"
    
    private let mockKeychain = MockKeychain()
    
    // Test-specific properties
    var sentMessages: [(message: BitchatMessage, packet: BitchatPacket)] = []
    var sentPackets: [BitchatPacket] = []
    var connectedPeers: Set<PeerID> = []
    var messageDeliveryHandler: ((BitchatMessage) -> Void)?
    var packetDeliveryHandler: ((BitchatPacket) -> Void)?
    
    // Compatibility properties for old tests
    var mockNickname: String {
        get { return myNickname }
        set { myNickname = newValue }
    }
    
    var nickname: String {
        return myNickname
    }
    
    var peerID: PeerID {
        return myPeerID
    }
    
    // MARK: - Initialization
    
    init(bus: MockBLEBus) {
        self.bus = bus
    }
    
    // MARK: - Methods matching BLEService
    
    func setNickname(_ nickname: String) {
        self.myNickname = nickname
    }
    
    // MARK: - In-memory test bus (for E2E/Integration)

    /// Registers this instance on first use.
    private func registerIfNeeded() {
        bus.register(self, for: myPeerID)
    }

    /// Returns adjacent neighbors based on the current simulated topology.
    private func neighbors() -> [MockBLEService] {
        bus.neighbors(of: myPeerID)
    }

    func startServices() {
        // Mock implementation - do nothing
    }
    
    func stopServices() {
        // Mock implementation - do nothing
    }
    
    func isPeerConnected(_ peerID: PeerID) -> Bool {
        return connectedPeers.contains(peerID)
    }

    func peerNickname(peerID: String) -> String? {
        "MockPeer_\(peerID)"
    }

    func getPeerNicknames() -> [PeerID: String] {
        var nicknames: [PeerID: String] = [:]
        for peer in connectedPeers {
            nicknames[peer] = "MockPeer_\(peer)"
        }
        return nicknames
    }
    
    func getPeers() -> [PeerID: String] {
        return getPeerNicknames()
    }
    
    func sendMessage(_ content: String, mentions: [String] = [], to recipientID: String? = nil, messageID: String? = nil, timestamp: Date? = nil) {
        let message = BitchatMessage(
            id: messageID ?? UUID().uuidString,
            sender: myNickname,
            content: content,
            timestamp: timestamp ?? Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: recipientID != nil,
            recipientNickname: nil,
            senderPeerID: myPeerID,
            mentions: mentions.isEmpty ? nil : mentions
        )
        
        if let payload = message.toBinaryPayload() {
            let packet = BitchatPacket(
                type: 0x01,
                senderID: myPeerID.id.data(using: .utf8)!,
                recipientID: recipientID?.data(using: .utf8),
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: payload,
                signature: nil,
                ttl: 3
            )
            
            sentMessages.append((message, packet))
            sentPackets.append(packet)
            
            // Simulate local echo
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didReceiveMessage(message)
            }
            
            // Surface raw packet to tests that intercept/relay/encrypt
            packetDeliveryHandler?(packet)

            // Deliver public messages to adjacent peers via bus
            if recipientID == nil {
                for neighbor in neighbors() {
                    neighbor.simulateIncomingPacket(packet)
                }
            }
        }
    }

    func sendFileBroadcast(_ packet: BitchatFilePacket, transferId: String) {
        // Tests currently ignore file transfer flows; keep stub for protocol conformance.
    }

    func sendFilePrivate(_ packet: BitchatFilePacket, to peerID: PeerID, transferId: String) {
        // Tests currently ignore file transfer flows; keep stub for protocol conformance.
    }

    func sendPrivateMessage(_ content: String, to recipientPeerID: PeerID, recipientNickname: String, messageID: String) {
        let message = BitchatMessage(
            id: messageID,
            sender: myNickname,
            content: content,
            timestamp: Date(),
            isRelay: false,
            originalSender: nil,
            isPrivate: true,
            recipientNickname: recipientNickname,
            senderPeerID: myPeerID,
            mentions: nil
        )
        
        if let payload = message.toBinaryPayload() {
            let packet = BitchatPacket(
                type: 0x01,
                senderID: myPeerID.id.data(using: .utf8)!,
                recipientID: recipientPeerID.id.data(using: .utf8)!,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                payload: payload,
                signature: nil,
                ttl: 3
            )
            
            sentMessages.append((message, packet))
            sentPackets.append(packet)
            
            // Simulate local echo
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didReceiveMessage(message)
            }
            
            // Surface raw packet to tests that intercept/relay/encrypt
            packetDeliveryHandler?(packet)

            // If directly connected to recipient, deliver only to them.
            if bus.isDirectNeighbor(myPeerID, recipientPeerID),
               let target = bus.service(for: recipientPeerID) {
                target.simulateIncomingPacket(packet)
            } else {
                // Not directly connected: deliver to neighbors for relay
                for neighbor in neighbors() where neighbor.peerID != recipientPeerID {
                    neighbor.simulateIncomingPacket(packet)
                }
            }
        }
    }
    
    func sendFavoriteNotification(to peerID: String, isFavorite: Bool) {
        // Mock implementation
    }
    
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: String) {
        // Mock implementation
    }
    
    func sendBroadcastAnnounce() {
        // Mock implementation
    }
    
    func getPeerFingerprint(_ peerID: String) -> String? {
        return nil
    }
    
    func getNoiseSessionState(for peerID: String) -> LazyHandshakeState {
        return .none
    }
    
    func triggerHandshake(with peerID: String) {
        // Mock implementation
    }
    
    func emergencyDisconnectAll() {
        connectedPeers.removeAll()
        delegate?.didUpdatePeerList([])
    }
    
    func getNoiseService() -> NoiseEncryptionService {
        return NoiseEncryptionService(keychain: mockKeychain)
    }
    
    func getFingerprint(for peerID: String) -> String? {
        return nil
    }
    
    // MARK: - Test Helper Methods
    
    func simulateConnectedPeer(_ peerID: PeerID) {
        registerIfNeeded()
        bus.connect(myPeerID, peerID)
        connectedPeers.insert(peerID)
        delegate?.didConnectToPeer(peerID)
        delegate?.didUpdatePeerList(Array(connectedPeers))
    }
    
    func simulateDisconnectedPeer(_ peerID: PeerID) {
        bus.disconnect(myPeerID, peerID)
        connectedPeers.remove(peerID)
        delegate?.didDisconnectFromPeer(peerID)
        delegate?.didUpdatePeerList(Array(connectedPeers))
    }
    
    func simulateIncomingMessage(_ message: BitchatMessage) {
        delegate?.didReceiveMessage(message)
        // Also surface via test handler for E2E/Integration
        messageDeliveryHandler?(message)
    }
    
    private var seenMessageIDs: Set<String> = []
    private let seenLock = NSLock()

    func simulateIncomingPacket(_ packet: BitchatPacket) {
        // Process through the actual handling logic
        if let message = BitchatMessage(packet.payload) {
            var shouldDeliver = false
            seenLock.lock()
            if !seenMessageIDs.contains(message.id) {
                seenMessageIDs.insert(message.id)
                shouldDeliver = true
            }
            seenLock.unlock()
            if shouldDeliver {
                delegate?.didReceiveMessage(message)
                // Also surface via test handler for E2E/Integration
                messageDeliveryHandler?(message)
                // Optional flooding for integration-style broadcast tests.
                // When enabled, propagate a public broadcast across the entire connected
                // component regardless of the original TTL to better emulate large-network
                // broadcast expectations. De-duplication via seenMessageIDs prevents loops.
                if bus.autoFloodEnabled,
                   packet.recipientID == nil,
                   !message.isPrivate {
                    let nextTTL = packet.ttl > 0 ? packet.ttl - 1 : 0
                    for neighbor in neighbors() {
                        // Avoid immediate echo loopback to sender if known
                        if let sender = message.senderPeerID, sender == neighbor.peerID { continue }
                        var relay = packet
                        relay.ttl = nextTTL
                        neighbor.simulateIncomingPacket(relay)
                    }
                }
            }
        }
        packetDeliveryHandler?(packet)
    }
    
    func getConnectedPeers() -> [PeerID] {
        return Array(connectedPeers)
    }
    
    // MARK: - Compatibility methods for old tests
    
    func sendPrivateMessage(_ content: String, to recipientPeerID: PeerID, recipientNickname: String, messageID: String? = nil) {
        sendPrivateMessage(content, to: recipientPeerID, recipientNickname: recipientNickname, messageID: messageID ?? UUID().uuidString)
    }
}

// Backward compatibility for older tests
typealias MockSimplifiedBluetoothService = MockBLEService

// MARK: - Helpers

extension MockBLEService {
    convenience init(peerID: PeerID, nickname: String, bus: MockBLEBus) {
        self.init(bus: bus)
        myPeerID = peerID
        mockNickname = nickname
    }

    func simulateConnection(with otherPeer: MockBLEService) {
        simulateConnectedPeer(otherPeer.myPeerID)
        otherPeer.simulateConnectedPeer(myPeerID)
    }
}
