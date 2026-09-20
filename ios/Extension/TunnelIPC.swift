import Foundation

/// The contract between the host app and the packet tunnel extension.
///
/// They are separate processes, so nothing is shared except what crosses
/// `NETunnelProviderSession.sendProviderMessage` and the app group container.
/// This file is compiled into both, which is what keeps the two sides honest —
/// change a key here and neither side can drift.
public enum TunnelIPC {

    // MARK: - Provider configuration

    /// Keys in `NETunnelProviderProtocol.providerConfiguration`, written by the
    /// app when it saves the VPN profile and read by the extension on start.
    public enum ConfigKey {
        /// Xray JSON configuration, UTF-8 encoded. Required.
        public static let xrayConfig = "xrayConfig"
        /// SOCKS inbound port. Optional: the extension reads it from the Xray
        /// config when absent.
        public static let socksPort = "socksPort"
        /// Tunnel MTU. Optional.
        public static let mtu = "mtu"
        /// DNS servers to advertise on the tunnel interface. Optional.
        public static let dnsServers = "dnsServers"
        /// Xray log level forwarded to the log file. Optional.
        public static let logLevel = "logLevel"
        /// App group identifier, so the extension can find the shared container.
        public static let groupIdentifier = "groupIdentifier"
    }

    // MARK: - Messages

    public enum RequestKind: String, Codable {
        /// Byte counters for the live tunnel.
        case traffic
        /// Delay through the running instance.
        case delay
        /// Recent core log lines.
        case logs
        /// Discard the log file.
        case clearLogs
    }

    public struct Request: Codable {
        public let kind: RequestKind
        public let url: String?
        public let timeoutMillis: Int?

        public init(kind: RequestKind, url: String? = nil, timeoutMillis: Int? = nil) {
            self.kind = kind
            self.url = url
            self.timeoutMillis = timeoutMillis
        }
    }

    public struct Response: Codable {
        public let uploadBytes: Int?
        public let downloadBytes: Int?
        public let delayMillis: Int?
        public let logs: [String]?
        public let error: String?

        public init(
            uploadBytes: Int? = nil,
            downloadBytes: Int? = nil,
            delayMillis: Int? = nil,
            logs: [String]? = nil,
            error: String? = nil
        ) {
            self.uploadBytes = uploadBytes
            self.downloadBytes = downloadBytes
            self.delayMillis = delayMillis
            self.logs = logs
            self.error = error
        }

        public static func failure(_ message: String) -> Response {
            Response(error: message)
        }
    }

    // MARK: - Coding

    public static func encode(_ request: Request) throws -> Data {
        try JSONEncoder().encode(request)
    }

    public static func decodeRequest(_ data: Data) throws -> Request {
        try JSONDecoder().decode(Request.self, from: data)
    }

    public static func encode(_ response: Response) -> Data {
        // A response that cannot be encoded would leave the app waiting, so fall
        // back to a hand-built error payload rather than returning nothing.
        (try? JSONEncoder().encode(response))
            ?? Data(#"{"error":"response encoding failed"}"#.utf8)
    }

    public static func decodeResponse(_ data: Data) throws -> Response {
        try JSONDecoder().decode(Response.self, from: data)
    }

    // MARK: - Shared log file

    /// Name of the core log inside the app group container. The extension has no
    /// logcat equivalent, so it writes here and the app reads it back.
    public static let logFileName = "xray-core.log"

    /// Cap on the log file. The extension is memory-capped and the container is
    /// not unlimited, so the log is trimmed rather than allowed to grow.
    public static let logFileByteLimit = 256 * 1024

    public static func logFileURL(groupIdentifier: String) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)?
            .appendingPathComponent(logFileName)
    }
}
