import Foundation

public struct HTTPReply: Sendable {
    public let status: Int
    public let data: Data

    public init(status: Int, data: Data) { self.status = status; self.data = data }
}

public protocol HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPReply
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Do not carry authentication to a redirect destination.
        completionHandler(nil)
    }
}

public final class QuotaTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> HTTPReply {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, data.count <= 2 * 1024 * 1024 else {
                throw SwitcherError.message("额度接口响应格式或大小异常。")
            }
            return HTTPReply(status: response.statusCode, data: data)
        } catch let error as SwitcherError {
            throw error
        } catch {
            throw SwitcherError.message("无法连接额度服务，保留上次查询结果。")
        }
    }
}

public struct QuotaWindow: Codable, Equatable, Sendable {
    public let name: String
    public let usedPercent: Double?
    public let windowEnd: Date?

    public func text(now: Date = Date()) -> String {
        guard let used = usedPercent, used.isFinite, used >= 0 else { return "\(name)：未知" }
        if let windowEnd, windowEnd <= now {
            let bounded = min(100, used)
            return "\(name)：待开启（上次已用 \(Int(bounded.rounded()))%）"
        }
        let remaining = Int(max(0, min(100, 100 - used)).rounded())
        return "\(name)：剩余 \(remaining)%"
    }
}

public struct QuotaGroup: Codable, Equatable, Sendable {
    public let name: String
    public let windows: [QuotaWindow]
}

public struct QuotaReport: Codable, Equatable, Sendable {
    public let groups: [QuotaGroup]
    public let extraUsageBalanceCents: Double?
    public let fetchedAt: Date
    public let note: String?

    public var summary: String {
        guard let group = groups.first(where: { $0.name == "standard" }) ?? groups.first else {
            return note ?? "未提供窗口额度"
        }
        return group.windows.prefix(3).map { $0.text() }.joined(separator: " · ")
    }

    public static func parse(_ data: Data, now: Date = Date()) throws -> QuotaReport {
        guard let root = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            throw SwitcherError.message("额度响应无法解析，不会显示推测的额度。")
        }
        var groups: [QuotaGroup] = []
        if case .object(let rawGroups) = root["limits"] {
            for (name, raw) in rawGroups {
                guard case .object(let rawWindows) = raw else { continue }
                let known = ["fiveHour", "weekly", "monthly"]
                let ordered = known.filter { rawWindows[$0] != nil } + rawWindows.keys.filter { !known.contains($0) }.sorted()
                var windows: [QuotaWindow] = []
                for key in ordered {
                    guard case .object(let record) = rawWindows[key] else { continue }
                    let labels = ["fiveHour": "5小时", "weekly": "周", "monthly": "月"]
                    var end: Date?
                    if let text = record["windowEnd"]?.string { end = parseDate(text) }
                    if end == nil, let seconds = record["secondsRemaining"]?.number,
                       seconds.isFinite, seconds <= 366 * 24 * 3600 {
                        end = now.addingTimeInterval(max(0, seconds))
                    }
                    windows.append(QuotaWindow(name: labels[key] ?? key, usedPercent: record["usedPercent"]?.number, windowEnd: end))
                }
                if !windows.isEmpty { groups.append(QuotaGroup(name: name, windows: windows)) }
            }
        }
        groups.sort {
            if $0.name == "standard" { return $1.name != "standard" }
            if $1.name == "standard" { return false }
            return $0.name < $1.name
        }
        let note: String? = groups.isEmpty ? "此套餐未提供可识别的窗口额度" : nil
        return QuotaReport(
            groups: groups, extraUsageBalanceCents: root["extraUsageBalanceCents"]?.number,
            fetchedAt: now, note: note
        )
    }

    public static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

public final class QuotaClient {
    private let transport: HTTPTransport
    private let version: String

    public init(transport: HTTPTransport, version: String = "0.230.0") {
        self.transport = transport
        self.version = version
    }

    public func fetch(_ credentials: Credentials) async throws -> QuotaReport {
        var request = URLRequest(url: URL(string: "https://api.factory.ai/api/billing/limits")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("cli", forHTTPHeaderField: "X-Factory-Client")
        request.setValue(version, forHTTPHeaderField: "X-Client-Version")
        if let org = credentials.activeOrganizationID {
            request.setValue(org, forHTTPHeaderField: "X-Factory-Org-Id")
        }
        let response = try await transport.send(request)
        switch response.status {
        case 200..<300: return try QuotaReport.parse(response.data)
        case 401: throw SwitcherError.message("当前额度查询的登录已过期，请打开 Factory 续期或重新登录。")
        case 403: throw SwitcherError.message("这个账号无权查看所选组织的额度。")
        case 429: throw SwitcherError.message("查询过于频繁，请稍后再试。")
        default: throw SwitcherError.message("额度服务返回 HTTP \(response.status)，保留上次结果。")
        }
    }

    public func refresh(_ credentials: Credentials) async throws -> Credentials {
        var request = URLRequest(url: URL(string: "https://api.workos.com/user_management/authenticate")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let form = [
            ("grant_type", "refresh_token"),
            ("client_id", "client_01HNM792M5G5G1A2THWPXKFMXB"),
            ("refresh_token", credentials.refreshToken),
        ]
        request.httpBody = Data(form.map {
            "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        // One request only: retries could reuse an already-rotated refresh token.
        let response = try await transport.send(request)
        guard (200..<300).contains(response.status) else {
            if response.status == 400 || response.status == 401 {
                throw SwitcherError.message("保存的登录已失效，请使用官方 Droid 重新登录该账号。")
            }
            throw SwitcherError.message("登录续期暂时失败（HTTP \(response.status)），没有更改保存的登录。")
        }
        guard let fields = try? JSONDecoder().decode([String: JSONValue].self, from: response.data),
              let access = fields["access_token"]?.string,
              let refresh = fields["refresh_token"]?.string else {
            throw SwitcherError.message("登录续期响应不完整，请重新登录。")
        }
        var updated = credentials
        try updated.replaceTokens(access: access, refresh: refresh)
        guard try updated.identity().userID == credentials.identity().userID else {
            throw SwitcherError.message("登录续期的账号身份不匹配。")
        }
        return updated
    }
}
