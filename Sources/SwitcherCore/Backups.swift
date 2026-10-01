import CryptoKit
import Foundation

public struct BackupManifest: Codable, Sendable {
    public let version: Int
    public let id: String
    public let createdAt: Date
    public let previousState: StoreState
    public let targetAccountID: String?
    public let authFiles: [String: String]
    public let fileKeyReference: String?
    public let systemKeyReference: String?
    public let sessions: [SessionEdit]
    public let indexDigest: String?
}

struct TransactionRecord: Codable {
    let backupID: String
    var committed: Bool
}

public final class Backups {
    private let store: AccountStore
    public init(store: AccountStore) { self.store = store }

    public func directory(_ id: String) throws -> URL {
        try SwitcherPaths.validateID(id)
        return store.paths.backups.appendingPathComponent(id, isDirectory: true)
    }

    public func prepare(state: StoreState, targetAccountID: String?) throws -> BackupManifest {
        let id = UUID().uuidString.lowercased()
        let root = try directory(id)
        try SafeFiles.ensureDirectory(root)
        var files: [String: String] = [:]
        var fileKeyReference: String?
        for name in AuthFormat.managedFilenames {
            let source = store.paths.factory.appendingPathComponent(name)
            guard try SafeFiles.exists(source) else { continue }
            let data = try SafeFiles.read(source, maximumBytes: 1024 * 1024)
            if name == "auth.v2.key" {
                fileKeyReference = try rememberKey(data)
            } else {
                try SafeFiles.atomicWrite(data, to: root.appendingPathComponent("auth").appendingPathComponent(name))
                files[name] = digest(data)
            }
        }
        var systemKeyReference: String?
        if let key = try store.keys.read(service: KeychainNames.factoryService, account: KeychainNames.factoryAccount) {
            systemKeyReference = try rememberKey(key)
        }
        let sessions = state.preferences.shareSessions ? try SessionFiles.prepare(
            root: store.paths.sessions, selectedIDs: Set(state.preferences.selectedSessionIDs),
            backup: root.appendingPathComponent("sessions", isDirectory: true)
        ) : []
        let index = store.paths.factory.appendingPathComponent("sessions-index.json")
        var indexDigest: String?
        if !sessions.isEmpty, try SafeFiles.exists(index) {
            let data = try SafeFiles.read(index, maximumBytes: 64 * 1024 * 1024)
            try SafeFiles.atomicWrite(data, to: root.appendingPathComponent("sessions-index.json"))
            indexDigest = digest(data)
        }
        let manifest = BackupManifest(
            version: 1, id: id, createdAt: Date(), previousState: state, targetAccountID: targetAccountID,
            authFiles: files, fileKeyReference: fileKeyReference,
            systemKeyReference: systemKeyReference, sessions: sessions, indexDigest: indexDigest
        )
        try SafeFiles.atomicWrite(SafeFiles.encode(manifest), to: root.appendingPathComponent("manifest.json"))
        _ = try read(id)
        return manifest
    }

    private func readManifest(_ id: String) throws -> BackupManifest {
        let manifest = try SafeFiles.decode(
            BackupManifest.self, from: SafeFiles.read(try directory(id).appendingPathComponent("manifest.json"))
        )
        guard manifest.version == 1, manifest.id == id else {
            throw SwitcherError.message("备份版本或标识不受支持。")
        }
        try manifest.previousState.validate()
        for reference in [manifest.fileKeyReference, manifest.systemKeyReference].compactMap({ $0 }) {
            try SwitcherPaths.validateID(reference)
        }
        return manifest
    }

    public func read(_ id: String) throws -> BackupManifest {
        let manifest = try readManifest(id)
        for (name, hash) in manifest.authFiles {
            guard AuthFormat.managedFilenames.contains(name), name != "auth.v2.key",
                  digest(try SafeFiles.read(try directory(id).appendingPathComponent("auth").appendingPathComponent(name))) == hash else {
                throw SwitcherError.message("登录备份校验失败，不会用它覆盖当前登录。")
            }
        }
        for reference in [manifest.fileKeyReference, manifest.systemKeyReference].compactMap({ $0 }) {
            guard try store.keys.read(service: KeychainNames.switcherService, account: reference) != nil else {
                throw SwitcherError.message("备份对应的钥匙串密钥不可用。")
            }
        }
        // Verify the key/ciphertext pair before replacing any live file.
        for (format, reference) in [
            (AuthFormat.loginKeychain, manifest.systemKeyReference),
            (AuthFormat.keyfile, manifest.fileKeyReference),
        ] {
            guard manifest.authFiles[format.filename] != nil else { continue }
            guard let reference,
                  let text = String(data: try requiredKey(reference), encoding: .utf8),
                  let key = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let encrypted = String(data: try SafeFiles.read(
                    try directory(id).appendingPathComponent("auth").appendingPathComponent(format.filename)
                  ), encoding: .utf8) else {
                throw SwitcherError.message("登录备份缺少有效的匹配密钥。")
            }
            _ = try AuthMaterial(format: format, encrypted: encrypted, key: key)
        }
        return manifest
    }

    public func list() throws -> [BackupManifest] {
        guard try SafeFiles.exists(store.paths.backups) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: store.paths.backups, includingPropertiesForKeys: nil)
            .compactMap { url in
                guard UUID(uuidString: url.lastPathComponent) != nil else { return nil }
                // Listing history must not query every historical secret or
                // prompt for Keychain access. Full validation happens on use.
                return try? readManifest(url.lastPathComponent)
            }.sorted { $0.createdAt > $1.createdAt }
    }

    public func restoreAuth(_ manifest: BackupManifest) throws {
        let verified = try read(manifest.id)
        if let reference = verified.systemKeyReference {
            let key = try requiredKey(reference)
            if try store.keys.read(service: KeychainNames.factoryService, account: KeychainNames.factoryAccount) != key {
                try store.keys.write(key, service: KeychainNames.factoryService, account: KeychainNames.factoryAccount)
            }
        } else {
            try store.keys.delete(service: KeychainNames.factoryService, account: KeychainNames.factoryAccount)
        }
        let root = try directory(manifest.id)
        for name in AuthFormat.managedFilenames {
            let destination = store.paths.factory.appendingPathComponent(name)
            if name == "auth.v2.key", let reference = verified.fileKeyReference {
                try SafeFiles.atomicWrite(requiredKey(reference), to: destination)
            } else if verified.authFiles[name] != nil {
                try SafeFiles.atomicWrite(
                    SafeFiles.read(root.appendingPathComponent("auth").appendingPathComponent(name)),
                    to: destination
                )
            } else {
                try SafeFiles.remove(destination)
            }
        }
    }

    public func restoreSessions(_ manifest: BackupManifest) throws {
        try SessionFiles.restore(
            manifest.sessions, root: store.paths.sessions,
            backup: try directory(manifest.id).appendingPathComponent("sessions", isDirectory: true)
        )
        if !manifest.sessions.isEmpty {
            // Let Droid rebuild the derived index; never restore an old index
            // over newer conversation messages or sessions.
            try SafeFiles.remove(store.paths.factory.appendingPathComponent("sessions-index.json"))
        }
    }

    private func rememberKey(_ data: Data) throws -> String {
        let reference = UUID().uuidString.lowercased()
        try store.keys.write(data, service: KeychainNames.switcherService, account: reference)
        return reference
    }

    private func requiredKey(_ reference: String) throws -> Data {
        guard let key = try store.keys.read(service: KeychainNames.switcherService, account: reference) else {
            throw SwitcherError.message("备份密钥不可用。")
        }
        return key
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
