// KeychainService.swift
// ClinicalAI — Secure API Key Storage
//
// Stores and retrieves the Anthropic API key from the iOS Keychain.
// The Keychain is the correct place for secrets on iOS — it is encrypted by the OS,
// survives app updates, and (with kSecAttrAccessibleWhenUnlockedThisDeviceOnly) cannot
// be transferred to another device via backup.
//
// Why the Keychain and not UserDefaults?
// UserDefaults is stored in a plain-text plist that any tool with device access can read.
// The Keychain is encrypted and protected by the device passcode / Secure Enclave.
// HIPAA requires protecting patient data and the API key that processes it.
//
// Usage (from anywhere in the app):
//   try KeychainService.shared.saveAPIKey("sk-ant-...")
//   let key = try KeychainService.shared.loadAPIKey()
//   KeychainService.shared.hasAPIKey()   ← safe to call, never throws

import Foundation
import Security

// MARK: - KeychainError

/// Errors that can occur during Keychain read/write operations.
///
/// Each case wraps the underlying `OSStatus` code from the Security framework
/// so you can look up the exact failure reason in Apple's documentation if needed.
enum KeychainError: LocalizedError {
    /// Saving a new item to the Keychain failed.
    case saveFailed(OSStatus)
    /// The requested item does not exist or could not be read.
    case loadFailed(OSStatus)
    /// Deleting an existing item failed (other than "item not found", which is not an error).
    case deleteFailed(OSStatus)
    /// The key string could not be encoded to UTF-8 data.
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Could not save the API key to the Keychain (OSStatus \(status)). " +
                   "Try deleting the app and re-installing."
        case .loadFailed(let status):
            return "Could not read the API key from the Keychain (OSStatus \(status)). " +
                   "Please re-enter the key in Settings."
        case .deleteFailed(let status):
            return "Could not remove the API key from the Keychain (OSStatus \(status))."
        case .encodingFailed:
            return "The API key contains characters that cannot be stored. " +
                   "Please paste the key directly from the Anthropic console."
        }
    }
}

// MARK: - KeychainService

/// Singleton wrapper around the iOS Keychain for API key storage.
///
/// All methods are synchronous — Keychain operations complete in microseconds and
/// do not need to be async. Call them from any context without risk of blocking the UI.
final class KeychainService {

    /// The shared instance. Use this throughout the app — never create your own instance.
    static let shared = KeychainService()
    private init() {}

    // The Keychain item is identified by the combination of service + account.
    // Using a reverse-domain identifier ensures no collision with other apps on the device.
    private let service = "com.farfelmed.ClinicalAI"
    private let account = "anthropic-api-key"

    // MARK: - Public API

    /// Saves the Anthropic API key to the Keychain, replacing any previously stored value.
    ///
    /// The key is protected with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`:
    ///   - Readable only while the device is unlocked.
    ///   - Not transferred when the user backs up to iCloud or iTunes.
    ///   - Erased when the device is wiped or the app is uninstalled.
    ///
    /// - Parameter key: The Anthropic API key string (typically begins with "sk-ant-").
    /// - Throws: `KeychainError.saveFailed` if the Keychain rejects the write.
    func saveAPIKey(_ key: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        // Always delete first so we can add a fresh item.
        // `SecItemUpdate` is an alternative, but delete-then-add avoids attribute mismatch errors.
        try? deleteAPIKey() // Ignore errors — item may not exist yet.

        let query: [String: Any] = [
            kSecClass as String:                kSecClassGenericPassword,
            kSecAttrService as String:          service,
            kSecAttrAccount as String:          account,
            kSecValueData as String:            data,
            // Readable only while device is unlocked; never transferred off this device.
            kSecAttrAccessible as String:       kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Retrieves the stored Anthropic API key.
    ///
    /// - Returns: The API key string.
    /// - Throws: `KeychainError.loadFailed` if no key is stored or the Keychain is locked.
    func loadAPIKey() throws -> String {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            throw KeychainError.loadFailed(status)
        }
        return key
    }

    /// Removes the stored API key from the Keychain.
    ///
    /// Safe to call even if no key is currently stored — `errSecItemNotFound` is treated
    /// as success because the end state (key absent) is already achieved.
    ///
    /// - Throws: `KeychainError.deleteFailed` only for unexpected failures.
    func deleteAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    /// Returns `true` if an API key has been saved and is non-empty.
    ///
    /// This is the safe way to check for a key — it never throws and never logs the key value.
    /// Use it to decide whether to show the first-run API key setup screen.
    func hasAPIKey() -> Bool {
        (try? loadAPIKey()).map { !$0.isEmpty } ?? false
    }
}
