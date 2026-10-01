import AppKit
import Foundation
import SwitcherCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let paths: SwitcherPaths
    private let appURL: URL
    private let engine: SwitcherEngine
    private var statusItem: NSStatusItem!
    private var state = StoreState()
    private var reports: [String: QuotaReport] = [:]
    private var quotaErrors: [String: String] = [:]
    private var history: [BackupManifest] = []
    private var working = false
    private var recoveryRequired = false
    private var dataReadFailed = false
    private var lastQuotaUpdate = Date.distantPast
    private var failedPendingImports = Set<String>()
    private var timer: Timer?

    init(paths: SwitcherPaths, appURL: URL) {
        self.paths = paths
        self.appURL = appURL
        let store = AccountStore(paths: paths, keys: MacKeychain())
        engine = SwitcherEngine(
            store: store, runtime: MacFactoryRuntime(appURL: appURL),
            quota: QuotaClient(transport: QuotaTransport())
        )
        super.init()
    }

    static func smokeTest() throws {
        // Exercise the real menu builder with synthetic display records.
        // The delegate is never launched: no timer, load, HTTP or Keychain call.
        let root = URL(fileURLWithPath: "/private/tmp/factory-switcher-ui-test-not-created", isDirectory: true)
        let delegate = AppDelegate(
            paths: SwitcherPaths(root: root, factory: root.appendingPathComponent("factory")),
            appURL: root.appendingPathComponent("Factory.app")
        )
        delegate.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(delegate.statusItem) }
        let account = try SafeFiles.decode(Account.self, from: Data("""
        {"id":"11111111-1111-4111-8111-111111111111","label":"模拟账号 A","email":"demo@example.test","userID":"synthetic-user","organizationID":"synthetic-org","format":"loginKeychain","keyReference":"22222222-2222-4222-8222-222222222222","snapshotID":"33333333-3333-4333-8333-333333333333","updatedAt":"2026-01-01T00:00:00Z"}
        """.utf8))
        delegate.state.accounts = [account]
        delegate.state.activeAccountID = account.id
        delegate.reports[account.id] = try QuotaReport.parse(Data("""
        {"limits":{"standard":{"fiveHour":{"usedPercent":37,"secondsRemaining":1000}}}}
        """.utf8))
        delegate.rebuildMenu()
        guard let menu = delegate.statusItem.menu, !menu.autoenablesItems,
              menu.item(withTitle: account.displayName)?.state == .on,
              menu.item(withTitle: account.displayName)?.isEnabled == true,
              menu.item(withTitle: "5小时：剩余 63%") != nil,
              menu.item(withTitle: "额度详情")?.submenu?.items.count == 3 else {
            throw SwitcherError.message("正常菜单检查失败。")
        }
        delegate.working = true
        delegate.rebuildMenu()
        guard delegate.statusItem.menu?.item(withTitle: account.displayName)?.isEnabled == false else {
            throw SwitcherError.message("忙碌状态检查失败。")
        }
        delegate.working = false
        delegate.recoveryRequired = true
        delegate.rebuildMenu()
        guard delegate.statusItem.menu?.item(withTitle: account.displayName)?.isEnabled == false,
              delegate.statusItem.menu?.item(withTitle: "恢复中断的操作…")?.isEnabled == true else {
            throw SwitcherError.message("恢复菜单检查失败。")
        }
        delegate.recoveryRequired = false
        delegate.state.pendingLogins = [PendingLogin(label: "模拟登录")]
        delegate.rebuildMenu()
        guard delegate.statusItem.menu?.item(withTitle: account.displayName)?.isEnabled == false,
              delegate.statusItem.menu?.item(withTitle: "正在添加：模拟登录")?.submenu?.items.count == 4 else {
            throw SwitcherError.message("登录菜单检查失败。")
        }
        let session = LocalSession(id: account.id, relativePath: "demo.jsonl", title: "模拟会话\n标题", organizationID: nil)
        let (scroll, buttons) = SessionPicker.accessory([session], selected: [session.id])
        guard scroll.hasVerticalScroller, buttons.count == 1, buttons[0].1.state == .on,
              !buttons[0].1.title.contains("\n"), LoginLauncher.shellQuote("a'b c") == "'a'\\''b c'" else {
            throw SwitcherError.message("会话选择或登录引用检查失败。")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "person.2.badge.key", accessibilityDescription: "Factory 切号器")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.title = " FS"
        statusItem.button?.toolTip = "Factory 切号器，点击选择账号"
        rebuildMenu()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task {
            guard await reload() else { return }
            if state.accounts.isEmpty {
                let choice = confirm(
                    title: "保存你当前的 Factory 账号？",
                    detail: "切号器仅管理你自己登录的账号。登录文件保持加密，密钥保存在本机钥匙串。\n\n系统可能要求你允许访问 Factory 的钥匙串项目。工具不会改动 Factory 安装包，也不会自动切号。",
                    action: "保存当前账号"
                )
                if choice { await saveCurrentAccount() }
            } else if !recoveryRequired {
                await updateQuotas()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if working {
            showError("操作正在进行，请完成后再退出切号器。")
            return .terminateCancel
        }
        return .terminateNow
    }

    func menuWillOpen(_ menu: NSMenu) {
        // No network or Keychain work in the menu-open callback.
        // Cached results keep the menu fast and avoid unexpected system prompts.
    }

    @discardableResult
    private func reload() async -> Bool {
        do {
            state = try await engine.state()
            recoveryRequired = try await engine.needsRecovery()
            history = try await engine.availableBackups()
            dataReadFailed = false
        } catch {
            dataReadFailed = true
            showError(error.localizedDescription)
        }
        rebuildMenu()
        return !dataReadFailed
    }

    private func rebuildMenu() {
        let menu = newMenu()
        menu.delegate = self
        menu.addItem(infoItem("Factory 切号器", bold: true))
        if working { menu.addItem(infoItem("正在处理，请稍候…")) }
        if dataReadFailed { menu.addItem(infoItem("数据读取失败，已暂停操作；请查看使用说明")) }
        if recoveryRequired {
            menu.addItem(infoItem("上次操作中断，当前已暂停切号"))
            menu.addItem(actionItem("恢复中断的操作…", #selector(recover)))
        }
        menu.addItem(.separator())
        if state.accounts.isEmpty { menu.addItem(infoItem("尚未保存账号")) }
        for account in state.accounts {
            let item = actionItem(truncate(account.displayName, to: 42), #selector(switchAccount(_:)), value: account.id)
            item.state = account.id == state.activeAccountID ? .on : .off
            item.isEnabled = !working && !recoveryRequired && !dataReadFailed && state.pendingLogins.isEmpty
            menu.addItem(item)
            if let email = account.email, email != account.displayName {
                menu.addItem(infoItem(email, indent: 1))
            }
            if state.preferences.showQuota {
                if let report = reports[account.id] {
                    menu.addItem(infoItem(truncate(report.summary, to: 64), indent: 1))
                    if let error = quotaErrors[account.id] {
                        menu.addItem(infoItem("上次结果 · \(truncate(error, to: 58))", indent: 1))
                    } else {
                        menu.addItem(infoItem("查询于 \(timeText(report.fetchedAt))", indent: 1))
                    }
                    if !report.groups.isEmpty || (report.extraUsageBalanceCents ?? 0) > 0 {
                        let detail = NSMenuItem(title: "额度详情", action: nil, keyEquivalent: "")
                        detail.indentationLevel = 1
                        detail.submenu = quotaDetailMenu(report)
                        menu.addItem(detail)
                    }
                } else {
                    menu.addItem(infoItem(truncate(quotaErrors[account.id] ?? "待查询额度", to: 64), indent: 1))
                }
            }
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("保存 / 同步当前账号", #selector(saveCurrent)))
        menu.addItem(actionItem("添加账号（官方登录）…", #selector(addAccount)))
        if let pending = state.pendingLogins.first {
            let pendingMenu = newMenu()
            pendingMenu.addItem(infoItem("完成授权后，在登录终端中退出 Droid"))
            pendingMenu.addItem(actionItem("保存新登录", #selector(finishLogin(_:)), value: pending.id))
            pendingMenu.addItem(actionItem("重新打开登录终端", #selector(reopenLogin(_:)), value: pending.id))
            pendingMenu.addItem(actionItem("取消添加…", #selector(cancelLogin(_:)), value: pending.id))
            let item = NSMenuItem(title: "正在添加：\(pending.label.isEmpty ? "新账号" : truncate(pending.label, to: 24))", action: nil, keyEquivalent: "")
            item.submenu = pendingMenu
            menu.addItem(item)
        }
        menu.addItem(actionItem("刷新所有账号额度", #selector(refreshQuotas)))
        menu.addItem(.separator())
        let sessions = actionItem("共享所选会话（先备份）", #selector(toggleSharing))
        sessions.state = state.preferences.shareSessions ? .on : .off
        menu.addItem(sessions)
        menu.addItem(actionItem(
            "选择要共享的会话…（\(state.preferences.selectedSessionIDs.count)）", #selector(selectSessions)
        ))
        let options = newMenu()
        let confirmation = actionItem("切号前确认重启", #selector(toggleConfirmation))
        confirmation.state = state.preferences.confirmSwitch ? .on : .off
        options.addItem(confirmation)
        let quotaToggle = actionItem("显示并定期查询额度", #selector(toggleQuota))
        quotaToggle.state = state.preferences.showQuota ? .on : .off
        options.addItem(quotaToggle)
        options.addItem(infoItem("不会自动切号；额度查询不消耗模型对话额度"))
        let optionItem = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        optionItem.submenu = options
        menu.addItem(optionItem)
        if !state.accounts.isEmpty {
            let manage = NSMenuItem(title: "管理账号", action: nil, keyEquivalent: "")
            let submenu = newMenu()
            for account in state.accounts {
                let accountMenu = newMenu()
                accountMenu.addItem(actionItem("修改备注…", #selector(renameAccount(_:)), value: account.id))
                accountMenu.addItem(actionItem("从菜单移除…", #selector(forgetAccount(_:)), value: account.id))
                let accountItem = NSMenuItem(title: truncate(account.displayName, to: 42), action: nil, keyEquivalent: "")
                accountItem.submenu = accountMenu
                submenu.addItem(accountItem)
            }
            manage.submenu = submenu
            menu.addItem(manage)
        }
        let backupItem = NSMenuItem(title: "备份与恢复", action: nil, keyEquivalent: "")
        backupItem.submenu = backupMenu()
        menu.addItem(backupItem)
        menu.addItem(.separator())
        menu.addItem(actionItem("打开 Factory", #selector(openFactory)))
        menu.addItem(actionItem("使用说明…", #selector(help)))
        menu.addItem(actionItem("退出切号器", #selector(quit)))
        statusItem.menu = menu
        statusItem.button?.title = working ? " FS…" : " FS"
    }

    private func quotaDetailMenu(_ report: QuotaReport) -> NSMenu {
        let menu = newMenu()
        for group in report.groups {
            menu.addItem(infoItem(group.name == "standard" ? "Standard" : group.name, bold: true))
            for window in group.windows {
                menu.addItem(infoItem(window.text()))
                if let end = window.windowEnd, end > Date() {
                    menu.addItem(infoItem("重置：\(dateTimeText(end))", indent: 1))
                }
            }
        }
        if let cents = report.extraUsageBalanceCents, cents > 0 {
            menu.addItem(infoItem(String(format: "额外用量余额：$%.2f", cents / 100)))
        }
        return menu
    }

    private func backupMenu() -> NSMenu {
        let menu = newMenu()
        menu.addItem(actionItem("打开备份目录", #selector(openBackups)))
        menu.addItem(infoItem("恢复会话标记前，需手动退出 Factory/Droid"))
        for backup in history.prefix(8) {
            if backup.sessions.isEmpty { continue }
            menu.addItem(actionItem(
                "恢复 \(dateTimeText(backup.createdAt)) 的 \(backup.sessions.count) 条会话标记…",
                #selector(restoreSessions(_:)), value: backup.id
            ))
        }
        return menu
    }

    private func tick() async {
        guard !working, !dataReadFailed else { return }
        if let pending = state.pendingLogins.first,
           !failedPendingImports.contains(pending.id),
           let root = try? paths.loginRoot(pending.id),
           (try? SafeFiles.exists(root.appendingPathComponent("completed"))) == true {
            await finishPending(pending.id)
            return
        }
        guard !recoveryRequired, !state.accounts.isEmpty else { return }
        working = true
        do {
            state = try await engine.synchronize(importUnknown: false)
        } catch {
            // Avoid repeated alerts from a background timer. Explicit actions
            // show the error; the menu keeps a short status for the user.
            for account in state.accounts { quotaErrors[account.id] = error.localizedDescription }
        }
        working = false
        rebuildMenu()
        if state.preferences.showQuota, Date().timeIntervalSince(lastQuotaUpdate) >= 300 {
            await updateQuotas()
        }
    }

    private func updateQuotas() async {
        guard !working, !recoveryRequired, !dataReadFailed, state.preferences.showQuota else { return }
        working = true
        rebuildMenu()
        lastQuotaUpdate = Date()
        for account in state.accounts {
            do {
                reports[account.id] = try await engine.quotaForAccount(account.id)
                quotaErrors[account.id] = nil
            } catch { quotaErrors[account.id] = error.localizedDescription }
            rebuildMenu()
        }
        working = false
        await reload()
    }

    private func saveCurrentAccount() async {
        await perform {
            let account = try await self.engine.saveCurrent()
            self.showMessage("账号已保存", detail: account.displayName)
        }
        await updateQuotas()
    }

    private func finishPending(_ id: String) async {
        await perform {
            do {
                let account = try await self.engine.finishPendingLogin(id)
                self.failedPendingImports.remove(id)
                self.showMessage("新账号已保存", detail: "\(account.displayName)\n\n当前 Factory 账号没有改变。点击账号列表中的新账号即可切换。")
            } catch {
                self.failedPendingImports.insert(id)
                throw error
            }
        }
        await updateQuotas()
    }

    private func perform(_ operation: @escaping () async throws -> Void) async {
        guard !working else { return }
        working = true
        rebuildMenu()
        do { try await operation() }
        catch { showError(error.localizedDescription) }
        working = false
        await reload()
    }

    @objc private func saveCurrent() { Task { await saveCurrentAccount() } }
    @objc private func refreshQuotas() { Task { await updateQuotas() } }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func switchAccount(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String,
              let account = state.accounts.first(where: { $0.id == id }) else { return }
        let shared = state.preferences.shareSessions ? state.preferences.selectedSessionIDs.count : 0
        let detail = """
        目标：\(account.displayName)

        工具会正常退出并重新打开 Factory。正在运行的任务会中断，请先保存工作。
        当前登录会保存；切换失败时会回滚。终端中的 Droid 需要先关闭。
        \(shared > 0 ? "\n将先备份并共享所选的 \(shared) 条本地会话。继续这些对话时，内容可能会被发送到目标账号所属的组织。" : "")
        """
        if state.preferences.confirmSwitch,
           !confirm(title: "切换账号并重启 Factory？", detail: detail, action: "切换") { return }
        Task {
            await perform {
                let result = try await self.engine.switchAccount(id)
                if let warning = result.warning { self.showMessage("切号结果", detail: warning) }
            }
            await updateQuotas()
        }
    }

    @objc private func addAccount() {
        guard let label = prompt(title: "添加账号", detail: "给新账号写个备注（可留空）。工具会打开独立目录中的官方 Droid 登录。\n完成浏览器授权后，请退出登录终端里的 Droid，账号会自动保存。", initial: "") else { return }
        Task {
            await perform {
                let login = try await self.engine.createPendingLogin(label: label)
                let script = try LoginLauncher.createScript(
                    login: login, paths: self.paths,
                    droidURL: self.appURL.appendingPathComponent("Contents/Resources/bin/droid")
                )
                try LoginLauncher.open(script)
            }
        }
    }

    @objc private func finishLogin(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        Task { await finishPending(id) }
    }

    @objc private func reopenLogin(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        Task {
            await perform {
                let pending = try await self.engine.preparePendingRetry(id)
                let script = try LoginLauncher.createScript(
                    login: pending, paths: self.paths,
                    droidURL: self.appURL.appendingPathComponent("Contents/Resources/bin/droid")
                )
                try LoginLauncher.open(script)
                self.failedPendingImports.remove(id)
            }
        }
    }

    @objc private func cancelLogin(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String,
              confirm(title: "取消添加这个账号？", detail: "请先退出登录终端里的 Droid。\n这只移除待添加记录，保留目录，不会关闭你的终端或删除文件。", action: "取消添加") else { return }
        Task { await perform { try await self.engine.cancelPendingLogin(id) } }
    }

    @objc private func toggleSharing() {
        var preferences = state.preferences
        preferences.shareSessions.toggle()
        if preferences.shareSessions,
           !confirm(title: "启用所选会话共享？", detail: "只共享你选择的本地会话，切换前会先备份。\n继续这些对话时，内容可能被发送到目标账号所属的组织。不要混用不同公司的机密对话。", action: "启用") { return }
        let updated = preferences
        Task { await perform { try await self.engine.setPreferences(updated) } }
    }

    @objc private func toggleConfirmation() {
        var preferences = state.preferences
        preferences.confirmSwitch.toggle()
        if !preferences.confirmSwitch,
           !confirm(title: "关闭切号确认？", detail: "之后点击账号会立即尝试退出并重新打开 Factory。请在切换前结束正在运行的任务。", action: "关闭确认") { return }
        let updated = preferences
        Task { await perform { try await self.engine.setPreferences(updated) } }
    }

    @objc private func toggleQuota() {
        var preferences = state.preferences
        preferences.showQuota.toggle()
        let updated = preferences
        Task {
            await perform { try await self.engine.setPreferences(updated) }
            if updated.showQuota { await updateQuotas() }
        }
    }

    @objc private func selectSessions() {
        Task {
            do {
                let sessions = try await engine.availableSessions()
                guard !sessions.isEmpty else {
                    showMessage("没有找到可共享的本地会话", detail: "先在 Factory 中开始一个对话，再来选择。")
                    return
                }
                guard let selected = SessionPicker.pick(sessions, selected: Set(state.preferences.selectedSessionIDs)) else { return }
                var preferences = state.preferences
                preferences.selectedSessionIDs = selected.sorted()
                let updated = preferences
                await perform { try await self.engine.setPreferences(updated) }
            } catch { showError(error.localizedDescription) }
        }
    }

    @objc private func renameAccount(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String,
              let account = state.accounts.first(where: { $0.id == id }),
              let label = prompt(title: "修改账号备注", detail: "留空会使用邮箱作为名称。", initial: account.label) else { return }
        Task { await perform { try await self.engine.rename(id, label: label) } }
    }

    @objc private func forgetAccount(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String,
              confirm(title: "从菜单移除这个账号？", detail: "不会退出当前登录。\n为了备份恢复，历史加密文件和钥匙串密钥会保留。完整清理请参考使用说明。", action: "移除") else { return }
        Task { await perform { try await self.engine.forget(id) } }
    }

    @objc private func recover() {
        Task {
            await perform {
                try await self.engine.recoverInterruptedOperation()
                self.showMessage("中断操作已恢复", detail: "可手动打开 Factory，或从菜单选择账号。")
            }
        }
    }

    @objc private func restoreSessions(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String,
              confirm(title: "恢复这些会话的原组织标记？", detail: "请先退出 Factory 和所有 Droid。\n仅恢复组织标记，不删除新增对话消息，也不更改当前登录。", action: "恢复") else { return }
        Task { await perform { try await self.engine.restoreSessionBackup(id) } }
    }

    @objc private func openBackups() {
        do {
            try SafeFiles.ensureDirectory(paths.backups)
            NSWorkspace.shared.open(paths.backups)
        } catch { showError(error.localizedDescription) }
    }

    @objc private func openFactory() {
        NSWorkspace.shared.open(appURL)
    }

    @objc private func help() {
        let bundled = Bundle.main.url(forResource: "使用说明", withExtension: "md")
        if let bundled { NSWorkspace.shared.open(bundled) }
        else {
            showMessage("Factory 切号器", detail: """
            1. 保存当前账号。
            2. 添加账号，通过官方 Droid 登录并退出登录终端。
            3. 选择要共享的本地会话。
            4. 点击账号切换，Factory 会重新打开。

            数据位于 ~/.factory-switcher，密钥在本机钥匙串。
            这是非官方本地工具，不会自动切号或修改服务端额度。
            """)
        }
    }

    private func actionItem(_ title: String, _ action: Selector, value: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        let alwaysAvailable = action == #selector(openBackups) || action == #selector(help) || action == #selector(quit)
        item.isEnabled = !working && (alwaysAvailable || (!dataReadFailed
            && (!recoveryRequired || action == #selector(recover))))
        return item
    }

    private func infoItem(_ title: String, indent: Int = 0, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = indent
        if bold { item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]) }
        return item
    }

    private func newMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }

    private func truncate(_ text: String, to count: Int) -> String {
        let plain = text.replacingOccurrences(of: "\n", with: " ")
        return plain.count > count ? String(plain.prefix(count - 1)) + "…" : plain
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func dateTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func confirm(title: String, detail: String, action: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "返回")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func prompt(title: String, detail: String, initial: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        field.stringValue = initial
        field.placeholderString = "个人账号 / 工作账号 / 备用账号"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    }

    private func showError(_ text: String) { showMessage("操作未完成", detail: text, warning: true) }

    private func showMessage(_ title: String, detail: String, warning: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = warning ? .warning : .informational
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
}
