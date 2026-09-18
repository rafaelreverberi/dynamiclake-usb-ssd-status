import Darwin
import Foundation

public enum DynamicLakeBridgeError: LocalizedError {
    case socketPathMissing
    case socket(String)
    case frameTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .socketPathMissing: return "DYNAMICLAKE_JSON_SOCKET is missing. Start this executable through DynamicLake."
        case .socket(let message): return message
        case .frameTooLarge(let size): return "DynamicLake JSON frame is too large (\(size) bytes)."
        }
    }
}

public final class DynamicLakeBridge {
    public var onAction: ((_ actionID: String, _ activityID: String?) -> Void)?
    public var onDisconnect: (() -> Void)?

    private let socketPath: String
    private let maxFrameSize = 64 * 1024
    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var buffer = Data()

    public init(socketPath: String) { self.socketPath = socketPath }

    public convenience init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let path = environment["DYNAMICLAKE_JSON_SOCKET"], !path.isEmpty else {
            throw DynamicLakeBridgeError.socketPathMissing
        }
        self.init(socketPath: path)
    }

    public func connect() throws {
        guard descriptor < 0 else { return }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DynamicLakeBridgeError.socket(errorText("socket")) }
        descriptor = fd

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else { close(); throw DynamicLakeBridgeError.socket("Socket path is too long.") }
        socketPath.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    memset(destination, 0, capacity)
                    strncpy(destination, source, capacity - 1)
                }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { let message = errorText("connect"); close(); throw DynamicLakeBridgeError.socket(message) }
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        installReadSource(fd)
    }

    public func send(_ payload: [String: Any]) throws {
        let json = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard json.count <= maxFrameSize else { throw DynamicLakeBridgeError.frameTooLarge(json.count) }
        var size = UInt32(json.count).bigEndian
        var frame = Data(bytes: &size, count: 4)
        frame.append(json)
        try sendAll(frame)
    }

    public func close() {
        readSource?.cancel()
        readSource = nil
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }

    private func installReadSource(_ fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler {}
        source.resume()
        readSource = source
    }

    private func readAvailable() {
        guard descriptor >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            if count > 0 { buffer.append(bytes, count: count); continue }
            if count == 0 { Logger.shared.warning("DynamicLake closed the plugin socket"); close(); onDisconnect?(); return }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            if errno == EINTR { continue }
            Logger.shared.warning(errorText("socket read")); close(); onDisconnect?(); return
        }
        decodeFrames()
    }

    private func decodeFrames() {
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length <= maxFrameSize else { buffer.removeAll(); return }
            let total = 4 + Int(length)
            guard buffer.count >= total else { return }
            let body = buffer.subdata(in: 4..<total)
            buffer.removeSubrange(0..<total)
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if type == "action", let actionID = object["actionID"] as? String {
                onAction?(actionID, object["activityID"] as? String)
            } else if type == "response" {
                if (object["ok"] as? Bool) == false {
                    Logger.shared.warning("DynamicLake rejected a command: \((object["error"] as? String) ?? "unknown error")")
                } else {
                    Logger.shared.debug("DynamicLake accepted command request=\((object["requestID"] as? String) ?? "unknown")")
                }
            }
        }
    }

    private func sendAll(_ data: Data) throws {
        guard descriptor >= 0 else { throw DynamicLakeBridgeError.socket("Socket is not connected.") }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let result = Darwin.send(descriptor, base.advanced(by: offset), data.count - offset, 0)
                if result > 0 { offset += result; continue }
                if result < 0 && errno == EINTR { continue }
                if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { usleep(10_000); continue }
                throw DynamicLakeBridgeError.socket(errorText("send"))
            }
        }
    }

    private func errorText(_ operation: String) -> String { "\(operation) failed: \(String(cString: strerror(errno)))" }
    deinit { close() }
}
