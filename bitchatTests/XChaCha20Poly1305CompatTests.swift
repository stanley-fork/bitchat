//
// XChaCha20Poly1305CompatTests.swift
// bitchatTests
//
// Tests for XChaCha20-Poly1305 encryption with proper error handling.
// This is free and unencumbered software released into the public domain.
//

import Testing
import Foundation
@testable import bitchat

struct XChaCha20Poly1305CompatTests {

    // MARK: - Valid Input Tests

    @Test func sealAndOpenRoundtrip() throws {
        let plaintext = "Hello, XChaCha20-Poly1305!".data(using: .utf8)!
        let key = Data(repeating: 0x42, count: 32)  // 32-byte key
        let nonce = Data(repeating: 0x24, count: 24) // 24-byte nonce

        let sealed = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: key, nonce24: nonce)
        let decrypted = try XChaCha20Poly1305Compat.open(
            ciphertext: sealed.ciphertext,
            tag: sealed.tag,
            key: key,
            nonce24: nonce
        )

        #expect(decrypted == plaintext)
    }

    @Test func sealAndOpenWithAAD() throws {
        let plaintext = "Secret message".data(using: .utf8)!
        let key = Data(repeating: 0xAB, count: 32)
        let nonce = Data(repeating: 0xCD, count: 24)
        let aad = "additional authenticated data".data(using: .utf8)!

        let sealed = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: key, nonce24: nonce, aad: aad)
        let decrypted = try XChaCha20Poly1305Compat.open(
            ciphertext: sealed.ciphertext,
            tag: sealed.tag,
            key: key,
            nonce24: nonce,
            aad: aad
        )

        #expect(decrypted == plaintext)
    }

    @Test func sealProducesDifferentCiphertextWithDifferentNonces() throws {
        let plaintext = "Same plaintext".data(using: .utf8)!
        let key = Data(repeating: 0x42, count: 32)
        let nonce1 = Data(repeating: 0x01, count: 24)
        let nonce2 = Data(repeating: 0x02, count: 24)

        let sealed1 = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: key, nonce24: nonce1)
        let sealed2 = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: key, nonce24: nonce2)

        #expect(sealed1.ciphertext != sealed2.ciphertext)
    }

    // MARK: - Invalid Key Length Tests

    @Test func sealThrowsOnShortKey() throws {
        let plaintext = "Test".data(using: .utf8)!
        let shortKey = Data(repeating: 0x42, count: 16)  // Only 16 bytes, need 32
        let nonce = Data(repeating: 0x24, count: 24)

        #expect(throws: XChaCha20Poly1305Compat.Error.self) {
            _ = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: shortKey, nonce24: nonce)
        }
    }

    @Test func sealThrowsOnLongKey() throws {
        let plaintext = "Test".data(using: .utf8)!
        let longKey = Data(repeating: 0x42, count: 64)  // 64 bytes, need 32
        let nonce = Data(repeating: 0x24, count: 24)

        #expect(throws: XChaCha20Poly1305Compat.Error.self) {
            _ = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: longKey, nonce24: nonce)
        }
    }

    @Test func sealThrowsOnEmptyKey() throws {
        let plaintext = "Test".data(using: .utf8)!
        let emptyKey = Data()
        let nonce = Data(repeating: 0x24, count: 24)

        #expect(throws: XChaCha20Poly1305Compat.Error.self) {
            _ = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: emptyKey, nonce24: nonce)
        }
    }

    @Test func openThrowsOnInvalidKeyLength() throws {
        let ciphertext = Data(repeating: 0x00, count: 16)
        let tag = Data(repeating: 0x00, count: 16)
        let shortKey = Data(repeating: 0x42, count: 31)  // 31 bytes, need 32
        let nonce = Data(repeating: 0x24, count: 24)

        #expect(throws: XChaCha20Poly1305Compat.Error.self) {
            _ = try XChaCha20Poly1305Compat.open(ciphertext: ciphertext, tag: tag, key: shortKey, nonce24: nonce)
        }
    }

    // MARK: - Invalid Nonce Length Tests

    @Test func sealThrowsOnShortNonce() throws {
        let plaintext = "Test".data(using: .utf8)!
        let key = Data(repeating: 0x42, count: 32)
        let shortNonce = Data(repeating: 0x24, count: 12)  // Only 12 bytes, need 24

        #expect(throws: XChaCha20Poly1305Compat.Error.self) {
            _ = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: key, nonce24: shortNonce)
        }
    }

    @Test func sealThrowsOnLongNonce() throws {
        let plaintext = "Test".data(using: .utf8)!
        let key = Data(repeating: 0x42, count: 32)
        let longNonce = Data(repeating: 0x24, count: 32)  // 32 bytes, need 24

        #expect(throws: XChaCha20Poly1305Compat.Error.self) {
            _ = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: key, nonce24: longNonce)
        }
    }

    @Test func sealThrowsOnEmptyNonce() throws {
        let plaintext = "Test".data(using: .utf8)!
        let key = Data(repeating: 0x42, count: 32)
        let emptyNonce = Data()

        #expect(throws: XChaCha20Poly1305Compat.Error.self) {
            _ = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: key, nonce24: emptyNonce)
        }
    }

    @Test func openThrowsOnInvalidNonceLength() throws {
        let ciphertext = Data(repeating: 0x00, count: 16)
        let tag = Data(repeating: 0x00, count: 16)
        let key = Data(repeating: 0x42, count: 32)
        let shortNonce = Data(repeating: 0x24, count: 23)  // 23 bytes, need 24

        #expect(throws: XChaCha20Poly1305Compat.Error.self) {
            _ = try XChaCha20Poly1305Compat.open(ciphertext: ciphertext, tag: tag, key: key, nonce24: shortNonce)
        }
    }

    // MARK: - Error Detail Tests

    @Test func invalidKeyLengthErrorContainsDetails() throws {
        let plaintext = "Test".data(using: .utf8)!
        let badKey = Data(repeating: 0x42, count: 16)
        let nonce = Data(repeating: 0x24, count: 24)

        do {
            _ = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: badKey, nonce24: nonce)
            Issue.record("Expected error to be thrown")
        } catch let error as XChaCha20Poly1305Compat.Error {
            if case .invalidKeyLength(let expected, let got) = error {
                #expect(expected == 32)
                #expect(got == 16)
            } else {
                Issue.record("Wrong error type")
            }
        }
    }

    @Test func invalidNonceLengthErrorContainsDetails() throws {
        let plaintext = "Test".data(using: .utf8)!
        let key = Data(repeating: 0x42, count: 32)
        let badNonce = Data(repeating: 0x24, count: 12)

        do {
            _ = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: key, nonce24: badNonce)
            Issue.record("Expected error to be thrown")
        } catch let error as XChaCha20Poly1305Compat.Error {
            if case .invalidNonceLength(let expected, let got) = error {
                #expect(expected == 24)
                #expect(got == 12)
            } else {
                Issue.record("Wrong error type")
            }
        }
    }

    // MARK: - Authentication Tests

    @Test func openFailsWithWrongKey() throws {
        let plaintext = "Secret".data(using: .utf8)!
        let correctKey = Data(repeating: 0x42, count: 32)
        let wrongKey = Data(repeating: 0x43, count: 32)
        let nonce = Data(repeating: 0x24, count: 24)

        let sealed = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: correctKey, nonce24: nonce)

        // Should throw authentication error (from ChaChaPoly)
        #expect(throws: (any Error).self) {
            _ = try XChaCha20Poly1305Compat.open(
                ciphertext: sealed.ciphertext,
                tag: sealed.tag,
                key: wrongKey,
                nonce24: nonce
            )
        }
    }

    @Test func openFailsWithTamperedCiphertext() throws {
        let plaintext = "Secret".data(using: .utf8)!
        let key = Data(repeating: 0x42, count: 32)
        let nonce = Data(repeating: 0x24, count: 24)

        let sealed = try XChaCha20Poly1305Compat.seal(plaintext: plaintext, key: key, nonce24: nonce)

        // Tamper with ciphertext
        var tampered = sealed.ciphertext
        if !tampered.isEmpty {
            tampered[0] ^= 0xFF
        }

        // Should throw authentication error
        #expect(throws: (any Error).self) {
            _ = try XChaCha20Poly1305Compat.open(
                ciphertext: tampered,
                tag: sealed.tag,
                key: key,
                nonce24: nonce
            )
        }
    }
}
