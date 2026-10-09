import Darwin
import Foundation

/// Making the address of a socket file, and the few system calls that take one.
enum SocketAddress {
    /// A path in `sockaddr_un` holds 104 bytes, one of them for the zero that ends it.
    static let maxPathBytes = 103

    /// The address of the socket file at `path`, or nil when the path doesn't fit.
    static func make(path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maxPathBytes, !bytes.contains(0) else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func connect(_ fd: Int32, _ address: sockaddr_un) -> Int32 {
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func bind(_ fd: Int32, _ address: sockaddr_un) -> Int32 {
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Settings every socket of Mantel's gets: no blocking, not inherited by a program it starts, and no SIGPIPE when
    /// the other end has gone, which would otherwise end the process: a write fails with an error instead.
    @discardableResult
    static func configure(_ fd: Int32) -> Bool {
        var noSignal: Int32 = 1
        return fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1
            && fcntl(fd, F_SETFD, FD_CLOEXEC) != -1
            && setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
    }
}

extension Duration {
    /// Whole milliseconds, rounded up, for a call that wants them.
    var millisecondsRoundedUp: Int64 {
        let (seconds, attoseconds) = components
        let fraction = (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
        return seconds * 1000 + fraction
    }
}
