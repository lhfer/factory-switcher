import AppKit
import Foundation
import SwitcherCore

final class MacFactoryRuntime: FactoryRuntime {
    static let factoryBundleID = "com.electron.factory"
    let appURL: URL

    init(appURL: URL) { self.appURL = appURL }

    @MainActor
    func status() async throws -> RuntimeStatus {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.factoryBundleID)
        let pids = Set(apps.filter { !$0.isTerminated }.map(\.processIdentifier))
        let records = try await Task.detached { try Self.processes() }.value
        return ProcessInspection.classify(records, factoryPIDs: pids)
    }

    @MainActor
    func stopFactory() async throws {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.factoryBundleID)
        for app in apps where !app.isTerminated {
            guard app.terminate() else {
                throw SwitcherError.message("Factory 没有接受退出请求，请先手动退出再切换。")
            }
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let current = try await status()
            if current.quiescent { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw SwitcherError.message("Factory/Droid 尚未退出。已取消切换，不会强制结束你的任务。")
    }

    @MainActor
    func startFactory() async throws {
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            throw SwitcherError.message("未找到 Factory.app，请确认安装位置。")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    private static func processes() throws -> [ProcessRecord] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,comm=", "-ww"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count < 4 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8) else {
            throw SwitcherError.message("无法确认 Droid 进程状态，出于安全考虑已停止操作。")
        }
        return ProcessInspection.parse(text)
    }
}
