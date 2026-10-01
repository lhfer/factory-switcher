import Foundation
import XCTest
@testable import SwitcherCore

final class SwitchingTests: XCTestCase {
    func testSwitchSyncsTokensAfterExitAndRestoresDifferentKey() async throws {
        let home = try TestHome()
        let original = try home.material(refresh: "before-refresh", keyByte: 17)
        try home.setLive(original)
        let a = try home.save(original, active: true)
        let targetMaterial = try home.material(user: "user-b", org: "org-b", keyByte: 34)
        let b = try home.save(targetMaterial)
        let rotated = try home.material(refresh: "last-rotated-token", keyByte: 17)
        home.runtime.current.factoryRunning = true
        home.runtime.onStop = { try home.setLive(rotated) }
        let result = try await home.engine.switchAccount(b.id)
        let state = try home.store.loadState()
        let savedA = try XCTUnwrap(state.accounts.first { $0.id == a.id })
        XCTAssertEqual(try home.store.load(savedA).credentials.refreshToken, "last-rotated-token")
        XCTAssertEqual(try home.store.auth.load(home: home.paths.factory)?.credentials.identity().userID, "user-b")
        XCTAssertEqual(state.activeAccountID, b.id)
        XCTAssertNotNil(result.backupID)
        XCTAssertEqual(home.runtime.startCalled, 1)
        XCTAssertFalse(try SafeFiles.exists(home.paths.transaction))
    }

    func testExternalDroidBlocksSwitchWithoutQuitting() async throws {
        let home = try TestHome()
        let a = try home.material()
        try home.setLive(a)
        _ = try home.save(a, active: true)
        let b = try home.save(home.material(user: "user-b", org: "org-b"))
        home.runtime.current.externalDroidPIDs = [99]
        do { _ = try await home.engine.switchAccount(b.id); XCTFail("Should block") } catch {}
        XCTAssertEqual(home.runtime.stopCalled, 0)
        XCTAssertEqual(try home.store.auth.load(home: home.paths.factory)?.encrypted, a.encrypted)
    }

    func testQuitFailureNeverChangesLiveLogin() async throws {
        let home = try TestHome()
        let a = try home.material()
        try home.setLive(a)
        _ = try home.save(a, active: true)
        let b = try home.save(home.material(user: "user-b", org: "org-b"))
        home.runtime.failStop = true
        do { _ = try await home.engine.switchAccount(b.id); XCTFail("Should fail") } catch {}
        XCTAssertEqual(try home.store.auth.load(home: home.paths.factory)?.encrypted, a.encrypted)
    }

    func testKeychainFailureRollsBackAuthAndSelection() async throws {
        let home = try TestHome()
        let aMaterial = try home.material(keyByte: 17)
        try home.setLive(aMaterial)
        let a = try home.save(aMaterial, active: true)
        let b = try home.save(home.material(user: "user-b", org: "org-b", keyByte: 34))
        home.keys.failFactoryWriteOnce = true
        do { _ = try await home.engine.switchAccount(b.id); XCTFail("Should fail") } catch {}
        XCTAssertEqual(try home.store.auth.load(home: home.paths.factory)?.encrypted, aMaterial.encrypted)
        XCTAssertEqual(try home.store.loadState().activeAccountID, a.id)
        XCTAssertFalse(try SafeFiles.exists(home.paths.transaction))
    }

    func testBackupFailurePreventsAnyLoginReplacement() async throws {
        let home = try TestHome()
        let aMaterial = try home.material()
        try home.setLive(aMaterial)
        _ = try home.save(aMaterial, active: true)
        let b = try home.save(home.material(user: "user-b", org: "org-b"))
        home.keys.failSwitcherWrite = true
        home.runtime.current.factoryRunning = true
        do { _ = try await home.engine.switchAccount(b.id); XCTFail("Should fail") } catch {}
        XCTAssertEqual(try home.store.auth.load(home: home.paths.factory)?.encrypted, aMaterial.encrypted)
        XCTAssertEqual(home.runtime.startCalled, 1)
    }

    func testKeyfileSwitchDisplacesSecureFilesAndKeepsSecretOutOfBackupFiles() async throws {
        let home = try TestHome()
        let aMaterial = try home.material(format: .keyfile)
        try home.setLive(aMaterial)
        _ = try home.save(aMaterial, active: true)
        let b = try home.save(home.material(user: "user-b", org: "org-b", format: .loginKeychain))
        let result = try await home.engine.switchAccount(b.id)
        XCTAssertFalse(try SafeFiles.exists(home.paths.factory.appendingPathComponent("auth.v2.key")))
        XCTAssertFalse(try SafeFiles.exists(home.paths.factory.appendingPathComponent("auth.v2.file")))
        let backupID = try XCTUnwrap(result.backupID)
        let backupRoot = try Backups(store: home.store).directory(backupID)
        XCTAssertFalse(try SafeFiles.exists(backupRoot.appendingPathComponent("auth/auth.v2.key")))
        let backup = try Backups(store: home.store).read(backupID)
        XCTAssertNotNil(backup.fileKeyReference)
    }

    func testFailedRelaunchKeepsCommittedTargetAccount() async throws {
        let home = try TestHome()
        let material = try home.material()
        try home.setLive(material)
        _ = try home.save(material, active: true)
        let b = try home.save(home.material(user: "user-b", org: "org-b"))
        home.runtime.failStart = true
        let result = try await home.engine.switchAccount(b.id)
        XCTAssertNotNil(result.warning)
        XCTAssertEqual(try home.store.loadState().activeAccountID, b.id)
        XCTAssertEqual(try home.store.auth.load(home: home.paths.factory)?.credentials.identity().userID, "user-b")
    }

    func testCrashJournalRecoveryRestoresOriginalLogin() async throws {
        let home = try TestHome()
        let original = try home.material()
        try home.setLive(original)
        let a = try home.save(original, active: true)
        let bMaterial = try home.material(user: "user-b", org: "org-b")
        let b = try home.save(bMaterial)
        let backup = try Backups(store: home.store).prepare(state: home.store.loadState(), targetAccountID: b.id)
        try SafeFiles.atomicWrite(
            SafeFiles.encode(TransactionRecord(backupID: backup.id, committed: false)), to: home.paths.transaction
        )
        try home.setLive(bMaterial)
        try await home.engine.recoverInterruptedOperation()
        XCTAssertEqual(try home.store.auth.load(home: home.paths.factory)?.encrypted, original.encrypted)
        XCTAssertEqual(try home.store.loadState().activeAccountID, a.id)
    }

    func testCorruptBackupCannotOverwriteLiveAuth() throws {
        let home = try TestHome()
        let original = try home.material()
        try home.setLive(original)
        _ = try home.save(original, active: true)
        let backups = Backups(store: home.store)
        let manifest = try backups.prepare(state: home.store.loadState(), targetAccountID: nil)
        let path = try backups.directory(manifest.id).appendingPathComponent("auth/auth.v2.loginkeychain")
        try SafeFiles.atomicWrite(Data("tampered".utf8), to: path)
        XCTAssertThrowsError(try backups.restoreAuth(manifest))
        XCTAssertEqual(try home.store.auth.load(home: home.paths.factory)?.encrypted, original.encrypted)
    }

    func testLiveDifferentUserNeverOverwritesOldActiveProfile() async throws {
        let home = try TestHome()
        let a = try home.save(home.material(), active: true)
        try home.setLive(home.material(user: "user-b", org: "org-b"))
        let state = try await home.engine.synchronize()
        XCTAssertEqual(try home.store.load(a).credentials.identity().userID, "user-a")
        XCTAssertEqual(state.accounts.count, 2)
        XCTAssertNotEqual(state.activeAccountID, a.id)
    }

    func testProcessClassificationDoesNotConfuseFactoryDaemonWithTerminal() {
        let text = "10 1 /Applications/Factory.app/Contents/MacOS/Factory\n11 10 /Applications/Factory.app/Contents/Resources/bin/droid\n12 1 /Users/test/.local/bin/droid\n13 1 /Applications/Claude.app/Contents/MacOS/Claude"
        let status = ProcessInspection.classify(ProcessInspection.parse(text), factoryPIDs: [10])
        XCTAssertTrue(status.factoryRunning)
        XCTAssertEqual(status.droidPIDs, [11, 12])
        XCTAssertEqual(status.externalDroidPIDs, [12])
    }

    func testWriteThenVerificationFailureRestoresBothKeyAndCiphertext() async throws {
        let home = try TestHome()
        let original = try home.material(keyByte: 17)
        try home.setLive(original)
        let a = try home.save(original, active: true)
        let b = try home.save(home.material(user: "user-b", org: "org-b", keyByte: 34))
        home.keys.failFactoryWriteAfterMutationOnce = true
        do { _ = try await home.engine.switchAccount(b.id); XCTFail("Should fail") } catch {}
        XCTAssertEqual(try home.store.auth.load(home: home.paths.factory)?.encrypted, original.encrypted)
        XCTAssertEqual(try home.store.loadState().activeAccountID, a.id)
    }

    func testUserRelaunchDuringSwitchLeavesRecoverableJournal() async throws {
        let home = try TestHome()
        let original = try home.material()
        try home.setLive(original)
        let a = try home.save(original, active: true)
        let b = try home.save(home.material(user: "user-b", org: "org-b"))
        home.runtime.statusHook = { call in
            call >= 4 ? RuntimeStatus(factoryRunning: true, droidPIDs: [88], externalDroidPIDs: []) : nil
        }
        do { _ = try await home.engine.switchAccount(b.id); XCTFail("Should defer rollback") } catch {}
        XCTAssertTrue(try SafeFiles.exists(home.paths.transaction))
        home.runtime.statusHook = nil
        try await home.engine.recoverInterruptedOperation()
        XCTAssertEqual(try home.store.auth.load(home: home.paths.factory)?.encrypted, original.encrypted)
        XCTAssertEqual(try home.store.loadState().activeAccountID, a.id)
    }

    func testRecoveryKeepsTargetTokensRotatedAfterInterruption() async throws {
        let home = try TestHome()
        let original = try home.material()
        try home.setLive(original)
        let a = try home.save(original, active: true)
        let b = try home.save(home.material(user: "user-b", org: "org-b", refresh: "b-before", keyByte: 34))
        home.runtime.statusHook = { call in
            call >= 4 ? RuntimeStatus(factoryRunning: true, droidPIDs: [88], externalDroidPIDs: []) : nil
        }
        do { _ = try await home.engine.switchAccount(b.id); XCTFail("Should defer rollback") } catch {}
        // The user keeps working as B and Factory rotates B's refresh token.
        try home.setLive(home.material(user: "user-b", org: "org-b", refresh: "b-rotated", keyByte: 34))
        home.runtime.statusHook = nil
        try await home.engine.recoverInterruptedOperation()
        let state = try home.store.loadState()
        let savedB = try XCTUnwrap(state.accounts.first { $0.id == b.id })
        XCTAssertEqual(try home.store.load(savedB).credentials.refreshToken, "b-rotated")
        XCTAssertEqual(try home.store.auth.load(home: home.paths.factory)?.encrypted, original.encrypted)
        XCTAssertEqual(state.activeAccountID, a.id)
    }

    func testCommittedJournalCleanupNeverResurrectsOriginalAccount() async throws {
        let home = try TestHome()
        let original = try home.material()
        try home.setLive(original)
        _ = try home.save(original, active: true)
        let target = try home.material(user: "user-b", org: "org-b")
        let b = try home.save(target)
        let backup = try Backups(store: home.store).prepare(state: home.store.loadState(), targetAccountID: b.id)
        try home.setLive(target)
        var state = try home.store.loadState()
        state.activeAccountID = b.id
        try home.store.saveState(state)
        try SafeFiles.atomicWrite(
            SafeFiles.encode(TransactionRecord(backupID: backup.id, committed: true)), to: home.paths.transaction
        )
        home.runtime.current.factoryRunning = true
        try await home.engine.recoverInterruptedOperation()
        XCTAssertEqual(try home.store.auth.load(home: home.paths.factory)?.encrypted, target.encrypted)
        XCTAssertEqual(try home.store.loadState().activeAccountID, b.id)
        XCTAssertEqual(home.runtime.stopCalled, 0)
    }

    func testCorruptBackupKeyIsRejectedBeforeChangingCurrentKey() throws {
        let home = try TestHome()
        let original = try home.material()
        try home.setLive(original)
        _ = try home.save(original, active: true)
        let backups = Backups(store: home.store)
        let backup = try backups.prepare(state: home.store.loadState(), targetAccountID: nil)
        let reference = try XCTUnwrap(backup.systemKeyReference)
        try home.keys.write(Data("invalid-key".utf8), service: KeychainNames.switcherService, account: reference)
        XCTAssertThrowsError(try backups.restoreAuth(backup))
        XCTAssertEqual(try home.store.auth.load(home: home.paths.factory)?.encrypted, original.encrypted)
    }
}
