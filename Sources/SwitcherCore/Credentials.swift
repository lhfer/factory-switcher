import CryptoKit
import Foundation
import Security

public struct Credentials: Sendable {
    public private(set) var fields: [String: JSONValue]

    public init(data: Data) throws {
        guard let fields = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              let access = fields["access_token"]?.string, !access.isEmpty,
              let refresh = fields["refresh_token"]?.string, !refresh.isEmpty else {
            throw SwitcherError.message("登录信息格式不受支持，请通过官方 Droid 重新登录。")
        }
        self.fields = fields
    }

    public var accessToken: String { fields["access_token"]!.string! }
    public var refreshToken: String { fields["refresh_token"]!.string! }
    public var activeOrganizationID: String? { nonempty(fields["active_organization_id"]?.string) }

    public func identity() throws -> AccountIdentity {
        // JWT claims are display hints only, never an authorization decision.
        let claims = Self.claims(accessToken)
        guard let userID = nonempty(claims?["sub"]?.string) else {
            throw SwitcherError.message("无法识别这个登录的账号，请重新登录。")
        }
        let org = activeOrganizationID
            ?? nonempty(claims?["external_org_id"]?.string)
            ?? nonempty(claims?["org_id"]?.string)
        return AccountIdentity(userID: userID, email: nonempty(claims?["email"]?.string), organizationID: org)
    }

    public func isExpired(now: Date = Date(), skew: TimeInterval = 60) -> Bool {
        guard let expiry = Self.claims(accessToken)?["exp"]?.number, expiry.isFinite else { return true }
        return now.timeIntervalSince1970 + skew >= expiry
    }

    public mutating func replaceTokens(access: String, refresh: String) throws {
        guard !access.isEmpty, !refresh.isEmpty else {
            throw SwitcherError.message("登录续期响应不完整，请稍后重试。")
        }
        fields["access_token"] = .string(access)
        fields["refresh_token"] = .string(refresh)
    }

    public func encoded() throws -> Data { try SafeFiles.encode(fields) }

    private static func claims(_ token: String) -> [String: JSONValue]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1].count < 128 * 1024 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { return nil }
        return try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

public enum AuthCrypto {
    public static func decrypt(_ encrypted: String, key: Data) throws -> Data {
        let parts = encrypted.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard key.count == 32, parts.count == 3,
              let iv = Data(base64Encoded: String(parts[0])), iv.count == 16,
              let tag = Data(base64Encoded: String(parts[1])), tag.count == 16,
              let ciphertext = Data(base64Encoded: String(parts[2])) else {
            throw SwitcherError.message("加密登录文件格式不受支持。")
        }
        do {
            let nonce = try AES.GCM.Nonce(data: iv)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: SymmetricKey(data: key))
        } catch {
            throw SwitcherError.message("无法验证登录文件，钥匙串密钥可能已更改。请重新保存或登录该账号。")
        }
    }

    public static func encrypt(_ plaintext: Data, key: Data) throws -> String {
        guard key.count == 32 else { throw SwitcherError.message("登录密钥长度无效。") }
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SwitcherError.message("无法生成安全随机数。")
        }
        let nonce = try AES.GCM.Nonce(data: bytes)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce)
        return [
            Data(bytes).base64EncodedString(),
            sealed.tag.base64EncodedString(),
            sealed.ciphertext.base64EncodedString(),
        ].joined(separator: ":")
    }
}

public struct AuthMaterial: Sendable {
    public let format: AuthFormat
    public let encrypted: String
    public let key: Data
    public let credentials: Credentials

    public init(format: AuthFormat, encrypted: String, key: Data) throws {
        self.format = format
        self.encrypted = encrypted
        self.key = key
        credentials = try Credentials(data: AuthCrypto.decrypt(encrypted, key: key))
    }

    public func replacing(_ credentials: Credentials) throws -> AuthMaterial {
        try AuthMaterial(format: format, encrypted: AuthCrypto.encrypt(credentials.encoded(), key: key), key: key)
    }
}
