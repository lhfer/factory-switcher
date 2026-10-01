import Foundation
import Security

public protocol KeyStore: AnyObject {
    func read(service: String, account: String) throws -> Data?
    func write(_ value: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

public enum KeychainNames {
    public static let factoryService = "Factory CLI"
    public static let factoryAccount = "auth-encryption-key-security-cli"
    public static let switcherService = "local.FactorySwitcher.keys"
}

public final class MacKeychain: KeyStore {
    public init() {}

    public func read(service: String, account: String) throws -> Data? {
        var query = queryFor(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else {
            throw SwitcherError.message("钥匙串返回的数据格式无效。")
        }
        return data
    }

    public func write(_ value: Data, service: String, account: String) throws {
        let query = queryFor(service: service, account: account)
        let attributes = [kSecValueData as String: value]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = value
            add[kSecAttrLabel as String] = "Factory Switcher 本地账号密钥"
            add[kSecAttrSynchronizable as String] = false
            try check(SecItemAdd(add as CFDictionary, nil))
        } else {
            try check(status)
        }
        guard try read(service: service, account: account) == value else {
            throw SwitcherError.message("钥匙串写入校验失败，操作已停止。")
        }
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(queryFor(service: service, account: account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func queryFor(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecInteractionNotAllowed {
                throw SwitcherError.message("钥匙串访问未获允许。请解锁登录钥匙串并在系统提示中允许访问。")
            }
            throw SwitcherError.message("钥匙串操作失败（状态 \(status)）。")
        }
    }
}

public final class AuthReader {
    private let keys: KeyStore

    public init(keys: KeyStore) { self.keys = keys }

    public func load(home: URL) throws -> AuthMaterial? {
        try SafeFiles.rejectSymlinks(home)
        let secure = home.appendingPathComponent(AuthFormat.loginKeychain.filename)
        if try SafeFiles.exists(secure) {
            guard let raw = try keys.read(service: KeychainNames.factoryService, account: KeychainNames.factoryAccount),
                  let text = String(data: raw, encoding: .utf8),
                  let key = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  key.count == 32 else {
                throw SwitcherError.message("找不到当前登录使用的钥匙串密钥，请通过 Factory 重新登录。")
            }
            let encrypted = try readCiphertext(secure)
            return try AuthMaterial(format: .loginKeychain, encrypted: encrypted, key: key)
        }
        let file = home.appendingPathComponent(AuthFormat.keyfile.filename)
        if try SafeFiles.exists(file) {
            let keyFile = try SafeFiles.read(home.appendingPathComponent("auth.v2.key"), maximumBytes: 256)
            guard let text = String(data: keyFile, encoding: .utf8),
                  let key = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  key.count == 32 else {
                throw SwitcherError.message("文件式登录缺少匹配的密钥。")
            }
            return try AuthMaterial(format: .keyfile, encrypted: readCiphertext(file), key: key)
        }
        if try SafeFiles.exists(home.appendingPathComponent("auth.v2.keyring")) {
            throw SwitcherError.message("这版工具仅支持当前 Mac 登录钥匙串格式和文件式登录，请通过 Factory 自带的 Droid 登录。")
        }
        return nil
    }

    private func readCiphertext(_ url: URL) throws -> String {
        guard let text = String(data: try SafeFiles.read(url, maximumBytes: 1024 * 1024), encoding: .utf8) else {
            throw SwitcherError.message("加密登录文件不是有效文本。")
        }
        return text
    }
}
