import Foundation

public enum SwitcherError: Error, LocalizedError, Equatable {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(UInt64.self) { self = .unsignedInteger(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .unsignedInteger(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var number: Double? {
        if case .number(let value) = self { return value }
        if case .integer(let value) = self { return Double(value) }
        if case .unsignedInteger(let value) = self { return Double(value) }
        return nil
    }
}

public enum AuthFormat: String, Codable, CaseIterable, Sendable {
    case loginKeychain
    case keyfile

    public var filename: String {
        self == .loginKeychain ? "auth.v2.loginkeychain" : "auth.v2.file"
    }

    public static let managedFilenames = [
        "auth.v2.loginkeychain", "auth.v2.file", "auth.v2.key", "auth.v2.keyring",
    ]
}

public struct Account: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var label: String
    public var email: String?
    public let userID: String
    public let organizationID: String?
    public var format: AuthFormat
    public var keyReference: String
    public var snapshotID: String
    public var updatedAt: Date

    public var displayName: String { label.isEmpty ? (email ?? "未命名账号") : label }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var showQuota = true
    public var shareSessions = true
    public var confirmSwitch = true
    public var selectedSessionIDs: [String] = []

    public init() {}
}

public struct StoreState: Codable, Equatable, Sendable {
    public var version = 1
    public var activeAccountID: String?
    public var accounts: [Account] = []
    public var preferences = Preferences()
    public var pendingLogins: [PendingLogin] = []

    public init() {}

    public func validate() throws {
        guard version == 1 else { throw SwitcherError.message("账号状态版本不受支持。") }
        var accountIDs = Set<String>()
        for account in accounts {
            try SwitcherPaths.validateID(account.id)
            try SwitcherPaths.validateID(account.keyReference)
            try SwitcherPaths.validateID(account.snapshotID)
            guard !account.userID.isEmpty, accountIDs.insert(account.id).inserted else {
                throw SwitcherError.message("账号状态中存在无效或重复记录。")
            }
        }
        if let activeAccountID, !accountIDs.contains(activeAccountID) {
            throw SwitcherError.message("当前账号记录与已保存账号不匹配。")
        }
        var loginIDs = Set<String>()
        for login in pendingLogins {
            try SwitcherPaths.validateID(login.id)
            guard loginIDs.insert(login.id).inserted else {
                throw SwitcherError.message("待添加账号记录重复。")
            }
        }
        for id in preferences.selectedSessionIDs { try SwitcherPaths.validateID(id) }
    }
}

public struct PendingLogin: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString.lowercased(), label: String, createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.createdAt = createdAt
    }
}

public struct AccountIdentity: Equatable, Sendable {
    public let userID: String
    public let email: String?
    public let organizationID: String?

    public func matches(_ account: Account) -> Bool {
        userID == account.userID && organizationID == account.organizationID
    }
}
