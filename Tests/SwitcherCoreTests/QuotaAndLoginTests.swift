import Foundation
import XCTest
@testable import SwitcherCore

final class QuotaAndLoginTests: XCTestCase {
    private let limits = Data("""
    {"limits":{"standard":{"fiveHour":{"usedPercent":37,"secondsRemaining":3600},"weekly":{"usedPercent":100,"windowEnd":"2000-01-01T00:00:00Z"},"monthly":{"usedPercent":18,"secondsRemaining":6000}},"futurePool":{"fiveHour":{"usedPercent":12,"secondsRemaining":1000}}},"extraUsageBalanceCents":235}
    """.utf8)

    func testLimitsParsingMissingFieldsAndExpiredWindows() throws {
        let report = try QuotaReport.parse(limits)
        XCTAssertEqual(report.groups.map(\.name), ["standard", "futurePool"])
        XCTAssertEqual(report.extraUsageBalanceCents, 235)
        XCTAssertTrue(report.summary.contains("剩余 63%"))
        XCTAssertTrue(report.summary.contains("待开启"))
        let unknown = try QuotaReport.parse(Data("{\"limits\":{\"standard\":{\"fiveHour\":{}}}}".utf8))
        XCTAssertTrue(unknown.summary.contains("未知"))
        XCTAssertThrowsError(try QuotaReport.parse(Data("html".utf8)))
        let huge = try QuotaReport.parse(Data("""
        {"limits":{"standard":{"fiveHour":{"usedPercent":1e300,"secondsRemaining":0},"weekly":{"usedPercent":-10},"monthly":{"usedPercent":45,"secondsRemaining":1e300}}}}
        """.utf8))
        XCTAssertTrue(huge.summary.contains("100%"))
        XCTAssertTrue(huge.summary.contains("未知"))
    }

    func testInactiveRefreshPreservesUnknownFieldsAndNeverWritesLiveLogin() async throws {
        let home = try TestHome()
        let live = try home.material()
        try home.setLive(live)
        _ = try home.save(live, active: true)
        let inactive = try home.material(user: "user-b", org: "org-b", expired: true)
        let b = try home.save(inactive)
        let next = try home.jwt(user: "user-b", org: "org-b")
        home.http.replies = [
            HTTPReply(status: 200, data: try SafeFiles.encode([
                "access_token": JSONValue.string(next), "refresh_token": .string("rotated-synthetic-b"),
            ])),
            HTTPReply(status: 200, data: limits),
        ]
        _ = try await home.engine.quotaForAccount(b.id)
        let state = try home.store.loadState()
        let updated = try home.store.load(XCTUnwrap(state.accounts.first { $0.id == b.id }))
        XCTAssertEqual(updated.credentials.fields["future_field"], inactive.credentials.fields["future_field"])
        XCTAssertEqual(updated.credentials.refreshToken, "rotated-synthetic-b")
        XCTAssertEqual(try home.store.auth.load(home: home.paths.factory)?.encrypted, live.encrypted)
        XCTAssertEqual(home.http.requests.count, 2)
        XCTAssertEqual(home.http.requests[0].httpMethod, "POST")
        XCTAssertFalse(String(data: try XCTUnwrap(home.http.requests[0].httpBody), encoding: .utf8)!.contains("organization_id"))
    }

    func testLiveExpiredTokenIsNeverRefreshedBySwitcher() async throws {
        let home = try TestHome()
        let live = try home.material(expired: true)
        try home.setLive(live)
        let a = try home.save(live, active: true)
        home.runtime.current.factoryRunning = true
        do { _ = try await home.engine.quotaForAccount(a.id); XCTFail("Should defer to Factory") } catch {}
        XCTAssertTrue(home.http.requests.isEmpty)
        XCTAssertEqual(try home.store.auth.load(home: home.paths.factory)?.encrypted, live.encrypted)
    }

    func testExternalDroidBlocksRefreshAndErrorBodiesNeverLeak() async throws {
        let home = try TestHome()
        let expired = try home.material(expired: true)
        let account = try home.save(expired)
        home.runtime.current.externalDroidPIDs = [98]
        do { _ = try await home.engine.quotaForAccount(account.id); XCTFail("Should block") } catch {}
        XCTAssertTrue(home.http.requests.isEmpty)
        home.runtime.current.externalDroidPIDs = []
        home.http.replies = [HTTPReply(status: 400, data: Data("SECRET_SHOULD_NOT_LEAK".utf8))]
        do { _ = try await home.engine.quotaForAccount(account.id); XCTFail("Should fail") }
        catch { XCTAssertFalse(error.localizedDescription.contains("SECRET_SHOULD_NOT_LEAK")) }
        XCTAssertEqual(home.http.requests.count, 1)
    }

    func testBusyGuardRejectsSwitchDuringQuotaRequest() async throws {
        let home = try TestHome()
        let material = try home.material()
        let account = try home.save(material)
        home.http.replies = [HTTPReply(status: 200, data: limits)]
        home.http.sendHook = {
            do {
                _ = try await home.engine.switchAccount(account.id)
                XCTFail("Must reject actor reentrant switch")
            } catch {}
        }
        _ = try await home.engine.quotaForAccount(account.id)
        XCTAssertEqual(home.runtime.stopCalled, 0)
    }

    func testPendingLoginStaysIsolatedAndDoesNotActivate() async throws {
        let home = try TestHome()
        let live = try home.material()
        try home.setLive(live)
        let a = try home.save(live, active: true)
        let pending = try await home.engine.createPendingLogin(label: "Second")
        let root = try home.paths.loginRoot(pending.id)
        let new = try home.material(user: "user-b", org: "org-b")
        try SafeFiles.atomicWrite(Data(new.encrypted.utf8), to: root.appendingPathComponent(".factory/auth.v2.loginkeychain"))
        do { _ = try await home.engine.finishPendingLogin(pending.id); XCTFail("Must wait for Droid exit") } catch {}
        try SafeFiles.atomicWrite(Data("0\n".utf8), to: root.appendingPathComponent("completed"))
        let b = try await home.engine.finishPendingLogin(pending.id)
        XCTAssertEqual(b.label, "Second")
        XCTAssertEqual(try home.store.loadState().activeAccountID, a.id)
        XCTAssertEqual(try home.store.auth.load(home: home.paths.factory)?.encrypted, live.encrypted)
    }

    func testPendingMarkerCannotImportWhileTerminalDroidStillRuns() async throws {
        let home = try TestHome()
        let material = try home.material()
        try home.setLive(material)
        let pending = try await home.engine.createPendingLogin(label: "")
        let root = try home.paths.loginRoot(pending.id)
        try SafeFiles.atomicWrite(Data(material.encrypted.utf8), to: root.appendingPathComponent(".factory/auth.v2.loginkeychain"))
        try SafeFiles.atomicWrite(Data("0\n".utf8), to: root.appendingPathComponent("completed"))
        home.runtime.current.externalDroidPIDs = [77]
        do { _ = try await home.engine.finishPendingLogin(pending.id); XCTFail("Must wait for processes") } catch {}
        XCTAssertEqual(try home.store.loadState().pendingLogins.count, 1)
        home.runtime.current.externalDroidPIDs = []
        _ = try await home.engine.finishPendingLogin(pending.id)
        XCTAssertEqual(try home.store.loadState().pendingLogins.count, 0)
    }

    func testRotationSavedEvenWhenFollowingQuotaRequestFails() async throws {
        let home = try TestHome()
        let expired = try home.material(expired: true)
        let account = try home.save(expired)
        home.http.replies = [
            HTTPReply(status: 200, data: try SafeFiles.encode([
                "access_token": JSONValue.string(home.jwt(user: "user-a", org: "org-a")),
                "refresh_token": .string("committed-rotation"),
            ])),
            HTTPReply(status: 503, data: Data()),
        ]
        do { _ = try await home.engine.quotaForAccount(account.id); XCTFail("Quota should fail") } catch {}
        let saved = try XCTUnwrap(home.store.loadState().accounts.first)
        XCTAssertEqual(try home.store.load(saved).credentials.refreshToken, "committed-rotation")
        XCTAssertEqual(home.http.requests.count, 2)
    }
}
