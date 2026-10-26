import Darwin
import Foundation

/// Protocol-only preflight: no identity, authentication, or content request.
/// AOSP docs/dev/adb_wifi.md: the encrypted listener replies with STLS, not AUTH.
enum PhoneImageTLS {
    private static let cnxn: UInt32 = 0x4e584e43
    private static let stls: UInt32 = 0x534c5453
    static var greeting: Data {
        let payload = Data("host::\0".utf8)
        var data = Data()
        for word: UInt32 in [cnxn, 0x01000001, 4096, UInt32(payload.count), payload.reduce(0) { $0 + UInt32($1) }, ~cnxn] {
            var little = word.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(payload); return data
    }
    static func isSTLS(_ data: Data) -> Bool {
        guard data.count == 24 else { return false }
        let bytes = Array(data)
        let words: [UInt32] = stride(from: 0, to: 24, by: 4).map { offset in
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
        }
        return words == [stls, 0x01000000, 0, 0, 0, ~stls]
    }
    private static func wait(_ fd: Int32, event: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw PhoneImageError.tlsRequired }
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let result = Darwin.poll(&descriptor, 1, Int32(max(1, min(3000, remaining * 1000))))
            if result < 0 && errno == EINTR { continue }
            guard result > 0, descriptor.revents & Int16(POLLNVAL | POLLERR) == 0 else { throw PhoneImageError.tlsRequired }
            return
        }
    }
    static func exchange(_ fd: Int32, timeout: TimeInterval = 3) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw PhoneImageError.tlsRequired }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw PhoneImageError.tlsRequired }
        let hello = greeting
        try hello.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try wait(fd, event: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw PhoneImageError.tlsRequired }; offset += count
            }
        }
        var bytes = [UInt8](repeating: 0, count: 24), offset = 0
        try bytes.withUnsafeMutableBytes { buffer in
            while offset < buffer.count {
                try wait(fd, event: Int16(POLLIN), deadline: deadline)
                let count = Darwin.recv(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw PhoneImageError.tlsRequired }; offset += count
            }
        }
        guard isSTLS(Data(bytes)) else { throw PhoneImageError.tlsRequired }
    }
    static func verify(endpoint: String) throws {
        guard PhoneImageADBClient.validEndpoint(endpoint) else { throw PhoneImageError.tlsRequired }
        let parts = endpoint.split(separator: ":")
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PhoneImageError.tlsRequired }; defer { close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw PhoneImageError.tlsRequired }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr(String(parts[0]))
        address.sin_port = UInt16(parts[1])!.bigEndian
        let result = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw PhoneImageError.tlsRequired }
            try wait(fd, event: Int16(POLLOUT), deadline: ProcessInfo.processInfo.systemUptime + 3)
            var error: Int32 = 0; var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw PhoneImageError.tlsRequired }
        }
        try exchange(fd)
    }
}
