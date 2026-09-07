import Darwin
import Foundation

/// User-local command socket. Only the running driver owns and mutates pairing state.
public final class DriverControl {
    public static var directory: URL {
        PairingStore.defaultURL().deletingLastPathComponent().appendingPathComponent("run")
    }
    private let endpointDirectory: URL
    private var path: String { endpointDirectory.appendingPathComponent("control.sock").path }
    private var source: DispatchSourceRead?
    private var lockFD: Int32 = -1
    private var ownsSocket = false
    private let queue = DispatchQueue(label: "touch-driver.control")

    public init(directory: URL = DriverControl.directory) { endpointDirectory = directory }
    deinit { stop() }

    public func start(handler: @escaping (String, @escaping (String) -> Void) -> Void) throws {
        try FileManager.default.createDirectory(at: endpointDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: endpointDirectory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              attributes[.ownerAccountID] as? UInt32 == getuid(),
              (attributes[.posixPermissions] as? Int ?? 0) & 0o077 == 0 else {
            throw ControlError.message("Control directory must be owned by this user with mode 0700.")
        }
        lockFD = open(endpointDirectory.appendingPathComponent("owner.lock").path,
                      O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD); lockFD = -1 }
            throw ControlError.message("A driver already owns the command endpoint.")
        }
        // Exclusive ownership makes stale socket cleanup a canonical driver operation.
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_uid == getuid(), existing.st_mode & S_IFMT == S_IFSOCK else {
                stop()
                throw ControlError.message("Unexpected object at the control socket path.")
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { stop(); throw ControlError.message("Could not create control socket.") }
        do {
            let result = try Self.withAddress(path: path) { bind(fd, $0, $1) }
            ownsSocket = result == 0
            guard result == 0, chmod(path, 0o600) == 0, listen(fd, 4) == 0 else {
                throw ControlError.message("Could not bind control socket.")
            }
        } catch { close(fd); stop(); throw error }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            Self.configure(client)
            // The private endpoint handles one short request at a time. A silent client
            // has a bounded read timeout and cannot block the application event loop.
            guard let request = Self.readLine(client, limit: 256) else { close(client); return }
            handler(request) { response in
                Self.write(response + "\n", to: client)
                close(client)
            }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        if lockFD >= 0 {
            if ownsSocket { unlink(path) }
            ownsSocket = false
            flock(lockFD, LOCK_UN)
            close(lockFD)
            lockFD = -1
        }
    }

    public static func request(_ command: String, directory: URL = DriverControl.directory) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.message("Could not create command connection.") }
        defer { close(fd) }
        configure(fd)
        guard try withAddress(path: directory.appendingPathComponent("control.sock").path, { connect(fd, $0, $1) }) == 0 else {
            throw ControlError.message("Driver is not reachable. Start the installed LaunchAgent.")
        }
        write(command + "\n", to: fd)
        guard let reply = readLine(fd, limit: 65_536) else {
            throw ControlError.message("Driver did not acknowledge the command within three seconds.")
        }
        return reply
    }

    private static func configure(_ fd: Int32) {
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
    }

    private static func withAddress<T>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ControlError.message("Control socket path is too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.copyBytes(from: bytes)
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        address.sun_len = UInt8(length)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }

    private static func readLine(_ fd: Int32, limit: Int) -> String? {
        var data = Data()
        var byte: UInt8 = 0
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while data.count < limit, DispatchTime.now().uptimeNanoseconds < deadline {
            guard Darwin.read(fd, &byte, 1) == 1 else { return nil }
            if byte == 10 { return String(data: data, encoding: .utf8) }
            data.append(byte)
        }
        return nil
    }

    private static func write(_ string: String, to fd: Int32) {
        let data = Array(string.utf8)
        data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let result = Darwin.write(fd, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                guard result > 0 else { return }
                sent += result
            }
        }
    }
}

enum ControlError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
