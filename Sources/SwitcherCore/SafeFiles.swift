import Darwin
import Foundation

public struct SwitcherPaths: Sendable {
    public let root: URL
    public let factory: URL

    public init(root: URL, factory: URL) {
        self.root = root.absoluteURL
        self.factory = factory.absoluteURL
    }

    public static func standard() -> SwitcherPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return SwitcherPaths(
            root: home.appendingPathComponent(".factory-switcher", isDirectory: true),
            factory: home.appendingPathComponent(".factory", isDirectory: true)
        )
    }

    public var state: URL { root.appendingPathComponent("state.json") }
    public var backups: URL { root.appendingPathComponent("backups", isDirectory: true) }
    public var sessions: URL { factory.appendingPathComponent("sessions", isDirectory: true) }
    public var transaction: URL { root.appendingPathComponent("transaction.json") }

    public func accountRoot(_ id: String) throws -> URL {
        try Self.validateID(id)
        return root.appendingPathComponent("accounts", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    public func loginRoot(_ id: String) throws -> URL {
        try Self.validateID(id)
        return root.appendingPathComponent("logins", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    public static func validateID(_ id: String) throws {
        guard UUID(uuidString: id) != nil else {
            throw SwitcherError.message("账号或备份标识无效。")
        }
    }
}

public enum SafeFiles {
    public static func rejectSymlinks(_ url: URL) throws {
        // standardizedFileURL rewrites an existing /private/var path back to
        // the /var symlink on macOS. Keep the caller's physical path intact.
        var current = url.absoluteURL
        while current.path != "/" {
            var info = stat()
            if lstat(current.path, &info) == 0 {
                if (info.st_mode & S_IFMT) == S_IFLNK {
                    throw SwitcherError.message("安全检查未通过：数据路径包含符号链接。")
                }
            } else if errno != ENOENT {
                throw SwitcherError.message("无法检查数据路径，请确认文件访问权限。")
            }
            current.deleteLastPathComponent()
        }
    }

    public static func ensureDirectory(_ url: URL) throws {
        try rejectSymlinks(url)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        guard chmod(url.path, 0o700) == 0 else {
            throw SwitcherError.message("无法保护数据目录的访问权限。")
        }
    }

    public static func exists(_ url: URL) throws -> Bool {
        try rejectSymlinks(url)
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw SwitcherError.message("无法检查文件，请确认文件访问权限。")
    }

    public static func read(_ url: URL, maximumBytes: Int = 4 * 1024 * 1024) throws -> Data {
        try rejectSymlinks(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SwitcherError.message("无法读取文件，请确认文件存在且可访问。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else {
            throw SwitcherError.message("文件类型或大小不受支持。")
        }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw SwitcherError.message("文件超过大小限制。") }
        return data
    }

    public static func atomicWrite(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        try rejectSymlinks(url)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SwitcherError.message("无法创建安全的临时文件。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var committed = false
        defer {
            try? handle.close()
            if !committed { try? FileManager.default.removeItem(at: temporary) }
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else {
            throw SwitcherError.message("无法原子替换文件，原文件未修改。")
        }
        committed = true
        syncDirectory(url.deletingLastPathComponent())
    }

    public static func remove(_ url: URL) throws {
        guard try exists(url) else { return }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw SwitcherError.message("拒绝删除非普通文件，已保留原数据。")
        }
        try FileManager.default.removeItem(at: url)
        syncDirectory(url.deletingLastPathComponent())
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    static func syncDirectory(_ url: URL) {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        if fd >= 0 { _ = fsync(fd); close(fd) }
    }
}

public final class StoreLock {
    private let fd: Int32

    public init(root: URL) throws {
        try SafeFiles.ensureDirectory(root)
        let url = root.appendingPathComponent("operation.lock")
        try SafeFiles.rejectSymlinks(url)
        fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SwitcherError.message("无法创建账号操作锁。") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw SwitcherError.message("账号操作锁不是普通文件，已停止操作。")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw SwitcherError.message("另一个账号操作正在执行，请稍后再试。")
        }
    }

    deinit {
        _ = flock(fd, LOCK_UN)
        close(fd)
    }
}
