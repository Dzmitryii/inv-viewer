import CryptoKit
import Darwin
import Foundation

enum BridgeError: LocalizedError {
    case system(String, Int32)
    case disconnected
    case invalidMessage

    var errorDescription: String? {
        switch self {
        case let .system(operation, code):
            String(localized: "Локальный MCP: \(operation) (\(String(cString: strerror(code)))).")
        case .disconnected:
            String(localized: "Откройте INV Viewer и включите «Инструменты → Локальный MCP».")
        case .invalidMessage:
            String(localized: "Повреждённое или слишком большое сообщение локального MCP.")
        }
    }
}

enum LocalBridge {
    enum Response {
        case immediate(Data)
        case deferred(@Sendable () -> Data)

        func resolve() -> Data {
            switch self {
            case .immediate(let data): data
            case .deferred(let finish): finish()
            }
        }
    }

    // Each installed copy gets its own endpoint, even when several copies share a sandbox container.
    // Include the build so a client from an updated bundle cannot talk to a still-running older process.
    private static let instance = {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let identity = bundle.path.precomposedStringWithCanonicalMapping + "\n" + build
        return SHA256.hash(data: Data(identity.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }()
    private static let folder = NSHomeDirectory() + "/.ivm"
    private static let path = folder + "/" + instance
    private static let requestLimit = 16 * 1024
    private static let replyLimit = 16 * 1024 * 1024

    @MainActor
    static func listen(_ handle: @escaping @MainActor @Sendable (Data) -> Response) throws -> DispatchSourceRead {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var metadata = stat()
        guard lstat(folder, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0 else {
            throw BridgeError.system("private socket directory", EACCES)
        }
        let lock = open(folder + "/" + instance + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw BridgeError.system("open lock", errno) }
        let listener: Int32
        do {
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw BridgeError.system("lock", errno) }
            listener = try makeListener()
        } catch {
            close(lock)
            throw error
        }

        let queue = DispatchQueue(label: "local.cbct.inv-viewer.mcp")
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler {
            let peer = accept(listener, nil, nil)
            guard peer >= 0 else { return }
            defer { close(peer) }
            guard isSameUser(peer) else { return }
            configure(peer)
            _ = fcntl(peer, F_SETFL, 0)
            do {
                let request = try readLine(peer, limit: requestLimit)
                let reply = DispatchQueue.main.sync { handle(request) }.resolve()
                guard reply.count <= replyLimit else { throw BridgeError.invalidMessage }
                try writeLine(reply, to: peer)
            } catch {
                return
            }
        }
        source.setCancelHandler {
            unlink(path)
            close(listener)
            close(lock)
        }
        source.resume()
        return source
    }

    static func request(_ data: Data) throws -> Data {
        guard data.count <= requestLimit else { throw BridgeError.invalidMessage }
        let peer = try makeSocket()
        defer { close(peer) }
        let connected = try withAddress { connect(peer, $0, $1) }
        guard connected == 0, isSameUser(peer) else { throw BridgeError.disconnected }
        try writeLine(data, to: peer)
        return try readLine(peer, limit: replyLimit)
    }

    private static func makeListener() throws -> Int32 {
        let descriptor = try makeSocket()
        var ready = false
        defer { if !ready { close(descriptor) } }
        if unlink(path) != 0, errno != ENOENT { throw BridgeError.system("unlink", errno) }
        guard try withAddress({ bind(descriptor, $0, $1) }) == 0 else {
            throw BridgeError.system("bind", errno)
        }
        guard chmod(path, 0o600) == 0, Darwin.listen(descriptor, 8) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            let code = errno
            unlink(path)
            throw BridgeError.system("listen", code)
        }
        ready = true
        return descriptor
    }

    private static func withAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw BridgeError.invalidMessage }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(length)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }

    private static func makeSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BridgeError.system("socket", errno) }
        configure(descriptor)
        return descriptor
    }

    private static func isSameUser(_ descriptor: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0 && uid == geteuid()
    }

    private static func configure(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var enabled: Int32 = 1
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }

    private static func readLine(_ descriptor: Int32, limit: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while result.count <= limit, ProcessInfo.processInfo.systemUptime < deadline {
            let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
            if count < 0, errno == EINTR { continue }
            if count < 0 { throw BridgeError.system("read", errno) }
            if count == 0 { break }
            let chunk = buffer.prefix(count)
            if let newline = chunk.firstIndex(of: 10) {
                guard result.count + newline <= limit else { break }
                result.append(contentsOf: chunk.prefix(newline))
                return result
            }
            result.append(contentsOf: chunk)
        }
        throw BridgeError.invalidMessage
    }

    private static func writeLine(_ data: Data, to descriptor: Int32) throws {
        var line = data
        line.append(10)
        try line.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = send(descriptor, buffer.baseAddress?.advanced(by: written), buffer.count - written, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw BridgeError.system("write", errno) }
                written += count
            }
        }
    }
}
