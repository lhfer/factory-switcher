import CryptoKit
import Darwin
import Foundation

public struct LocalSession: Identifiable, Sendable {
    public let id: String
    public let relativePath: String
    public let title: String
    public let organizationID: String?

    public init(id: String, relativePath: String, title: String, organizationID: String?) {
        self.id = id
        self.relativePath = relativePath
        self.title = title
        self.organizationID = organizationID
    }
}

public struct SessionEdit: Codable, Sendable {
    public let relativePath: String
    public let originalDigest: String
    public let replacementHeader: Data
    public let originalHeader: Data
}

public enum SessionFiles {
    public static func scan(root: URL) throws -> [LocalSession] {
        guard try SafeFiles.exists(root) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in false }
        ) else { throw SwitcherError.message("无法扫描本地对话目录。") }
        var sessions: [LocalSession] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            // DirectoryEnumerator does not follow symlinks. Calling
            // skipDescendants on a file link can skip a later real directory.
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true, url.pathExtension == "jsonl" else { continue }
            guard let header = try? firstLine(url) else { continue }
            guard let data = try? JSONDecoder().decode([String: JSONValue].self, from: header),
                  data["type"]?.string == "session_start" else { continue }
            let id = data["id"]?.string ?? data["sessionId"]?.string ?? url.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: id) != nil else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            _ = try scoped(relative, root: root)
            sessions.append(LocalSession(
                id: id, relativePath: relative,
                title: data["title"]?.string ?? url.deletingPathExtension().lastPathComponent,
                organizationID: data["organizationId"]?.string
            ))
        }
        return sessions.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public static func prepare(
        root: URL, selectedIDs: Set<String>, backup: URL
    ) throws -> [SessionEdit] {
        guard !selectedIDs.isEmpty else { return [] }
        let candidates = try scan(root: root).filter {
            selectedIDs.contains($0.id) && !($0.organizationID ?? "").isEmpty
        }
        var edits: [SessionEdit] = []
        for session in candidates {
            let source = try scoped(session.relativePath, root: root)
            let originalHeader = try firstLine(source)
            var record = try JSONDecoder().decode([String: JSONValue].self, from: originalHeader)
            record.removeValue(forKey: "organizationId")
            var replacement = try SafeFiles.encode(record)
            if originalHeader.last == 10 { replacement.append(10) }
            let destination = try scoped(session.relativePath, root: backup)
            try copy(source, to: destination)
            let digest = try sha256(source)
            guard try sha256(destination) == digest, try firstLine(destination) == originalHeader else {
                throw SwitcherError.message("对话备份校验失败，未开始修改对话。")
            }
            edits.append(SessionEdit(
                relativePath: session.relativePath, originalDigest: digest,
                replacementHeader: replacement, originalHeader: originalHeader
            ))
        }
        return edits
    }

    public static func apply(_ edits: [SessionEdit], root: URL) throws {
        // Validate every candidate before changing the first one.
        for edit in edits {
            let url = try scoped(edit.relativePath, root: root)
            guard try sha256(url) == edit.originalDigest else {
                throw SwitcherError.message("对话在备份后发生变化，已停止共享。请关闭相关任务后重试。")
            }
        }
        for edit in edits {
            try rewriteHeader(
                try scoped(edit.relativePath, root: root),
                expected: edit.originalHeader, replacement: edit.replacementHeader
            )
        }
    }

    public static func restore(_ edits: [SessionEdit], root: URL, backup: URL) throws {
        // Only restore this metadata field. New conversation messages are kept.
        for edit in edits {
            let original = try scoped(edit.relativePath, root: backup)
            guard try sha256(original) == edit.originalDigest else {
                throw SwitcherError.message("对话备份已更改，无法安全恢复。")
            }
            guard try firstLine(original) == edit.originalHeader else {
                throw SwitcherError.message("对话备份头部校验失败，无法安全恢复。")
            }
            let live = try scoped(edit.relativePath, root: root)
            let header = try firstLine(live)
            let current = try JSONDecoder().decode([String: JSONValue].self, from: header)
            let before = try JSONDecoder().decode([String: JSONValue].self, from: edit.originalHeader)
            let after = try JSONDecoder().decode([String: JSONValue].self, from: edit.replacementHeader)
            guard current["type"]?.string == "session_start",
                  current["id"] == before["id"], current["sessionId"] == before["sessionId"],
                  current["organizationId"] == before["organizationId"]
                    || current["organizationId"] == after["organizationId"] else {
                throw SwitcherError.message("对话已绑定到其他组织，不能自动恢复。")
            }
        }
        for edit in edits {
            let live = try scoped(edit.relativePath, root: root)
            let header = try firstLine(live)
            var current = try JSONDecoder().decode([String: JSONValue].self, from: header)
            let before = try JSONDecoder().decode([String: JSONValue].self, from: edit.originalHeader)
            if current["organizationId"] == before["organizationId"] { continue }
            current["organizationId"] = before["organizationId"]
            var replacement = try SafeFiles.encode(current)
            if header.last == 10 { replacement.append(10) }
            try rewriteHeader(live, expected: header, replacement: replacement)
        }
    }

    public static func scoped(_ relative: String, root: URL) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"), !components.contains(".."),
              !components.contains("."), !components.contains(""), !relative.contains("\0") else {
            throw SwitcherError.message("对话备份路径无效。")
        }
        let url = root.appendingPathComponent(relative).absoluteURL
        guard url.path.hasPrefix(root.absoluteURL.path + "/") else {
            throw SwitcherError.message("对话路径越出了允许的目录。")
        }
        try SafeFiles.rejectSymlinks(url)
        return url
    }

    public static func firstLine(_ url: URL) throws -> Data {
        let handle = try openReader(url)
        defer { try? handle.close() }
        var line = Data()
        while let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty {
            if let newline = chunk.firstIndex(of: 10) {
                line.append(chunk.prefix(through: newline))
                break
            }
            line.append(chunk)
            if line.count > 256 * 1024 { throw SwitcherError.message("对话头部过大，不会修改这个文件。") }
        }
        guard line.count <= 256 * 1024 else { throw SwitcherError.message("对话头部过大。") }
        return line
    }

    public static func sha256(_ url: URL) throws -> String {
        let handle = try openReader(url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func copy(_ source: URL, to destination: URL) throws {
        try replaceStreaming(source: source, destination: destination, replacementHeader: nil)
    }

    private static func rewriteHeader(_ url: URL, expected: Data, replacement: Data) throws {
        guard try firstLine(url) == expected else {
            throw SwitcherError.message("对话在准备后发生变化，已停止修改。")
        }
        try replaceStreaming(source: url, destination: url, replacementHeader: (expected.count, replacement))
    }

    private static func openReader(_ url: URL) throws -> FileHandle {
        try SafeFiles.rejectSymlinks(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SwitcherError.message("无法读取本地对话文件。") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw SwitcherError.message("对话路径不是普通文件。")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func replaceStreaming(
        source: URL, destination: URL, replacementHeader: (Int, Data)?
    ) throws {
        try SafeFiles.ensureDirectory(destination.deletingLastPathComponent())
        try SafeFiles.rejectSymlinks(destination)
        let reader = try openReader(source)
        defer { try? reader.close() }
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".session-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SwitcherError.message("无法创建对话修改的临时文件。") }
        let writer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var committed = false
        defer {
            try? writer.close()
            if !committed { try? FileManager.default.removeItem(at: temp) }
        }
        if let (skip, header) = replacementHeader {
            try reader.seek(toOffset: UInt64(skip))
            try writer.write(contentsOf: header)
        }
        while let chunk = try reader.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
        try writer.synchronize()
        try writer.close()
        guard rename(temp.path, destination.path) == 0 else {
            throw SwitcherError.message("对话替换失败，原文件未修改。")
        }
        committed = true
        SafeFiles.syncDirectory(destination.deletingLastPathComponent())
    }
}
