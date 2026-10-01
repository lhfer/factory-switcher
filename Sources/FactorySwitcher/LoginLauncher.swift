import AppKit
import Darwin
import Foundation
import SwitcherCore

enum LoginLauncher {
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func createScript(login: PendingLogin, paths: SwitcherPaths, droidURL: URL) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: droidURL.path) else {
            throw SwitcherError.message("找不到 Factory 自带的 Droid 登录程序。")
        }
        let root = try paths.loginRoot(login.id)
        let script = root.appendingPathComponent("login.command")
        let body = """
        #!/bin/bash
        umask 077
        cd \(shellQuote(root.path)) || exit 1
        if ! /bin/mkdir run.lock 2>/dev/null; then
          printf '此登录终端已经打开，请使用原终端完成登录。\\n'
          exit 1
        fi
        finish() {
          result=$?
          printf '%s\\n' "$result" > \(shellQuote(root.appendingPathComponent("completed").path))
          /bin/rmdir run.lock
        }
        trap finish EXIT
        trap ':' INT
        printf '\\nFactory 切号器：正在独立目录中添加账号。\\n'
        printf '请按 Droid 提示完成官方登录。登录后请按 Ctrl+C 退出 Droid，不要使用 /logout。\\n'
        printf '如果浏览器显示旧账号，请将登录链接复制到无痕窗口后登录新账号。\\n\\n'
        /usr/bin/env -u FACTORY_API_KEY -u FACTORY_API_BASE_URL \\
          -u AGENT_BROWSER_CDP -u AGENT_BROWSER_SESSION \\
          -u FACTORY_DESKTOP_CDP_PORT -u FACTORY_UPSTREAM_CLIENT_TYPE \\
          FACTORY_HOME_OVERRIDE=\(shellQuote(root.path)) \\
          FACTORY_ENV=production FACTORY_DEPLOYMENT_ENV=production \\
          FACTORY_DROID_AUTO_UPDATE_ENABLED=false \\
          \(shellQuote(droidURL.path))
        result=$?
        printf '\\n登录程序已退出。请回到屏幕右上角的切号器，点击“保存新登录”。\\n'
        exit "$result"
        """
        try SafeFiles.atomicWrite(Data(body.utf8), to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    @MainActor
    static func open(_ script: URL) throws {
        // A .command file is handed to Terminal through Launch Services.
        // No Apple Events permission or synthetic keyboard input is needed.
        guard NSWorkspace.shared.open(script) else {
            throw SwitcherError.message("无法打开登录终端，请在 Finder 中双击 login.command。")
        }
    }

    static func smokeTest() throws {
        guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw SwitcherError.message("无法创建脚本测试目录。")
        }
        defer { free(physical) }
        let temporary = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("factory switcher 'script test' \(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let paths = SwitcherPaths(root: temporary, factory: temporary.appendingPathComponent("unused-factory"))
        let login = PendingLogin(label: "模拟登录")
        let script = try createScript(login: login, paths: paths, droidURL: URL(fileURLWithPath: "/usr/bin/true"))
        for arguments in [["-n", script.path], [script.path]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": temporary.path, "TERM": "dumb"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw SwitcherError.message("独立登录脚本测试失败。")
            }
        }
        let root = try paths.loginRoot(login.id)
        guard try SafeFiles.read(root.appendingPathComponent("completed")) == Data("0\n".utf8),
              try !SafeFiles.exists(root.appendingPathComponent("run.lock")) else {
            throw SwitcherError.message("登录退出标记检查失败。")
        }
    }
}
