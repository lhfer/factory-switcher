import Foundation

public struct RuntimeStatus: Sendable {
    public var factoryRunning: Bool
    public var droidPIDs: [Int32]
    public var externalDroidPIDs: [Int32]

    public init(factoryRunning: Bool, droidPIDs: [Int32], externalDroidPIDs: [Int32]) {
        self.factoryRunning = factoryRunning
        self.droidPIDs = droidPIDs
        self.externalDroidPIDs = externalDroidPIDs
    }

    public var quiescent: Bool { !factoryRunning && droidPIDs.isEmpty }
}

public protocol FactoryRuntime: AnyObject {
    func status() async throws -> RuntimeStatus
    func stopFactory() async throws
    func startFactory() async throws
}

public struct ProcessRecord: Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let executable: String
}

public enum ProcessInspection {
    public static func parse(_ text: String) -> [ProcessRecord] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 3, let pid = Int32(parts[0]), let parent = Int32(parts[1]) else { return nil }
            return ProcessRecord(pid: pid, parentPID: parent, executable: String(parts[2]))
        }
    }

    public static func classify(_ processes: [ProcessRecord], factoryPIDs: Set<Int32>) -> RuntimeStatus {
        let parents = Dictionary(processes.map { ($0.pid, $0.parentPID) }, uniquingKeysWith: { first, _ in first })
        let droids = processes.filter { URL(fileURLWithPath: $0.executable).lastPathComponent == "droid" }
        func belongsToFactory(_ process: ProcessRecord) -> Bool {
            var current = process.parentPID
            var visited = Set<Int32>()
            while current > 1, visited.insert(current).inserted {
                if factoryPIDs.contains(current) { return true }
                current = parents[current] ?? 0
            }
            return false
        }
        return RuntimeStatus(
            factoryRunning: !factoryPIDs.isEmpty,
            droidPIDs: droids.map(\.pid),
            externalDroidPIDs: droids.filter { !belongsToFactory($0) }.map(\.pid)
        )
    }
}
