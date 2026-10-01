import Foundation
import XCTest
@testable import SwitcherCore

final class CryptoAndFilesTests: XCTestCase {
    func testNodeAESGCM16ByteNonceInteroperability() throws {
        let vector = "IiIiIiIiIiIiIiIiIiIiIg==:66lyW7Ircaobv+C4x2Ahfw==:WtJyW/GV5pJgho9DrERYVie0AdFILV3l31vvYJf9Hm+j5shoCK4="
        let plain = try AuthCrypto.decrypt(vector, key: Data(repeating: 0x11, count: 32))
        XCTAssertEqual(String(data: plain, encoding: .utf8), "Factory Switcher interoperability test")
    }

    func testTamperAndWrongKeyRejected() throws {
        let home = try TestHome()
        let auth = try home.material()
        XCTAssertThrowsError(try AuthCrypto.decrypt(auth.encrypted, key: Data(repeating: 0x55, count: 32)))
        XCTAssertThrowsError(try AuthCrypto.decrypt("not:a:ciphertext", key: auth.key))
        XCTAssertThrowsError(try AuthCrypto.encrypt(Data(), key: Data()))
    }

    func testCredentialsPreserveUnknownFields() throws {
        let home = try TestHome()
        let original = try home.material()
        var credentials = original.credentials
        try credentials.replaceTokens(access: home.jwt(user: "user-a", org: "org-a"), refresh: "rotated-synthetic")
        let updated = try original.replacing(credentials)
        XCTAssertEqual(updated.credentials.fields["future_field"], original.credentials.fields["future_field"])
        XCTAssertEqual(updated.credentials.fields["whoami"], original.credentials.fields["whoami"])
        XCTAssertEqual(updated.credentials.refreshToken, "rotated-synthetic")
    }

    func testSymlinkReadAndWriteRejected() throws {
        let home = try TestHome()
        let victim = home.temporary.appendingPathComponent("victim")
        try SafeFiles.atomicWrite(Data("unchanged".utf8), to: victim)
        let link = home.paths.factory.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
        XCTAssertThrowsError(try SafeFiles.read(link))
        XCTAssertThrowsError(try SafeFiles.atomicWrite(Data("changed".utf8), to: link))
        XCTAssertEqual(try SafeFiles.read(victim), Data("unchanged".utf8))
    }

    func testPrivateModesAndExclusiveLock() throws {
        let home = try TestHome()
        let file = home.paths.root.appendingPathComponent("private")
        try SafeFiles.atomicWrite(Data("test".utf8), to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let lock = try StoreLock(root: home.paths.root)
        XCTAssertThrowsError(try StoreLock(root: home.paths.root))
        withExtendedLifetime(lock) {}
    }

    func testCorruptStateNeverOverwritten() throws {
        let home = try TestHome()
        let bad = Data("{broken".utf8)
        try SafeFiles.atomicWrite(bad, to: home.paths.state)
        XCTAssertThrowsError(try home.store.loadState())
        XCTAssertEqual(try SafeFiles.read(home.paths.state), bad)
    }

    func testAccountIdentityMismatchAndTraversalRejected() throws {
        let home = try TestHome()
        let saved = try home.save(home.material())
        var forged = saved
        forged.snapshotID = "../outside"
        XCTAssertThrowsError(try home.store.load(forged))
        XCTAssertThrowsError(try home.paths.accountRoot("../../secrets"))
        XCTAssertThrowsError(try SessionFiles.scoped("../outside", root: home.paths.sessions))
    }

    func testPhysicalTemporaryPathSurvivesExistingDirectoryNormalization() throws {
        let home = try TestHome()
        let reloaded = SwitcherPaths(root: home.paths.root, factory: home.paths.factory)
        XCTAssertEqual(reloaded.factory.path, home.paths.factory.path)
        XCTAssertTrue(try SafeFiles.exists(reloaded.factory))
        let path = reloaded.factory.appendingPathComponent("existing-file")
        try SafeFiles.atomicWrite(Data("safe".utf8), to: path)
        XCTAssertEqual(try SafeFiles.read(path), Data("safe".utf8))
    }

    func testParentSymlinkCannotBeUsedToEscapePrivateStore() throws {
        let home = try TestHome()
        let link = home.paths.factory.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.temporary)
        XCTAssertThrowsError(try SafeFiles.atomicWrite(Data("test".utf8), to: link.appendingPathComponent("escape")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.temporary.appendingPathComponent("escape").path))
    }

    func testUnchangedSyncDoesNotAccumulateSnapshotsAndForgetStaysForgotten() async throws {
        let home = try TestHome()
        let material = try home.material()
        try home.setLive(material)
        let a = try home.save(material, active: true)
        for _ in 0..<3 { _ = try await home.engine.synchronize() }
        let entries = try FileManager.default.contentsOfDirectory(at: home.paths.accountRoot(a.id), includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.count, 1)
        let other = try home.save(home.material(user: "user-b", org: "org-b"))
        try await home.engine.forget(a.id)
        let state = try await home.engine.synchronize(importUnknown: false)
        XCTAssertEqual(state.accounts.map(\.id), [other.id])
        XCTAssertNil(state.activeAccountID)
        XCTAssertEqual(try home.store.auth.load(home: home.paths.factory)?.encrypted, material.encrypted)
    }

    func testTokenReplacementPreservesUnknown64BitIntegers() throws {
        var credentials = try Credentials(data: Data("""
        {"access_token":"synthetic","refresh_token":"synthetic","future_integer":9223372036854775807,"future_unsigned":18446744073709551615}
        """.utf8))
        try credentials.replaceTokens(access: "next-synthetic", refresh: "next-refresh")
        let encoded = String(data: try credentials.encoded(), encoding: .utf8)!
        XCTAssertTrue(encoded.contains("9223372036854775807"))
        XCTAssertTrue(encoded.contains("18446744073709551615"))
    }

    func testRemoveRefusesDirectoriesAndPreservesTheirContents() throws {
        let home = try TestHome()
        let directory = home.paths.factory.appendingPathComponent("auth.v2.file")
        let contents = directory.appendingPathComponent("keep")
        try SafeFiles.atomicWrite(Data("keep".utf8), to: contents)
        XCTAssertThrowsError(try SafeFiles.remove(directory))
        XCTAssertEqual(try SafeFiles.read(contents), Data("keep".utf8))
    }
}
