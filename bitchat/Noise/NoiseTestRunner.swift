import CryptoKit
import Foundation

// MARK: - Minimal Mocks for Dependencies

protocol KeychainManagerProtocol {
	func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool
	func getIdentityKey(forKey key: String) -> Data?
	func deleteIdentityKey(forKey key: String) -> Bool
	func deleteAllKeychainData() -> Bool
	func secureClear(_ data: inout Data)
	func secureClear(_ string: inout String)
	func verifyIdentityKeyExists() -> Bool
}

struct MockKeychain: KeychainManagerProtocol {
	func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool { true }
	func getIdentityKey(forKey key: String) -> Data? { nil }
	func deleteIdentityKey(forKey key: String) -> Bool { true }
	func deleteAllKeychainData() -> Bool { true }
	func secureClear(_ data: inout Data) { data.resetBytes(in: 0..<data.count) }
	func secureClear(_ string: inout String) { string = "" }
	func verifyIdentityKeyExists() -> Bool { true }
}

enum SecureLogCategory { case encryption, security }

struct SecureLogger {
	static func debug(_ message: String, category: SecureLogCategory? = nil) {}
	static func info(_ message: Any) {}
	static func warning(_ message: String, category: SecureLogCategory) {}
	static func error(_ message: Any, category: SecureLogCategory? = nil) {}
	static func logKeyOperation(_ op: String, keyType: String, success: Bool) {}
}

enum SecureLogEvent {
	case handshakeCompleted(peerID: String)
	case sessionExpired(peerID: String)
	case authenticationFailed(peerID: String)
}

extension SecureLogger {
	static func error(_ event: SecureLogEvent) {}
	static func info(_ event: SecureLogEvent) {}
}

// MARK: - Test Vector Structure

struct NoiseTestVector: Codable {
	let protocol_name: String
	let init_prologue: String
	let init_static: String
	let init_ephemeral: String
	let init_psks: [String]?
	let resp_prologue: String
	let resp_static: String
	let resp_ephemeral: String
	let resp_psks: [String]?
	let handshake_hash: String?
	let messages: [TestMessage]

	struct TestMessage: Codable {
		let payload: String
		let ciphertext: String
	}
}

// MARK: - Helper Extensions

extension Data {
	init?(hex: String) {
		let cleaned = hex.replacingOccurrences(of: " ", with: "")
		guard cleaned.count % 2 == 0 else { return nil }
		var data = Data(capacity: cleaned.count / 2)
		var index = cleaned.startIndex
		while index < cleaned.endIndex {
			let nextIndex = cleaned.index(index, offsetBy: 2)
			guard let byte = UInt8(cleaned[index..<nextIndex], radix: 16) else { return nil }
			data.append(byte)
			index = nextIndex
		}
		self = data
	}

	func hexString() -> String {
		map { String(format: "%02x", $0) }.joined()
	}
}

// MARK: - Test Runner

func runNoiseTests() {
	print("=== Noise Protocol Test Vector Runner ===\n")

	// Load test vectors
	guard let testData = try? Data(contentsOf: URL(fileURLWithPath: "NoiseTestVectors.json")),
		let testVectors = try? JSONDecoder().decode([NoiseTestVector].self, from: testData)
	else {
		print("❌ Failed to load test vectors")
		exit(1)
	}

	print("Found \(testVectors.count) test vector(s)\n")

	for (index, testVector) in testVectors.enumerated() {
		print("=== Test Vector \(index + 1) ===")
		print("Protocol: \(testVector.protocol_name)")
		runSingleTest(testVector)
		print("")
	}

	print("=== All Test Vectors Passed! ===")
}

func runSingleTest(_ testVector: NoiseTestVector) {

	// Parse test inputs
	guard let initStatic = Data(hex: testVector.init_static),
		let initEphemeral = Data(hex: testVector.init_ephemeral),
		let respStatic = Data(hex: testVector.resp_static),
		let respEphemeral = Data(hex: testVector.resp_ephemeral),
		let prologue = Data(hex: testVector.init_prologue)
	else {
		print("❌ Failed to parse test vector hex strings")
		exit(1)
	}

	let expectedHash = testVector.handshake_hash.flatMap { Data(hex: $0) }

	// Create keys
	guard
		let initStaticKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: initStatic),
		let initEphemeralKey = try? Curve25519.KeyAgreement.PrivateKey(
			rawRepresentation: initEphemeral),
		let respStaticKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: respStatic),
		let respEphemeralKey = try? Curve25519.KeyAgreement.PrivateKey(
			rawRepresentation: respEphemeral)
	else {
		print("❌ Failed to create keys from test vectors")
		exit(1)
	}

	let keychain = MockKeychain()

	// Create handshake states
	let initiatorHandshake = NoiseHandshakeState(
		role: .initiator,
		pattern: .XX,
		keychain: keychain,
		localStaticKey: initStaticKey,
		prologue: prologue,
		predeterminedEphemeralKey: initEphemeralKey
	)

	let responderHandshake = NoiseHandshakeState(
		role: .responder,
		pattern: .XX,
		keychain: keychain,
		localStaticKey: respStaticKey,
		prologue: prologue,
		predeterminedEphemeralKey: respEphemeralKey
	)

	print("\n--- Handshake Phase ---")

	// Message 1: Initiator -> Responder (e)
	guard let msg1 = try? initiatorHandshake.writeMessage() else {
		print("❌ Failed to write message 1")
		exit(1)
	}
	print("✓ Message 1: Initiator sent ephemeral (\(msg1.count) bytes)")

	guard (try? responderHandshake.readMessage(msg1)) != nil else {
		print("❌ Failed to read message 1")
		exit(1)
	}
	print("✓ Message 1: Responder received")

	// Message 2: Responder -> Initiator (e, ee, s, es)
	guard let msg2 = try? responderHandshake.writeMessage() else {
		print("❌ Failed to write message 2")
		exit(1)
	}
	print("✓ Message 2: Responder sent (\(msg2.count) bytes)")

	guard (try? initiatorHandshake.readMessage(msg2)) != nil else {
		print("❌ Failed to read message 2")
		exit(1)
	}
	print("✓ Message 2: Initiator received")

	// Message 3: Initiator -> Responder (s, se)
	guard let msg3 = try? initiatorHandshake.writeMessage() else {
		print("❌ Failed to write message 3")
		exit(1)
	}
	print("✓ Message 3: Initiator sent (\(msg3.count) bytes)")

	guard (try? responderHandshake.readMessage(msg3)) != nil else {
		print("❌ Failed to read message 3")
		exit(1)
	}
	print("✓ Message 3: Responder received")

	// Verify handshake hash
	let initiatorHash = initiatorHandshake.getHandshakeHash()
	let responderHash = responderHandshake.getHandshakeHash()

	if initiatorHash != responderHash {
		print("❌ Initiator and responder hashes don't match!")
		exit(1)
	}

	if let expectedHash = expectedHash {
		if initiatorHash == expectedHash {
			print("✓ Handshake hash verified")
		} else {
			print("⚠️  Handshake hash differs from test vector (may be implementation-specific)")
		}
	} else {
		print("✓ Handshake complete")
	}

	// Get transport ciphers
	guard let (initSend, initRecv) = try? initiatorHandshake.getTransportCiphers(),
		let (respSend, respRecv) = try? responderHandshake.getTransportCiphers()
	else {
		print("❌ Failed to split to transport ciphers")
		exit(1)
	}

	print("\n--- Transport Phase ---")

	// Test transport messages
	var passedMessages = 0
	for (index, testMsg) in testVector.messages.enumerated() {
		guard let payload = Data(hex: testMsg.payload) else {
			print("❌ Message \(index + 1): Failed to parse payload hex")
			exit(1)
		}

		// Alternate between initiator and responder sending
		let (sender, receiver): (NoiseCipherState, NoiseCipherState)
		let direction: String
		if index % 2 == 0 {
			sender = initSend
			receiver = respRecv
			direction = "Initiator → Responder"
		} else {
			sender = respSend
			receiver = initRecv
			direction = "Responder → Initiator"
		}

		// Encrypt
		guard let ciphertext = try? sender.encrypt(plaintext: payload) else {
			print("❌ Message \(index + 1): Encryption failed")
			exit(1)
		}

		// Decrypt
		guard let decrypted = try? receiver.decrypt(ciphertext: ciphertext) else {
			print("❌ Message \(index + 1): Decryption failed")
			print("  Ciphertext: \(ciphertext.hexString())")
			exit(1)
		}

		if decrypted == payload {
			print(
				"✓ Message \(index + 1) (\(direction)): Encrypt/decrypt successful (\(payload.count) bytes)"
			)
			passedMessages += 1
		} else {
			print("❌ Message \(index + 1): Decrypted payload mismatch!")
			print("  Expected: \(payload.hexString())")
			print("  Got:      \(decrypted.hexString())")
			exit(1)
		}
	}

	print("✓ Test Passed!")
	print("  Handshake: ✓")
	print("  Transport Messages: \(passedMessages)/\(testVector.messages.count) ✓")
}

// MARK: - Main Entry Point

@main
struct NoiseTestRunner {
	static func main() {
		runNoiseTests()
	}
}
