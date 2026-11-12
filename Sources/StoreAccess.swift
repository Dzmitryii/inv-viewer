import Darwin
import Foundation

/// Serializes document operations and recovers prepared multi-file imports.
enum StoreAccess {
    struct Update: Codable, Equatable {
        let path: String
        let before: Data?
        let after: Data
    }
    struct Journal: Codable {
        let version: Int
        let updates: [Update]
    }

    static func root(for file: URL) -> URL {
        let parent = file.deletingLastPathComponent()
        return parent.lastPathComponent == "Studies" ? parent.deletingLastPathComponent() : parent
    }

    static func locked<T>(_ root: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try withFileLocks([root.appendingPathComponent(".store.lock")]) {
            try recoverUnlocked(root)
            return try body()
        }
    }

    static func withFileLocks<T>(_ paths: [URL], _ body: () throws -> T) throws -> T {
        var descriptors: [Int32] = []
        defer { for descriptor in descriptors.reversed() { _ = close(descriptor) } }
        for path in paths.sorted(by: { $0.path < $1.path }) {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = open(path.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw error() }
            descriptors.append(descriptor)
            guard flock(descriptor, LOCK_EX) == 0 else { throw error() }
        }
        return try body()
    }

    static func read(_ file: URL, limit: Int) throws -> Data? {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw error() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw error() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { throw StudyStoreError.invalid }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit, data.count == info.st_size else { throw StudyStoreError.invalid }
        return data
    }

    static func atomicWrite(_ data: Data, to file: URL) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent("." + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw error() }
        defer { _ = unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, file.path) == 0 else { throw error() }
        try syncDirectory(directory)
    }

    static func validPath(_ path: String) -> Bool {
        if path == "Patients.json" { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0] == "Studies" && parts[1].hasSuffix(".json") &&
            StudyStore.validFingerprint(String(parts[1].dropLast(5)))
    }

    /// Caller holds the root lock. Validate everything before preparing the journal.
    static func commitUnlocked(_ updates: [Update], at root: URL) throws {
        guard !updates.isEmpty else { return }
        guard valid(updates) else { throw StudyStoreError.invalid }
        try withFileLocks(updates.map { root.appendingPathComponent($0.path + ".lock") }) {
            for update in updates {
                guard try read(root.appendingPathComponent(update.path), limit: 16 * 1024 * 1024) == update.before else {
                    throw StudyStoreError.changed
                }
            }
            let journal = root.appendingPathComponent(".PendingImport.json")
            let data = try JSONEncoder().encode(Journal(version: 1, updates: updates))
            guard data.count <= 192 * 1024 * 1024 else { throw StudyStoreError.invalid }
            try atomicWrite(data, to: journal)
            try apply(updates, root: root)
            guard unlink(journal.path) == 0 else { throw error() }
            try syncDirectory(root)
        }
    }

    private static func recoverUnlocked(_ root: URL) throws {
        let file = root.appendingPathComponent(".PendingImport.json")
        guard let data = try read(file, limit: 192 * 1024 * 1024) else { return }
        let journal = try JSONDecoder().decode(Journal.self, from: data)
        guard journal.version == 1, valid(journal.updates) else { throw StudyStoreError.invalid }
        try withFileLocks(journal.updates.map { root.appendingPathComponent($0.path + ".lock") }) {
            for update in journal.updates {
                let current = try read(root.appendingPathComponent(update.path), limit: 16 * 1024 * 1024)
                guard current == update.before || current == update.after else { throw StudyStoreError.changed }
            }
            try apply(journal.updates, root: root)
            guard unlink(file.path) == 0 else { throw error() }
            try syncDirectory(root)
        }
    }

    private static func valid(_ updates: [Update]) -> Bool {
        !updates.isEmpty && updates.count <= 4097 && Set(updates.map(\.path)).count == updates.count &&
            updates.allSatisfy { validPath($0.path) && $0.after.count <= 16 * 1024 * 1024 &&
                ($0.before?.count ?? 0) <= 16 * 1024 * 1024 } &&
            updates.reduce(0) { $0 + $1.after.count + ($1.before?.count ?? 0) } <= 128 * 1024 * 1024
    }

    private static func apply(_ updates: [Update], root: URL) throws {
        for update in updates { try atomicWrite(update.after, to: root.appendingPathComponent(update.path)) }
    }

    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw error() }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw error() }
    }

    private static func error() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
