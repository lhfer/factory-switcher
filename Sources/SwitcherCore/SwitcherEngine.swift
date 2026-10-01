import Foundation

public struct SwitchResult: Sendable {
    public let backupID: String?
    public let sharedSessionCount: Int
    public let warning: String?
}

public actor SwitcherEngine {
    public let store: AccountStore
    private let runtime: FactoryRuntime
    private let quota: QuotaClient
    private let backups: Backups
    private var busy = false

    public init(store: AccountStore, runtime: FactoryRuntime, quota: QuotaClient) {
        self.store = store
        self.runtime = runtime
        self.quota = quota
        backups = Backups(store: store)
    }

    public func state() throws -> StoreState { try store.loadState() }
    public func runtimeStatus() async throws -> RuntimeStatus { try await runtime.status() }
    public func availableSessions() throws -> [LocalSession] { try SessionFiles.scan(root: store.paths.sessions) }
    public func availableBackups() throws -> [BackupManifest] { try backups.list() }
    public func needsRecovery() throws -> Bool { try SafeFiles.exists(store.paths.transaction) }

    public func saveCurrent(label: String = "") throws -> Account {
        try beginOperation()
        defer { busy = false }
        let lock = try StoreLock(root: store.paths.root)
        defer { withExtendedLifetime(lock) {} }
        try assertNoJournal()
        guard let material = try store.auth.load(home: store.paths.factory) else {
            throw SwitcherError.message("当前 Factory 尚未登录，请先登录或添加一个账号。")
        }
        var state = try store.loadState()
        return try store.importMaterial(material, label: label, active: true, state: &state)
    }

    public func synchronize(importUnknown: Bool = true) throws -> StoreState {
        try beginOperation()
        defer { busy = false }
        let lock = try StoreLock(root: store.paths.root)
        defer { withExtendedLifetime(lock) {} }
        try assertNoJournal()
        var state = try store.loadState()
        _ = try store.syncLive(state: &state, importUnknown: importUnknown)
        return state
    }

    public func setPreferences(_ preferences: Preferences) throws {
        try beginOperation()
        defer { busy = false }
        try assertNoJournal()
        try store.updatePreferences { $0 = preferences }
    }

    public func rename(_ id: String, label: String) throws {
        try beginOperation()
        defer { busy = false }
        try assertNoJournal()
        try store.rename(id, label: label)
    }

    public func forget(_ id: String) throws {
        try beginOperation()
        defer { busy = false }
        try assertNoJournal()
        try store.forget(id)
    }

    public func switchAccount(_ id: String) async throws -> SwitchResult {
        try beginOperation()
        defer { busy = false }
        let lock = try StoreLock(root: store.paths.root)
        defer { withExtendedLifetime(lock) {} }
        try assertNoJournal()
        var state = try store.loadState()
        guard state.pendingLogins.isEmpty else {
            throw SwitcherError.message("请先完成或取消正在添加的账号，再切换。")
        }
        guard let target = state.accounts.first(where: { $0.id == id }) else {
            throw SwitcherError.message("这个账号还没有保存。")
        }
        let targetMaterial = try store.load(target) // Check before quitting Factory.
        let initial = try await runtime.status()
        guard initial.externalDroidPIDs.isEmpty else {
            throw SwitcherError.message("检测到终端中的 Droid。请先关闭这些会话，再切换账号；工具不会结束你的任务。")
        }
        if let live = try store.auth.load(home: store.paths.factory),
           try live.credentials.identity().matches(target) {
            _ = try store.syncLive(state: &state)
            if !initial.factoryRunning { try await runtime.startFactory() }
            return SwitchResult(backupID: nil, sharedSessionCount: 0, warning: "这个账号已经在使用。")
        }

        try await runtime.stopFactory()
        try await requireStopped()
        let backup: BackupManifest
        do {
            _ = try store.syncLive(state: &state) // Capture the last rotated tokens after exit.
            backup = try backups.prepare(state: state, targetAccountID: id)
            try writeJournal(backup.id, committed: false)
        } catch {
            // No auth/session replacement has happened yet. Reopen the
            // original app if preparation fails after its graceful exit.
            if initial.factoryRunning { try? await runtime.startFactory() }
            throw error
        }
        do {
            try await requireStopped()
            try install(targetMaterial)
            try await requireStopped()
            try SessionFiles.apply(backup.sessions, root: store.paths.sessions)
            if !backup.sessions.isEmpty {
                try SafeFiles.remove(store.paths.factory.appendingPathComponent("sessions-index.json"))
            }
            // Avoid a later sync of pre-switch state overwriting the target.
            state.activeAccountID = id
            try store.saveState(state)
            try writeJournal(backup.id, committed: true)
        } catch {
            do {
                try await requireStopped()
                try backups.restoreAuth(backup)
                try backups.restoreSessions(backup)
                try store.saveState(backup.previousState)
                try SafeFiles.remove(store.paths.transaction)
            } catch {
                throw SwitcherError.message("切换没有完成，已保留备份和恢复记录。请关闭 Factory/Droid，点击“恢复中断的操作”。")
            }
            if initial.factoryRunning { try? await runtime.startFactory() }
            throw SwitcherError.message("切换失败，已恢复原登录和会话组织信息。")
        }
        var warning: String?
        do { try SafeFiles.remove(store.paths.transaction) }
        catch {
            // The commit marker is durable. Never start rolling back after
            // that point; recovery only needs to finish journal cleanup.
            warning = "账号已切换，但恢复记录未能清理。请点击“恢复中断的操作”完成清理。"
        }
        do {
            try await runtime.startFactory()
            return SwitchResult(backupID: backup.id, sharedSessionCount: backup.sessions.count, warning: warning)
        } catch {
            // Launch failure is not a reason to resurrect an old account after
            // the new account was committed.
            return SwitchResult(
                backupID: backup.id, sharedSessionCount: backup.sessions.count,
                warning: [warning, "账号已切换，但 Factory 未能自动打开。请手动打开 Factory。"]
                    .compactMap { $0 }.joined(separator: "\n")
            )
        }
    }

    public func quotaForAccount(_ id: String) async throws -> QuotaReport {
        try beginOperation()
        defer { busy = false }
        let lock = try StoreLock(root: store.paths.root)
        defer { withExtendedLifetime(lock) {} }
        try assertNoJournal()
        var state = try store.loadState()
        guard state.pendingLogins.isEmpty else {
            throw SwitcherError.message("正在添加账号，额度查询稍后继续。")
        }
        guard let account = state.accounts.first(where: { $0.id == id }) else {
            throw SwitcherError.message("找不到已保存的账号。")
        }
        let live = try store.auth.load(home: store.paths.factory)
        let liveIdentity = try live?.credentials.identity()
        let isLive = liveIdentity?.matches(account) == true
        var material = isLive ? live! : try store.load(account)
        if material.credentials.isExpired() {
            let status = try await runtime.status()
            // The running app owns the live refresh token. Different org
            // profiles of the same user can also share a rotating session.
            guard !isLive, status.externalDroidPIDs.isEmpty,
                  !(status.factoryRunning && liveIdentity?.userID == account.userID) else {
                throw SwitcherError.message("此登录正在被 Factory/Droid 使用，切号器不会同时续期。请打开 Factory 后重试。")
            }
            let refreshed = try await quota.refresh(material.credentials)
            material = try material.replacing(refreshed)
            // Persist rotation before any other network request.
            try store.saveRefreshed(material, for: account, state: &state)
        }
        return try await quota.fetch(material.credentials)
    }

    public func createPendingLogin(label: String) throws -> PendingLogin {
        try beginOperation()
        defer { busy = false }
        let lock = try StoreLock(root: store.paths.root)
        defer { withExtendedLifetime(lock) {} }
        try assertNoJournal()
        var state = try store.loadState()
        guard state.pendingLogins.isEmpty else {
            throw SwitcherError.message("请先完成或取消上一个账号的登录。")
        }
        let login = PendingLogin(label: String(label.prefix(120)))
        let root = try store.paths.loginRoot(login.id)
        try SafeFiles.ensureDirectory(root.appendingPathComponent(".factory", isDirectory: true))
        state.pendingLogins.append(login)
        try store.saveState(state)
        return login
    }

    public func finishPendingLogin(_ id: String) async throws -> Account {
        try beginOperation()
        defer { busy = false }
        let lock = try StoreLock(root: store.paths.root)
        defer { withExtendedLifetime(lock) {} }
        try assertNoJournal()
        var state = try store.loadState()
        guard let login = state.pendingLogins.first(where: { $0.id == id }) else {
            throw SwitcherError.message("找不到正在添加的账号。")
        }
        let root = try store.paths.loginRoot(login.id)
        let statusFile = root.appendingPathComponent("completed")
        guard try SafeFiles.exists(statusFile) else {
            throw SwitcherError.message("请完成官方登录，然后在登录终端中退出 Droid；退出后才能保存新账号。")
        }
        guard try await runtime.status().externalDroidPIDs.isEmpty else {
            throw SwitcherError.message("登录终端或其他终端中的 Droid 仍在运行。请先退出，再保存新账号。")
        }
        guard let material = try store.auth.load(home: root.appendingPathComponent(".factory")) else {
            throw SwitcherError.message("官方登录未生成账号信息，请重新打开登录终端。")
        }
        // Import without activating or touching the running Factory account.
        let account = try store.importMaterial(material, label: login.label, active: false, state: &state)
        state.pendingLogins.removeAll { $0.id == id }
        try store.saveState(state)
        return account
    }

    public func preparePendingRetry(_ id: String) async throws -> PendingLogin {
        try beginOperation()
        defer { busy = false }
        let lock = try StoreLock(root: store.paths.root)
        defer { withExtendedLifetime(lock) {} }
        try assertNoJournal()
        let state = try store.loadState()
        guard let login = state.pendingLogins.first(where: { $0.id == id }) else {
            throw SwitcherError.message("找不到正在添加的账号。")
        }
        guard try await runtime.status().externalDroidPIDs.isEmpty else {
            throw SwitcherError.message("请先关闭登录终端和其他终端中的 Droid，再重新打开登录。")
        }
        try SafeFiles.remove(try store.paths.loginRoot(id).appendingPathComponent("completed"))
        return login
    }

    public func cancelPendingLogin(_ id: String) async throws {
        try beginOperation()
        defer { busy = false }
        let lock = try StoreLock(root: store.paths.root)
        defer { withExtendedLifetime(lock) {} }
        try assertNoJournal()
        var state = try store.loadState()
        state.pendingLogins.removeAll { $0.id == id }
        try store.saveState(state)
        // Preserve the login directory. Never delete a running login's files.
    }

    public func recoverInterruptedOperation() async throws {
        try beginOperation()
        defer { busy = false }
        let lock = try StoreLock(root: store.paths.root)
        defer { withExtendedLifetime(lock) {} }
        guard try SafeFiles.exists(store.paths.transaction) else { return }
        let transaction = try SafeFiles.decode(TransactionRecord.self, from: SafeFiles.read(store.paths.transaction))
        if !transaction.committed {
            try await requireStopped()
            let backup = try backups.read(transaction.backupID)
            // The installed login may have been used, and its tokens rotated,
            // since the interruption. Save it to its known profile before the
            // backup replaces it. An unreadable half-installed login is skipped.
            var current = try? store.loadState()
            if var synced = current, (try? store.syncLive(state: &synced, importUnknown: false)) != nil {
                current = synced
            }
            try backups.restoreAuth(backup)
            try backups.restoreSessions(backup)
            var restored = backup.previousState
            for index in restored.accounts.indices {
                // Snapshot pointers only move forward; keep the newest ones.
                if let newer = current?.accounts.first(where: { $0.id == restored.accounts[index].id }) {
                    restored.accounts[index] = newer
                }
            }
            try store.saveState(restored)
        }
        try SafeFiles.remove(store.paths.transaction)
    }

    public func restoreSessionBackup(_ id: String) async throws {
        try beginOperation()
        defer { busy = false }
        let lock = try StoreLock(root: store.paths.root)
        defer { withExtendedLifetime(lock) {} }
        try assertNoJournal()
        try await requireStopped()
        let backup = try backups.read(id)
        try backups.restoreSessions(backup)
    }

    private func beginOperation() throws {
        guard !busy else { throw SwitcherError.message("正在处理另一个账号操作，请稍后再试。") }
        busy = true
    }

    private func assertNoJournal() throws {
        guard try !SafeFiles.exists(store.paths.transaction) else {
            throw SwitcherError.message("上次切换中断，请先关闭 Factory/Droid 并恢复中断的操作。")
        }
    }

    private func requireStopped() async throws {
        guard try await runtime.status().quiescent else {
            throw SwitcherError.message("Factory 或 Droid 仍在运行，未更改登录或对话文件。")
        }
    }

    private func writeJournal(_ id: String, committed: Bool) throws {
        try SafeFiles.atomicWrite(
            SafeFiles.encode(TransactionRecord(backupID: id, committed: committed)), to: store.paths.transaction
        )
    }

    private func install(_ material: AuthMaterial) throws {
        let home = store.paths.factory
        try SafeFiles.ensureDirectory(home)
        if material.format == .loginKeychain {
            let raw = Data(material.key.base64EncodedString().utf8)
            if try store.keys.read(service: KeychainNames.factoryService, account: KeychainNames.factoryAccount) != raw {
                try store.keys.write(raw, service: KeychainNames.factoryService, account: KeychainNames.factoryAccount)
            }
        } else {
            try SafeFiles.atomicWrite(Data(material.key.base64EncodedString().utf8), to: home.appendingPathComponent("auth.v2.key"))
        }
        try SafeFiles.atomicWrite(Data(material.encrypted.utf8), to: home.appendingPathComponent(material.format.filename))
        for name in AuthFormat.managedFilenames {
            if name == material.format.filename || (name == "auth.v2.key" && material.format == .keyfile) { continue }
            try SafeFiles.remove(home.appendingPathComponent(name))
        }
        guard let installed = try store.auth.load(home: home),
              installed.key == material.key, installed.encrypted == material.encrypted else {
            throw SwitcherError.message("切换后的登录校验失败。")
        }
    }
}
