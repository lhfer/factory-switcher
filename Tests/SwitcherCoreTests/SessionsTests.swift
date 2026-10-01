import Foundation
import XCTest
@testable import SwitcherCore

final class SessionsTests: XCTestCase {
    func testOnlySelectedSessionHeaderChangesAndBackupIsExact() async throws {
        let home = try TestHome()
        let material = try home.material()
        try home.setLive(material)
        _ = try home.save(material, active: true)
        let b = try home.save(home.material(user: "user-b", org: "org-b"))
        let (selectedID, selected, original) = try home.session(title: "选中")
        let (_, untouched, untouchedData) = try home.session(title: "未选中")
        try home.enableSharing([selectedID])
        let result = try await home.engine.switchAccount(b.id)
        let shared = try SafeFiles.read(selected)
        let header = try JSONDecoder().decode([String: JSONValue].self, from: SessionFiles.firstLine(selected))
        XCTAssertNil(header["organizationId"])
        XCTAssertEqual(header["untouched"], .integer(42))
        XCTAssertEqual(shared.split(separator: 10).dropFirst(), original.split(separator: 10).dropFirst())
        XCTAssertEqual(try SafeFiles.read(untouched), untouchedData)
        let manifest = try Backups(store: home.store).read(XCTUnwrap(result.backupID))
        XCTAssertEqual(manifest.sessions.count, 1)
        let backup = try Backups(store: home.store).directory(manifest.id)
            .appendingPathComponent("sessions").appendingPathComponent(manifest.sessions[0].relativePath)
        XCTAssertEqual(try SafeFiles.read(backup), original)
    }

    func testSessionRestoreKeepsNewMessages() throws {
        let home = try TestHome()
        let (id, url, _) = try home.session()
        let backup = home.paths.backups.appendingPathComponent("session-test")
        let edits = try SessionFiles.prepare(root: home.paths.sessions, selectedIDs: [id], backup: backup)
        try SessionFiles.apply(edits, root: home.paths.sessions)
        var appended = try SafeFiles.read(url)
        let newMessage = Data("{\"type\":\"message\",\"content\":\"later message\"}\n".utf8)
        appended.append(newMessage)
        try SafeFiles.atomicWrite(appended, to: url)
        try SessionFiles.restore(edits, root: home.paths.sessions, backup: backup)
        let header = try JSONDecoder().decode([String: JSONValue].self, from: SessionFiles.firstLine(url))
        XCTAssertEqual(header["organizationId"], .string("org-a"))
        XCTAssertTrue(try SafeFiles.read(url).suffix(newMessage.count) == newMessage)
    }

    func testModifiedSessionIsNotOverwrittenAfterPreparation() throws {
        let home = try TestHome()
        let (id, url, _) = try home.session()
        let backup = home.paths.backups.appendingPathComponent("session-test")
        let edits = try SessionFiles.prepare(root: home.paths.sessions, selectedIDs: [id], backup: backup)
        var changed = try SafeFiles.read(url)
        changed.append(Data("{\"type\":\"message\"}\n".utf8))
        try SafeFiles.atomicWrite(changed, to: url)
        XCTAssertThrowsError(try SessionFiles.apply(edits, root: home.paths.sessions))
        XCTAssertEqual(try SafeFiles.read(url), changed)
    }

    func testScannerSkipsSymlinkAndMalformedSession() throws {
        let home = try TestHome()
        let (id, real, _) = try home.session()
        let link = home.paths.sessions.appendingPathComponent("linked.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let invalid = home.paths.sessions.appendingPathComponent("invalid.jsonl")
        try SafeFiles.atomicWrite(Data("not json\n".utf8), to: invalid)
        let sessions = try SessionFiles.scan(root: home.paths.sessions)
        XCTAssertEqual(sessions.map(\.id), [id])
    }

    func testEmptySelectionDoesNotRewriteAnySessions() async throws {
        let home = try TestHome()
        let original = try home.material()
        try home.setLive(original)
        _ = try home.save(original, active: true)
        let target = try home.save(home.material(user: "user-b", org: "org-b"))
        let (_, file, data) = try home.session()
        let result = try await home.engine.switchAccount(target.id)
        XCTAssertEqual(result.sharedSessionCount, 0)
        XCTAssertEqual(try SafeFiles.read(file), data)
    }

    func testRestoreRefusesUnexpectedOrganizationWithoutLosingMessages() throws {
        let home = try TestHome()
        let (id, file, _) = try home.session()
        let backup = home.paths.backups.appendingPathComponent("session-test")
        let edits = try SessionFiles.prepare(root: home.paths.sessions, selectedIDs: [id], backup: backup)
        try SessionFiles.apply(edits, root: home.paths.sessions)
        var header = try JSONDecoder().decode([String: JSONValue].self, from: SessionFiles.firstLine(file))
        header["organizationId"] = .string("org-unexpected")
        var data = try SafeFiles.encode(header)
        data.append(contentsOf: "\n{\"type\":\"message\",\"content\":\"keep this\"}\n".utf8)
        try SafeFiles.atomicWrite(data, to: file)
        XCTAssertThrowsError(try SessionFiles.restore(edits, root: home.paths.sessions, backup: backup))
        XCTAssertEqual(try SafeFiles.read(file), data)
    }

    func testStreamingHeaderEditKeepsLargeMessageBodyByteForByte() throws {
        let home = try TestHome()
        let (id, file, _) = try home.session()
        var data = try SessionFiles.firstLine(file)
        let body = Data(repeating: 97, count: 3 * 1024 * 1024)
        data.append(body)
        try SafeFiles.atomicWrite(data, to: file)
        let backup = home.paths.backups.appendingPathComponent("session-test")
        let edits = try SessionFiles.prepare(root: home.paths.sessions, selectedIDs: [id], backup: backup)
        try SessionFiles.apply(edits, root: home.paths.sessions)
        XCTAssertEqual(try SafeFiles.read(file).suffix(body.count), body)
    }
}
