import AppKit
import Foundation
import SwitcherCore

@main
struct FactorySwitcherMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--smoke-test") {
            // UI construction check only. No user's Keychain, Factory home,
            // network, process termination or login operation is touched.
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            do {
                try AppDelegate.smokeTest()
                try LoginLauncher.smokeTest()
            } catch {
                fputs("UI smoke test failed\n", stderr)
                exit(1)
            }
            print("Smoke test passed: account, quota, busy, recovery, session controls and isolated login script. No live account accessed.")
            return
        }

        let bundleID = "local.FactorySwitcher"
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: .activateIgnoringOtherApps)
            return
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let factory = NSWorkspace.shared.urlForApplication(withBundleIdentifier: MacFactoryRuntime.factoryBundleID)
            ?? URL(fileURLWithPath: "/Applications/Factory.app", isDirectory: true)
        let delegate = AppDelegate(paths: .standard(), appURL: factory)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
