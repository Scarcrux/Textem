import Darwin
import Foundation

enum PhoneImageCommand {
    private final class State: @unchecked Sendable {
        let process = Process()
        let lock = NSLock()
        var timedOut = false
    }
    static func run(_ executable: URL, _ arguments: [String], maximum: Int = 4096, timeout: Double = 12) throws -> Data {
        let state = State(), pipe = Pipe()
        let process = state.process
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw PhoneImageError.connection }
        let deadline = DispatchWorkItem {
            if process.isRunning {
                state.lock.withLock { state.timedOut = true }
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel(); try? pipe.fileHandleForReading.close() }
        var output = Data()
        do {
            while let chunk = try pipe.fileHandleForReading.read(upToCount: min(8192, maximum + 1 - output.count)), !chunk.isEmpty {
                output.append(chunk)
                if output.count > maximum { throw PhoneImageError.invalid }
            }
        } catch {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit()
            throw PhoneImageError.invalid
        }
        process.waitUntilExit()
        if state.lock.withLock({ state.timedOut }) { throw PhoneImageError.timeout }
        guard process.terminationStatus == 0 else { throw PhoneImageError.connection }
        return output
    }
}

/// Owns only its private loopback adb server. Never stops a shared server or changes phone pairing.
final class PhoneImageADBClient: @unchecked Sendable {
    static let shared = PhoneImageADBClient()
    private let lock = NSLock()
    private var daemon: Process?
    private var port: Int?
    private let externalPort: Int?
    init(serverPort: Int? = nil) { externalPort = serverPort }
    deinit { stop() }
    func stop() { lock.withLock { if let daemon, daemon.isRunning { daemon.terminate() }; daemon = nil; port = nil } }
    private static func executable() throws -> URL {
        let homeSDK = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path
        for path in ["/opt/homebrew/share/android-commandlinetools/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb", homeSDK] {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            var info = stat()
            if lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
               info.st_uid == 0 || info.st_uid == getuid(), info.st_mode & mode_t(0o022) == 0,
               FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw PhoneImageError.adbMissing
    }
    private static func availablePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PhoneImageError.connection }
        defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, result == 0 else { throw PhoneImageError.connection }
        return Int(UInt16(bigEndian: address.sin_port))
    }
    private func server(_ executable: URL) throws -> Int {
        try lock.withLock {
            if let externalPort { guard (1...65535).contains(externalPort) else { throw PhoneImageError.invalid }; return externalPort }
            if let daemon, daemon.isRunning, let port { return port }
            let selectedPort = try Self.availablePort()
            let process = Process(); process.executableURL = executable
            process.arguments = ["-L", "tcp:127.0.0.1:\(selectedPort)", "nodaemon", "server"]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); daemon = process; port = selectedPort
            return selectedPort
        }
    }
    static func validEndpoint(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port),
              parts[1].allSatisfy(\.isNumber) else { return false }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ piece in
            guard let number = Int(piece) else { return false }
            return (0...255).contains(number) && String(number) == piece
        }) else { return false }
        let numbers = octets.compactMap { Int($0) }
        return numbers[0] == 10 || (numbers[0] == 192 && numbers[1] == 168)
            || (numbers[0] == 172 && (16...31).contains(numbers[1]))
    }
    static func authorizedDevices(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let value = String(line)
            guard let range = value.range(of: #"\s+device(?:\s|$)"#, options: .regularExpression) else { return nil }
            let serial = String(value[..<range.lowerBound])
            let supported = value.contains(" usb:") || serial.contains("._adb-tls-connect._tcp") || validEndpoint(serial)
            return supported && !serial.isEmpty && !serial.hasPrefix("emulator-") && serial.utf8.count <= 256 ? serial : nil
        }
    }
    func fetch(endpoint: String) async throws -> (PhoneImageManifest, Data) {
        let executable = try Self.executable(), port = try server(executable)
        // Give the owned foreground server time to bind without spawning a second background daemon.
        if externalPort == nil { try await Task.sleep(for: .milliseconds(250)) }
        if externalPort == nil && !lock.withLock({ daemon?.isRunning == true }) { throw PhoneImageError.connection }
        let base = ["-P", String(port)]
        let serial: String
        if !endpoint.isEmpty {
            guard Self.validEndpoint(endpoint) else { throw PhoneImageError.noDevice }
            _ = try? PhoneImageCommand.run(executable, base + ["connect", endpoint])
            serial = endpoint
        } else {
            let devices = Self.authorizedDevices(try PhoneImageCommand.run(executable, base + ["devices", "-l"], maximum: 32768))
            guard devices.count == 1 else { throw PhoneImageError.noDevice }; serial = devices[0]
        }
        let device = base + ["-s", serial]
        func connected() -> Bool {
            guard let data = try? PhoneImageCommand.run(executable, device + ["get-state"]) else { return false }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "device"
        }
        if !connected(), !endpoint.isEmpty {
            try await Task.sleep(for: .milliseconds(800))
            _ = try? PhoneImageCommand.run(executable, base + ["connect", endpoint])
        }
        guard connected() else { throw PhoneImageError.noDevice }
        if Self.validEndpoint(serial) {
            // adbd publishes this property for its TLS listener, not the legacy plaintext tcpip port.
            let tls = try PhoneImageCommand.run(executable, device + ["shell", "getprop", "service.adb.tls.port"])
            guard String(data: tls, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                == String(serial.split(separator: ":").last ?? "") else { throw PhoneImageError.tlsRequired }
        }
        func read(_ filename: String, maximum: Int) throws -> Data {
            try PhoneImageCommand.run(executable, device + ["exec-out", "run-as", "dev.textem.probe", "/system/bin/head",
                "-c", String(maximum + 1), "files/" + filename], maximum: maximum)
        }
        do {
            let first = try read("mac-image.json", maximum: 4096)
            let manifest = try PhoneImageManifest.parse(first)
            let png = try read(manifest.filename, maximum: PhoneImageManifest.maximumBytes)
            let second = try read("mac-image.json", maximum: 4096)
            guard first == second else { throw PhoneImageError.invalid }
            try manifest.validatePNG(png)
            return (manifest, png)
        } catch let error as PhoneImageError where error == .timeout || error == .invalid { throw error }
        catch { if !connected() { throw PhoneImageError.connection }; throw PhoneImageError.noExport }
    }
}
