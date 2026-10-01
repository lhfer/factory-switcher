import Foundation

struct StoredSnapshot: Codable {
    let format: AuthFormat
    let encrypted: String
}

public final class AccountStore {
    public let paths: SwitcherPaths
    public let keys: KeyStore
    public let auth: AuthReader

    public init(paths: SwitcherPaths, keys: KeyStore) {
        self.paths = paths
        self.keys = keys
        auth = AuthReader(keys: keys)
    }

    public func loadState() throws -> StoreState {
        guard try SafeFiles.exists(paths.state) else { return StoreState() }
        guard let state = try? SafeFiles.decode(StoreState.self, from: SafeFiles.read(paths.state)),
              state.version == 1 else {
            throw SwitcherError.message("账号目录状态无法读取。已停止操作，不会覆盖现有数据。")
        }
        try state.validate()
        return state
    }

    public func saveState(_ state: StoreState) throws {
        try state.validate()
        try SafeFiles.atomicWrite(SafeFiles.encode(state), to: paths.state)
    }

    public func load(_ account: Account) throws -> AuthMaterial {
        let snapshot = try SafeFiles.decode(
            StoredSnapshot.self,
            from: SafeFiles.read(snapshotURL(accountID: account.id, snapshotID: account.snapshotID))
        )
        guard let key = try keys.read(service: KeychainNames.switcherService, account: account.keyReference),
              key.count == 32 else {
            throw SwitcherError.message("已保存账号的钥匙串密钥不可用，请重新保存或登录该账号。")
        }
        let material = try AuthMaterial(format: snapshot.format, encrypted: snapshot.encrypted, key: key)
        guard try material.credentials.identity().matches(account) else {
            throw SwitcherError.message("账号文件与菜单记录不匹配，操作已停止。")
        }
        return material
    }

    @discardableResult
    public func importMaterial(
        _ material: AuthMaterial, label: String = "", active: Bool, state: inout StoreState
    ) throws -> Account {
        let identity = try material.credentials.identity()
        let index = state.accounts.firstIndex(where: { identity.matches($0) })
        let id = index.map { state.accounts[$0].id } ?? UUID().uuidString.lowercased()
        // A new immutable snapshot pointer commits only when state.json commits.
        // Old versions remain available to backups and crash recovery.
        var keyRef: String?
        for existing in state.accounts {
            if try keys.read(service: KeychainNames.switcherService, account: existing.keyReference) == material.key {
                keyRef = existing.keyReference
                break
            }
        }
        let reference = keyRef ?? UUID().uuidString.lowercased()
        if keyRef == nil {
            try keys.write(material.key, service: KeychainNames.switcherService, account: reference)
        }
        let snapshotID = UUID().uuidString.lowercased()
        let snapshot = StoredSnapshot(format: material.format, encrypted: material.encrypted)
        try SafeFiles.atomicWrite(
            SafeFiles.encode(snapshot), to: snapshotURL(accountID: id, snapshotID: snapshotID)
        )
        let oldLabel = index.map { state.accounts[$0].label } ?? ""
        let account = Account(
            id: id, label: label.isEmpty ? oldLabel : label,
            email: identity.email, userID: identity.userID, organizationID: identity.organizationID,
            format: material.format, keyReference: reference, snapshotID: snapshotID, updatedAt: Date()
        )
        if let index { state.accounts[index] = account } else { state.accounts.append(account) }
        if active { state.activeAccountID = account.id }
        try saveState(state)
        return account
    }

    @discardableResult
    public func syncLive(state: inout StoreState, importUnknown: Bool = true) throws -> Account? {
        guard let material = try auth.load(home: paths.factory) else {
            if state.activeAccountID != nil {
                state.activeAccountID = nil
                try saveState(state)
            }
            return nil
        }
        let identity = try material.credentials.identity()
        if !importUnknown, !state.accounts.contains(where: { identity.matches($0) }) {
            if state.activeAccountID != nil {
                state.activeAccountID = nil
                try saveState(state)
            }
            return nil
        }
        if let index = state.accounts.firstIndex(where: { identity.matches($0) }),
           let saved = try? load(state.accounts[index]),
           saved.format == material.format, saved.encrypted == material.encrypted, saved.key == material.key {
            if state.activeAccountID != state.accounts[index].id {
                state.activeAccountID = state.accounts[index].id
                try saveState(state)
            }
            return state.accounts[index]
        }
        return try importMaterial(material, active: true, state: &state)
    }

    public func snapshotURL(accountID: String, snapshotID: String) throws -> URL {
        try SwitcherPaths.validateID(snapshotID)
        return try paths.accountRoot(accountID).appendingPathComponent("\(snapshotID).json")
    }

    public func saveRefreshed(_ material: AuthMaterial, for account: Account, state: inout StoreState) throws {
        guard try material.credentials.identity().matches(account) else {
            throw SwitcherError.message("续期后账号或组织发生变化，请通过官方流程重新登录。")
        }
        _ = try importMaterial(material, active: false, state: &state)
    }

    public func rename(_ id: String, label: String) throws {
        let lock = try StoreLock(root: paths.root)
        defer { withExtendedLifetime(lock) {} }
        var state = try loadState()
        guard let index = state.accounts.firstIndex(where: { $0.id == id }) else {
            throw SwitcherError.message("找不到这个已保存的账号。")
        }
        state.accounts[index].label = String(label.prefix(120))
        try saveState(state)
    }

    public func forget(_ id: String) throws {
        let lock = try StoreLock(root: paths.root)
        defer { withExtendedLifetime(lock) {} }
        var state = try loadState()
        state.accounts.removeAll { $0.id == id }
        if state.activeAccountID == id { state.activeAccountID = nil }
        // Forgetting a profile must not sign out the live app or break backups.
        // Historical encrypted snapshots/keys remain for recovery.
        try saveState(state)
    }

    public func updatePreferences(_ update: (inout Preferences) -> Void) throws {
        let lock = try StoreLock(root: paths.root)
        defer { withExtendedLifetime(lock) {} }
        var state = try loadState()
        update(&state.preferences)
        try saveState(state)
    }
}
