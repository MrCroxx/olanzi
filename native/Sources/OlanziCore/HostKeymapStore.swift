import Darwin
import Foundation

public final class HostKeymapStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Olanzi/host-keymap.json")
    }

    public func load() throws -> HostKeymap? {
        lock.lock()
        defer { lock.unlock() }
        return try read()
    }

    public func save(_ keymap: HostKeymap) throws {
        try keymap.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(keymap)
        guard bytes.count <= HostKeymap.maximumJSONBytes else { throw HostKeymapError.tooLarge }
        lock.lock()
        defer { lock.unlock() }
        // 损坏配置必须显式恢复，不能在后台用默认值悄悄覆盖。
        _ = try read()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".host-keymap-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        defer {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: temporary)
        }
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
        // 同一目录内 rename 为原子替换；此前任何错误都保留旧配置。
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw posixError() }
    }

    private func read() throws -> HostKeymap? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw posixError() }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnsupportedSchemeError,
                          userInfo: [NSLocalizedDescriptionKey: "配置路径必须是普通文件。"])
        }
        guard info.st_size <= HostKeymap.maximumJSONBytes else { throw HostKeymapError.tooLarge }
        let bytes = try handle.read(upToCount: HostKeymap.maximumJSONBytes + 1) ?? Data()
        return try HostKeymap.decode(data: bytes)
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}
