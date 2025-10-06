//
// PreviewKeychainManager.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

final class PreviewKeychainManager: KeychainManagerProtocol {
    private var storage: [String: Data] = [:]
    init() {}
    
    func saveIdentityKey(_ keyData: Data, forKey key: String) -> Bool {
        storage[key] = keyData
        return true
    }
    
    func getIdentityKey(forKey key: String) -> Data? {
        storage[key]
    }
    
    func deleteIdentityKey(forKey key: String) -> Bool {
        storage.removeValue(forKey: key)
        return true
    }
    
    func deleteAllKeychainData() -> Bool {
        storage.removeAll()
        return true
    }
    
    func secureClear(_ data: inout Data) {}
    
    func secureClear(_ string: inout String) {}
    
    func verifyIdentityKeyExists() -> Bool {
        storage["identity_noiseStaticKey"] != nil
    }
}
