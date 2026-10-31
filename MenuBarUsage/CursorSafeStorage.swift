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

    static func resetForTests() {
        cachedKey = nil
        CursorSafeStorageKeychain.resetForTests()
    }

    /// Keychain identities for the Cursor install that owns `state.vscdb`.
    /// Current Electron uses the account `"<App> Key"`. Older builds used the
    /// app name alone. Insiders and Nightly keep their own item and fall
    /// back to the stable name when that item is the one Cursor actually wrote.
    static func identities(forDatabase url: URL) -> [SafeStorageIdentity] {
        let path = url.path
        let names: [String]
        if path.contains("/Cursor Nightly/") {
            names = ["Cursor Nightly", "Cursor"]
        } else if path.contains("/Cursor - Insiders/") {
            names = ["Cursor - Insiders", "Cursor Insiders", "Cursor"]
        } else {
            names = ["Cursor"]
        }
        var seen = Set<String>()
        var identities: [SafeStorageIdentity] = []
        for name in names {
            for account in ["\(name) Key", name] {
                let identity = SafeStorageIdentity(service: "\(name) Safe Storage", account: account)
                let key = "\(identity.service)\n\(identity.account)"
                if seen.insert(key).inserted {
                    identities.append(identity)
                }
            }
        }
        return identities
    }

    static func decrypt(sealed: String, password: Data) -> String? {
        guard sealed.hasPrefix(sealedPrefix) else { return nil }
        let encoded = String(sealed.dropFirst(sealedPrefix.count))
        guard let blob = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else { return nil }
        guard let key = deriveKey(password: password) else { return nil }
        return decrypt(blob: blob, key: key)
    }

    /// Opens a sealed cell. `cache` keeps the derived AES key in memory so a
    /// later refresh does not raise another Keychain dialog. The JWT itself
    /// is not cached. A test passes `cache: false` and its own `secrets`.
    static func unseal(
        _ stored: String,
        database: URL,
        secrets: (String, String) -> SafeStorageSecret,
        cache: Bool
    ) -> SafeStorageUnseal {
        let result = unsealNow(stored, database: database, secrets: secrets, cache: cache)
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
        database: URL,
        secrets: (String, String) -> SafeStorageSecret,
        cache: Bool
    ) -> SafeStorageUnseal {
        guard stored.hasPrefix(sealedPrefix) else { return .failed }
        let encoded = String(stored.dropFirst(sealedPrefix.count))
        guard let blob = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), isElectronEnvelope(blob) else {
            return .failed
        }

        if cache, let cachedKey, let plain = jwt(blob, key: cachedKey) {
            return .opened(plain)
        }
        if cache {
            cachedKey = nil
        }

        var needsConsent = false
        for identity in identities(forDatabase: database) {
            switch secrets(identity.service, identity.account) {
            case let .secret(password):
                guard let key = deriveKey(password: password), let plain = jwt(blob, key: key) else { continue }
                if cache {
                    cachedKey = key
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

/// Reads Cursor's existing Safe Storage password. Never creates a keychain item.
///
/// The first lookup skips the authentication dialog so a missing account name
/// and a background refresh stay quiet. The dialog is the second lookup, and
/// only while the panel is open or the user clicked Refresh or Open Cursor.
/// One pass prompts at most once. A denial or a prompt that still does not
/// open the blob stays quiet until the next explicit request.
enum CursorSafeStorageKeychain {
    static var interactive = false

    private static var suppressPrompt = false
    private static var promptedThisPass = false
    private static var didPromptThisPass = false

    static func allowPrompt() {
        suppressPrompt = false
    }

    static func beginPass() {
        promptedThisPass = false
        didPromptThisPass = false
    }

    static func notePromptDidNotUnlock() {
        if didPromptThisPass {
            suppressPrompt = true
        }
    }

    static func resetForTests() {
        interactive = false
        suppressPrompt = false
        promptedThisPass = false
        didPromptThisPass = false
    }

    static func secret(service: String, account: String) -> SafeStorageSecret {
        switch read(service: service, account: account, prompt: false) {
        case let .secret(data):
            return .secret(data)
        case .missing:
            return .missing
        case .needsConsent:
            let mayPrompt = interactive && !suppressPrompt && !promptedThisPass
            guard mayPrompt else { return .needsConsent }
            promptedThisPass = true
            didPromptThisPass = true
            return read(service: service, account: account, prompt: true)
        }
    }

    private static func read(service: String, account: String, prompt: Bool) -> SafeStorageSecret {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !prompt {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }
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
