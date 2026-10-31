import CommonCrypto
import Foundation
import Security

/// One login-Keychain item that can unwrap Electron `safeStorage` on this Mac.
struct SafeStorageIdentity: Equatable {
    var service: String
    var account: String
}

/// Result of asking the Keychain for a Safe Storage password.
enum SafeStorageSecret: Equatable {
    case secret(Data)
    case missing
    case needsConsent
}

/// Cursor 3.27+ writes `cursorAuth/accessToken` as `cursor-safe-storage:v1:`
/// plus the base64 of Electron `safeStorage.encryptString`. On macOS that
/// ciphertext is Chromium OSCrypt: `v10` (or `v11`) followed by AES-128-CBC.
/// The key is not inside the database. It is derived from the password Cursor
/// already keeps in the login Keychain.
enum CursorSafeStorage {
    static let sealedPrefix = "cursor-safe-storage:v1:"

    private static var cachedKey: Data?

    /// Stable Cursor only. Current Electron uses account `Cursor Key`; older builds used `Cursor`.
    static let identities = [
        SafeStorageIdentity(service: "Cursor Safe Storage", account: "Cursor Key"),
        SafeStorageIdentity(service: "Cursor Safe Storage", account: "Cursor")
    ]

    /// Opens a sealed cell. `cache` keeps the derived AES key in memory so a
    /// later refresh does not raise another Keychain dialog. The JWT itself
    /// is not cached. A test passes `cache: false` and its own `secrets`.
    static func unseal(
        _ stored: String,
        secrets: (String, String) -> SafeStorageSecret,
        cache: Bool
    ) -> SafeStorageUnseal {
        let result = unsealNow(stored, secrets: secrets, cache: cache)
        if cache, case .opened = result {
            return result
        }
        if cache {
            CursorSafeStorageKeychain.notePromptDidNotUnlock()
        }
        return result
    }

    private static func unsealNow(
        _ stored: String,
        secrets: (String, String) -> SafeStorageSecret,
        cache: Bool
    ) -> SafeStorageUnseal {
        guard stored.hasPrefix(sealedPrefix) else { return .failed }
        let encoded = String(stored.dropFirst(sealedPrefix.count))
        guard let blob = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), isElectronEnvelope(blob) else {
            return .failed
        }

        if cache, let key = SafeStorageGate.withLock({ cachedKey }), let plain = jwt(blob, key: key) {
            return .opened(plain)
        }
        if cache {
            SafeStorageGate.withLock { cachedKey = nil }
        }

        var needsConsent = false
        for identity in identities {
            switch secrets(identity.service, identity.account) {
            case let .secret(password):
                guard let key = deriveKey(password: password), let plain = jwt(blob, key: key) else { continue }
                if cache {
                    SafeStorageGate.withLock { cachedKey = key }
                }
                return .opened(plain)
            case .missing:
                continue
            case .needsConsent:
                needsConsent = true
            }
        }
        return needsConsent ? .needsConsent : .failed
    }

    /// PBKDF2-HMAC-SHA1, salt `saltysalt`, 1003 rounds, 16-byte AES key.
    /// The password is the raw Keychain bytes. It is not a UTF-8 string.
    static func deriveKey(password: Data) -> Data? {
        guard !password.isEmpty else { return nil }
        let salt = Array("saltysalt".utf8)
        var key = Data(count: kCCKeySizeAES128)
        let status: CCCryptorStatus = password.withUnsafeBytes { secret in
            salt.withUnsafeBytes { saltBytes -> CCCryptorStatus in
                key.withUnsafeMutableBytes { out -> CCCryptorStatus in
                    guard let secretBase = secret.baseAddress,
                          let saltBase = saltBytes.baseAddress,
                          let outBase = out.baseAddress else {
                        return kCCParamError
                    }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        secretBase.assumingMemoryBound(to: CChar.self),
                        secret.count,
                        saltBase.assumingMemoryBound(to: UInt8.self),
                        saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        UInt32(1003),
                        outBase.assumingMemoryBound(to: UInt8.self),
                        out.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return key
    }

    /// AES-128-CBC, IV of 16 spaces, PKCS#7. Returns nil when the padding
    /// does not check out, which is what a wrong Safe Storage password does.
    static func decrypt(blob: Data, key: Data) -> String? {
        guard key.count == kCCKeySizeAES128, isElectronEnvelope(blob) else { return nil }
        let ciphertext = Data(blob.dropFirst(3))
        var output = Data(count: ciphertext.count)
        var written = 0
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        let status = output.withUnsafeMutableBytes { outputRaw in
            ciphertext.withUnsafeBytes { cipherRaw in
                key.withUnsafeBytes { keyRaw in
                    iv.withUnsafeBytes { ivRaw in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyRaw.baseAddress, key.count,
                            ivRaw.baseAddress,
                            cipherRaw.baseAddress, ciphertext.count,
                            outputRaw.baseAddress, outputRaw.count,
                            &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, written > 0, written <= output.count else { return nil }
        guard let text = String(data: output.prefix(written), encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func jwt(_ blob: Data, key: Data) -> String? {
        guard let text = decrypt(blob: blob, key: key), JWTClaims.decode(text) != nil else { return nil }
        return text
    }

    private static func isElectronEnvelope(_ blob: Data) -> Bool {
        guard blob.count >= 3 + kCCBlockSizeAES128 else { return false }
        let prefix = blob.prefix(3)
        guard prefix == Data("v10".utf8) || prefix == Data("v11".utf8) else { return false }
        return (blob.count - 3).isMultiple(of: kCCBlockSizeAES128)
    }
}

enum SafeStorageUnseal: Equatable {
    case opened(String)
    case needsConsent
    case failed
}

/// Serializes prompt flags and the cached AES key. The lock is never held across
/// `SecItemCopyMatching`: the interactive call blocks until the user answers.
enum SafeStorageGate {
    private static let lock = NSLock()

    static func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Reads Cursor's existing Safe Storage password. Never creates a keychain item.
///
/// A quiet read disables user interaction for that call. `Cursor Safe Storage`
/// is a legacy login-Keychain item, and `kSecUseAuthenticationUISkip` reports
/// that ACL as "not found" or still raises SecurityAgent. Interaction-blocked
/// statuses stay `.needsConsent`, so a later interactive read can ask.
/// The dialog runs only when `interactive && !suppressPrompt`, and not while
/// this lock is held.
enum CursorSafeStorageKeychain {
    private static var interactive = false
    private static var suppressPrompt = false
    private static var promptedThisPass = false
    private static var didPromptThisPass = false

    static func setInteractive(_ value: Bool) {
        SafeStorageGate.withLock { interactive = value }
    }

    static func allowPrompt() {
        SafeStorageGate.withLock { suppressPrompt = false }
    }

    static func beginPass() {
        SafeStorageGate.withLock {
            promptedThisPass = false
            didPromptThisPass = false
        }
    }

    static func notePromptDidNotUnlock() {
        SafeStorageGate.withLock {
            if didPromptThisPass {
                suppressPrompt = true
            }
        }
    }

    static func secret(service: String, account: String) -> SafeStorageSecret {
        switch read(service: service, account: account, prompt: false) {
        case let .secret(data):
            return .secret(data)
        case .missing:
            return .missing
        case .needsConsent:
            let mayPrompt = SafeStorageGate.withLock { () -> Bool in
                let allowed = interactive && !suppressPrompt && !promptedThisPass
                if allowed {
                    promptedThisPass = true
                    didPromptThisPass = true
                }
                return allowed
            }
            guard mayPrompt else { return .needsConsent }
            return read(service: service, account: account, prompt: true)
        }
    }

    private static func read(service: String, account: String, prompt: Bool) -> SafeStorageSecret {
        if prompt {
            return copyMatching(service: service, account: account)
        }
        var allowed = DarwinBoolean(true)
        SecKeychainGetUserInteractionAllowed(&allowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return copyMatching(service: service, account: account)
    }

    private static func copyMatching(service: String, account: String) -> SafeStorageSecret {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, !data.isEmpty else { return .missing }
            return .secret(data)
        case errSecItemNotFound:
            return .missing
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .needsConsent
        default:
            return .missing
        }
    }
}
