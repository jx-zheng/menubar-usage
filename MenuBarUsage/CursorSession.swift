import Foundation
import SQLite3

enum AuthFailure: Error, Equatable {
    case missing
    case expired
    case encrypted
    case unreadable
    case rejected

    var message: String {
        switch self {
        case .missing:
            return "Cursor is not signed in on this Mac."
        case .expired:
            return "The Cursor session on this Mac has expired. Open Cursor and sign in again."
        case .encrypted:
            return "Cursor saved an encrypted session this app does not unlock. Open Cursor, or paste a session token."
        case .unreadable:
            return "Cursor's session database could not be read."
        case .rejected:
            return "Cursor rejected this session. Open Cursor and sign in again, or paste a new token."
        }
    }

    var dumpLabel: String {
        switch self {
        case .missing: return "missing"
        case .expired: return "expired"
        case .encrypted: return "encrypted"
        case .unreadable: return "unreadable"
        case .rejected: return "rejected"
        }
    }
}

enum SessionSource: String, Equatable {
    case keychain
    case cursorDatabase

    var label: String {
        switch self {
        case .keychain: return "Keychain"
        case .cursorDatabase: return "Cursor"
        }
    }
}

struct SessionCredential: Equatable {
    var cookie: String
    var source: SessionSource
}

enum JWTClaims {
    struct Payload {
        var subject: String
        var expiresAt: Date?
        var userId: String?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow < 60
        }
    }

    static func decode(_ jwt: String) -> Payload? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let data = base64URLDecode(String(parts[1])) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let subject = json["sub"] as? String, !subject.isEmpty else { return nil }
        let expires: Date?
        if let exp = json["exp"] as? TimeInterval {
            expires = Date(timeIntervalSince1970: exp)
        } else if let exp = json["exp"] as? Int {
            expires = Date(timeIntervalSince1970: TimeInterval(exp))
        } else if let exp = json["exp"] as? String, let number = TimeInterval(exp) {
            expires = Date(timeIntervalSince1970: number)
        } else {
            expires = nil
        }
        let tail = subject.split(separator: "|").last.map(String.init) ?? subject
        let userId = tail.contains("user_") ? tail : nil
        return Payload(subject: subject, expiresAt: expires, userId: userId)
    }

    private static func base64URLDecode(_ text: String) -> Data? {
        var encoded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder > 0 {
            encoded.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: encoded)
    }
}

enum SessionCookie {
    /// Cookie value for `WorkosCursorSessionToken`, with the separator percent-encoded.
    static func value(fromJWT jwt: String) -> String? {
        let trimmed = jwt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let claims = JWTClaims.decode(trimmed), let userId = claims.userId, !claims.isExpired else {
            return nil
        }
        return "\(userId)%3A%3A\(trimmed)"
    }

    static func normalizePasted(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        let prefix = "WorkosCursorSessionToken="
        if value.lowercased().hasPrefix(prefix.lowercased()) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = value.range(of: "%3A%3A", options: .caseInsensitive) {
            value.replaceSubrange(range, with: "::")
        }
        if let range = value.range(of: "::") {
            let user = String(value[..<range.lowerBound])
            let token = String(value[range.upperBound...])
            guard user.contains("user_"), token.split(separator: ".").count >= 3 else { return nil }
            if JWTClaims.decode(token)?.isExpired == true { return nil }
            return "\(user)%3A%3A\(token)"
        }
        return Self.value(fromJWT: value)
    }
}

enum KeychainTokenStore {
    static let service = "com.jxzheng.menubar-usage.session"
    static let account = "WorkosCursorSessionToken"

    private static var hasCache = false
    private static var cached: String?

    static func read() -> String? {
        if hasCache { return cached }
        cached = readKeychain()
        hasCache = true
        return cached
    }

    /// Drops the in-memory copy so the next read hits the Keychain.
    /// Used on launch misses, rejection, and when the JWT is near expiry.
    static func invalidateCache() {
        hasCache = false
        cached = nil
    }

    static func save(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess {
            cached = value
            hasCache = true
            return true
        }
        guard update == errSecItemNotFound else {
            invalidateCache()
            return false
        }
        var insert = query
        attributes.forEach { insert[$0.key] = $0.value }
        let saved = SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        if saved {
            cached = value
            hasCache = true
        } else {
            invalidateCache()
        }
        return saved
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        cached = nil
        hasCache = true
    }

    private static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}

enum SessionCredentialFreshness {
    /// Re-read the Keychain and Cursor's database this long before `exp`.
    static let leadTime: TimeInterval = 5 * 60

    static func isNearExpiry(_ cookie: String, now: Date = Date(), lead: TimeInterval = leadTime) -> Bool {
        guard let expires = expiration(of: cookie) else { return false }
        return expires.timeIntervalSince(now) <= lead
    }

    static func expiration(of cookie: String) -> Date? {
        let jwt: String
        if let range = cookie.range(of: "%3A%3A", options: .caseInsensitive) {
            jwt = String(cookie[range.upperBound...])
        } else if let range = cookie.range(of: "::") {
            jwt = String(cookie[range.upperBound...])
        } else {
            jwt = cookie
        }
        return JWTClaims.decode(jwt)?.expiresAt
    }
}

enum CursorDatabase {
    enum Outcome: Equatable {
        case token(String)
        case expired
        case encrypted
        case missing
        case unreadable
    }

    static func load(fileManager: FileManager = .default, home: URL? = nil) -> Outcome {
        let base = home ?? fileManager.homeDirectoryForCurrentUser
        let names = ["Cursor", "Cursor - Insiders", "Cursor Nightly"]
        let candidates = names.map {
            base.appendingPathComponent("Library/Application Support/\($0)/User/globalStorage/state.vscdb")
        }
        var sawExpired = false
        var sawEncrypted = false
        var sawUnreadable = false
        var sawFile = false
        for url in candidates {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            sawFile = true
            switch readToken(at: url) {
            case let .token(value):
                if SessionCookie.value(fromJWT: value) != nil {
                    return .token(value)
                }
                sawExpired = true
            case .expired:
                sawExpired = true
            case .encrypted:
                sawEncrypted = true
            case .missing:
                continue
            case .unreadable:
                sawUnreadable = true
            }
        }
        if sawExpired { return .expired }
        if sawEncrypted { return .encrypted }
        if sawUnreadable { return .unreadable }
        if sawFile { return .missing }
        return .missing
    }

    static func readToken(at url: URL) -> Outcome {
        var database: OpaquePointer?
        guard let uri = uri(for: url) else { return .unreadable }
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &database, flags, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return .unreadable
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 300)

        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .unreadable
        }
        defer { sqlite3_finalize(statement) }

        let key = "cursorAuth/accessToken"
        let outcome: Outcome = key.withCString { pointer in
            guard sqlite3_bind_text(statement, 1, pointer, -1, nil) == SQLITE_OK else { return .unreadable }
            let step = sqlite3_step(statement)
            guard step == SQLITE_ROW else {
                return step == SQLITE_DONE ? .missing : .unreadable
            }
            guard let raw = sqlite3_column_text(statement, 0) else { return .missing }
            return tokenOutcome(String(cString: raw))
        }
        return outcome
    }

    private static func tokenOutcome(_ raw: String) -> Outcome {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty else { return .missing }
        if value.hasPrefix("cursor-safe-storage:") { return .encrypted }
        if JWTClaims.decode(value) == nil { return .unreadable }
        if JWTClaims.decode(value)?.isExpired == true { return .expired }
        return .token(value)
    }

    private static func uri(for url: URL) -> String? {
        var components = URLComponents()
        components.scheme = "file"
        components.path = url.path
        components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        return components.string
    }
}

enum SessionResolver {
    static func keychainCredential() -> SessionCredential? {
        guard let stored = KeychainTokenStore.read(), let cookie = SessionCookie.normalizePasted(stored) else {
            return nil
        }
        return SessionCredential(cookie: cookie, source: .keychain)
    }

    static func databaseCredential(home: URL? = nil) -> Result<SessionCredential, AuthFailure> {
        switch CursorDatabase.load(home: home) {
        case let .token(jwt):
            guard let cookie = SessionCookie.value(fromJWT: jwt) else { return .failure(.expired) }
            return .success(SessionCredential(cookie: cookie, source: .cursorDatabase))
        case .expired:
            return .failure(.expired)
        case .encrypted:
            return .failure(.encrypted)
        case .unreadable:
            return .failure(.unreadable)
        case .missing:
            return .failure(.missing)
        }
    }

    static func resolve(allowKeychain: Bool = true, home: URL? = nil) -> Result<SessionCredential, AuthFailure> {
        if allowKeychain, let pasted = keychainCredential() {
            return .success(pasted)
        }
        return databaseCredential(home: home)
    }
}
