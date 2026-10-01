import AppKit
import SwitcherCore

@MainActor
enum SessionPicker {
    static func pick(_ sessions: [LocalSession], selected: Set<String>) -> Set<String>? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "选择要跨账号继续的本地会话"
        alert.informativeText = """
        切换前会备份所选会话，再移除本地组织标记。
        继续对话时，其内容可能被发送到目标账号所属的组织。
        请勿选择你没有权限转移的公司或他人对话。
        """
        alert.addButton(withTitle: "保存选择")
        alert.addButton(withTitle: "取消")
        let (scroll, buttons) = accessory(sessions, selected: selected)
        alert.accessoryView = scroll
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Set(buttons.filter { $0.1.state == .on }.map(\.0))
    }

    static func accessory(_ sessions: [LocalSession], selected: Set<String>) -> (NSScrollView, [(String, NSButton)]) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let height = CGFloat(max(320, sessions.count * 34 + 12))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: height))
        var buttons: [(String, NSButton)] = []
        for (index, session) in sessions.enumerated() {
            let title = session.title.replacingOccurrences(of: "\n", with: " ")
            let label = (title.count > 43 ? String(title.prefix(42)) + "…" : title)
                + (session.organizationID == nil ? "（已共享）" : "")
            let button = NSButton(checkboxWithTitle: label, target: nil, action: nil)
            button.frame = NSRect(x: 10, y: height - CGFloat((index + 1) * 34), width: 480, height: 28)
            button.state = selected.contains(session.id) ? .on : .off
            button.toolTip = "\(title)\n\(session.relativePath)"
            document.addSubview(button)
            buttons.append((session.id, button))
        }
        scroll.documentView = document
        document.scroll(NSPoint(x: 0, y: height - 320))
        return (scroll, buttons)
    }
}
