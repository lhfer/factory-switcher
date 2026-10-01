import Darwin
import Foundation
import SwitcherCore

final class MemoryKeys: KeyStore {
    var values: [String: Data] = [:]
    var failFactoryWriteOnce = false
    var failFactoryWriteAfterMutationOnce = false
    var failSwitcherWrite = false

    private func id(_ service: String, _ account: String) -> String { "\(service)|\(account)" }

    func read(service: String, account: String) throws -> Data? { values[id(service, account)] }
    func write(_ value: Data, service: String, account: String) throws {
        if service == KeychainNames.factoryService && failFactoryWriteOnce {
            failFactoryWriteOnce = false
            throw SwitcherError.message("模拟钥匙串写入失败。")
        }
        if service == KeychainNames.switcherService && failSwitcherWrite {
            throw SwitcherError.message("模拟备份密钥写入失败。")
        }
        values[id(service, account)] = value
        if service == KeychainNames.factoryService && failFactoryWriteAfterMutationOnce {
            failFactoryWriteAfterMutationOnce = false
            throw SwitcherError.message("模拟钥匙串写入后校验失败。")
        }
    }
    func delete(service: String, account: String) throws { values.removeValue(forKey: id(service, account)) }
}

final class FakeRuntime: FactoryRuntime {
    var current = RuntimeStatus(factoryRunning: false, droidPIDs: [], externalDroidPIDs: [])
    var stopCalled = 0
    var startCalled = 0
    var failStop = false
    var failStart = false
    var onStop: (() throws -> Void)?
    var statusCalls = 0
    var statusHook: ((Int) -> RuntimeStatus?)?

    func status() async throws -> RuntimeStatus {
        statusCalls += 1
        return statusHook?(statusCalls) ?? current
    }
    func stopFactory() async throws {
        stopCalled += 1
        if failStop { throw SwitcherError.message("模拟退出失败。") }
        current = RuntimeStatus(factoryRunning: false, droidPIDs: [], externalDroidPIDs: [])
        try onStop?()
    }
    func startFactory() async throws {
        startCalled += 1
        if failStart { throw SwitcherError.message("模拟打开失败。") }
        current = RuntimeStatus(factoryRunning: true, droidPIDs: [], externalDroidPIDs: [])
    }
}

final class FakeHTTP: HTTPTransport {
    var requests: [URLRequest] = []
    var replies: [HTTPReply] = []
    var sendHook: (() async throws -> Void)?

    func send(_ request: URLRequest) async throws -> HTTPReply {
        requests.append(request)
        try await sendHook?()
        guard !replies.isEmpty else { throw SwitcherError.message("测试禁止访问真实网络。") }
        return replies.removeFirst()
    }
}

final class TestHome {
    let temporary: URL
    let paths: SwitcherPaths
    let keys = MemoryKeys()
    let runtime = FakeRuntime()
    let http = FakeHTTP()
    let store: AccountStore
    let engine: SwitcherEngine

    init() throws {
        // Foundation leaves macOS's /var alias unresolved on some releases.
        // Use realpath so the test itself does not violate symlink protection.
        guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw SwitcherError.message("无法确定测试临时目录。")
        }
        defer { free(physical) }
        temporary = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("factory-switcher-test-\(UUID().uuidString)", isDirectory: true)
        paths = SwitcherPaths(
            root: temporary.appendingPathComponent("switcher"),
            factory: temporary.appendingPathComponent("factory")
        )
        try SafeFiles.ensureDirectory(paths.factory)
        store = AccountStore(paths: paths, keys: keys)
        engine = SwitcherEngine(store: store, runtime: runtime, quota: QuotaClient(transport: http))
    }

    deinit { try? FileManager.default.removeItem(at: temporary) }

    func material(
        user: String = "user-a", org: String = "org-a", refresh: String = "synthetic-refresh",
        expired: Bool = false, format: AuthFormat = .loginKeychain, keyByte: UInt8 = 17
    ) throws -> AuthMaterial {
        let token = try jwt(user: user, org: org, expired: expired)
        let fields: [String: JSONValue] = [
            "access_token": .string(token), "refresh_token": .string(refresh),
            "active_organization_id": .string(org),
            "whoami": .object(["region": .string("test-region")]),
            "future_field": .object(["keep": .bool(true)]),
        ]
        let key = Data(repeating: keyByte, count: 32)
        return try AuthMaterial(
            format: format, encrypted: AuthCrypto.encrypt(SafeFiles.encode(fields), key: key), key: key
        )
    }

    func jwt(user: String, org: String, expired: Bool = false) throws -> String {
        let payload: [String: JSONValue] = [
            "sub": .string(user), "email": .string("\(user)@example.test"), "org_id": .string(org),
            "exp": .number(Date().addingTimeInterval(expired ? -3600 : 7200).timeIntervalSince1970),
        ]
        let encoded = try SafeFiles.encode(payload).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(encoded).synthetic"
    }

    func setLive(_ material: AuthMaterial) throws {
        if material.format == .loginKeychain {
            try keys.write(
                Data(material.key.base64EncodedString().utf8),
                service: KeychainNames.factoryService, account: KeychainNames.factoryAccount
            )
        } else {
            try SafeFiles.atomicWrite(
                Data(material.key.base64EncodedString().utf8), to: paths.factory.appendingPathComponent("auth.v2.key")
            )
        }
        try SafeFiles.atomicWrite(Data(material.encrypted.utf8), to: paths.factory.appendingPathComponent(material.format.filename))
    }

    func save(_ material: AuthMaterial, active: Bool = false) throws -> Account {
        var state = try store.loadState()
        return try store.importMaterial(material, active: active, state: &state)
    }

    func session(org: String = "org-a", title: String = "测试对话") throws -> (String, URL, Data) {
        let id = UUID().uuidString.lowercased()
        let url = paths.sessions.appendingPathComponent("project").appendingPathComponent("\(id).jsonl")
        let first: [String: JSONValue] = [
            "type": .string("session_start"), "id": .string(id), "title": .string(title),
            "organizationId": .string(org), "untouched": .number(42),
        ]
        var data = try SafeFiles.encode(first)
        data.append(contentsOf: "\n{\"type\":\"message\",\"content\":\"synthetic private content\"}\n".utf8)
        try SafeFiles.atomicWrite(data, to: url)
        return (id, url, data)
    }

    func enableSharing(_ ids: [String]) throws {
        var state = try store.loadState()
        state.preferences.shareSessions = true
        state.preferences.selectedSessionIDs = ids
        try store.saveState(state)
    }
}
