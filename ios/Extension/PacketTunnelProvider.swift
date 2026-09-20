import Foundation
import NetworkExtension
import Xray
import os

/// The VPN itself. Runs in its own process, separate from the Flutter app, and
/// is held to a 50 MiB memory cap on iOS 15+ (15 MiB on iOS 14 and earlier) that
/// jetsam enforces by killing the process. Everything here is written with that
/// budget in mind: no geo data, bounded buffers, bounded logs.
///
/// Packets flow: app traffic -> utun -> tun2socks -> Xray SOCKS inbound ->
/// outbound. Xray never touches the tunnel device directly.
final class PacketTunnelProvider: NEPacketTunnelProvider {

    private static let logger = os.Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "flutter_v2ray_client",
        category: "tunnel"
    )

    /// Interface address for the tunnel.
    ///
    /// Deliberately outside `198.18.0.0/16`: that range is the FakeDNS pool, and
    /// an interface address inside the pool can be handed to a domain, which
    /// makes a fraction of lookups resolve to the tunnel itself.
    private enum Interface {
        static let remoteAddress = "254.1.1.1"
        static let ipv4Address = "172.19.0.1"
        static let ipv4Mask = "255.255.255.252"
        static let ipv6Address = "fd6e:a81b:704f:1211::1"
        static let ipv6PrefixLength: NSNumber = 64
        /// Matches the tun2socks default; the two must agree or large packets
        /// are silently dropped.
        static let defaultMTU = 8500
    }

    private enum Default {
        /// Any address that routes into the tunnel works, because tun2socks
        /// relays UDP to the SOCKS inbound and Xray answers. Keep this in step
        /// with the `dns` block of the generated Xray config.
        static let dnsServers = ["1.1.1.1", "8.8.8.8"]
        static let memoryLimitMegabytes = 45
    }

    private var groupIdentifier: String?
    private var logHandle: LogWriter?
    private var tunnelStarted = false

    // MARK: - Lifecycle

    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        let configuration = try providerConfiguration()

        let xrayConfig = try xrayConfigData(from: configuration)
        let socksPort = try resolveSocksPort(configuration: configuration, xrayConfig: xrayConfig)
        let mtu = (configuration[TunnelIPC.ConfigKey.mtu] as? Int) ?? Interface.defaultMTU
        let dnsServers = (configuration[TunnelIPC.ConfigKey.dnsServers] as? [String]) ?? Default.dnsServers

        groupIdentifier = configuration[TunnelIPC.ConfigKey.groupIdentifier] as? String
        if let groupIdentifier {
            logHandle = LogWriter(groupIdentifier: groupIdentifier)
        }

        try await setTunnelNetworkSettings(networkSettings(mtu: mtu, dnsServers: dnsServers))

        // Cap the Go heap before the core allocates anything.
        XraySetMemoryLimit(Default.memoryLimitMegabytes)

        // gomobile emits plain C functions that report failure through a Bool
        // result and an NSError out-parameter, so these are not Swift throwing
        // calls despite the Go side returning an error.
        var startError: NSError?
        guard XrayStart(xrayConfig, logHandle, &startError) else {
            let reason = startError?.localizedDescription ?? "unknown error"
            log("Xray failed to start: \(reason)")
            throw TunnelError.coreStartFailed(reason)
        }

        log("Xray \(XrayVersion()) started, SOCKS inbound on 127.0.0.1:\(socksPort)")
        startTun2Socks(socksPort: socksPort, mtu: mtu)
        tunnelStarted = true
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        log("Stopping tunnel, reason \(reason.rawValue)")
        tunnelStarted = false

        Tun2Socks.quit()

        var stopError: NSError?
        if !XrayStop(&stopError) {
            log("Xray failed to stop cleanly: \(stopError?.localizedDescription ?? "unknown error")")
        }
        logHandle?.flush()
    }

    /// The tunnel keeps running while the device sleeps; there is nothing to
    /// tear down, and reconnecting on wake would drop live connections.
    override func sleep() async {}

    override func wake() {}

    // MARK: - tun2socks

    private func startTun2Socks(socksPort: Int, mtu: Int) {
        let configuration = Tun2Socks.configuration(socksPort: socksPort, mtu: mtu)

        // Blocks for the lifetime of the tunnel, so it gets its own queue.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try Tun2Socks.run(configuration: configuration)
                // A clean return means the tunnel was asked to quit.
                self?.log("tun2socks stopped")
            } catch {
                self?.log("tun2socks failed: \(error.localizedDescription)")
                // Without a packet path there is no tunnel, so surface it
                // rather than sitting there looking connected.
                guard let self, self.tunnelStarted else { return }
                self.cancelTunnelWithError(TunnelError.packetPathFailed(error.localizedDescription))
            }
        }
    }

    // MARK: - Configuration

    private func providerConfiguration() throws -> [String: Any] {
        guard
            let protocolConfiguration = protocolConfiguration as? NETunnelProviderProtocol,
            let configuration = protocolConfiguration.providerConfiguration
        else {
            throw TunnelError.missingConfiguration
        }
        return configuration
    }

    private func xrayConfigData(from configuration: [String: Any]) throws -> Data {
        if let data = configuration[TunnelIPC.ConfigKey.xrayConfig] as? Data {
            return data
        }
        if let string = configuration[TunnelIPC.ConfigKey.xrayConfig] as? String,
           let data = string.data(using: .utf8) {
            return data
        }
        throw TunnelError.missingConfiguration
    }

    /// Prefers the port the app passed, and otherwise reads the first local
    /// SOCKS or HTTP inbound out of the Xray config.
    private func resolveSocksPort(configuration: [String: Any], xrayConfig: Data) throws -> Int {
        if let port = configuration[TunnelIPC.ConfigKey.socksPort] as? Int, port > 0 {
            return port
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: xrayConfig) as? [String: Any],
            let inbounds = json["inbounds"] as? [[String: Any]]
        else {
            throw TunnelError.noSocksInbound
        }

        for inbound in inbounds {
            guard
                let proto = inbound["protocol"] as? String,
                proto == "socks" || proto == "http",
                let port = inbound["port"] as? Int, port > 0
            else { continue }
            return port
        }
        throw TunnelError.noSocksInbound
    }

    private func networkSettings(mtu: Int, dnsServers: [String]) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: Interface.remoteAddress)
        settings.mtu = NSNumber(value: mtu)

        settings.ipv4Settings = {
            let ipv4 = NEIPv4Settings(
                addresses: [Interface.ipv4Address],
                subnetMasks: [Interface.ipv4Mask]
            )
            ipv4.includedRoutes = [NEIPv4Route.default()]
            return ipv4
        }()

        settings.ipv6Settings = {
            let ipv6 = NEIPv6Settings(
                addresses: [Interface.ipv6Address],
                networkPrefixLengths: [Interface.ipv6PrefixLength]
            )
            ipv6.includedRoutes = [NEIPv6Route.default()]
            return ipv6
        }()

        let dns = NEDNSSettings(servers: dnsServers)
        // Claim every domain, so queries reach Xray instead of leaking to the
        // network's resolver. FakeDNS depends on this.
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        return settings
    }

    // MARK: - Messages from the app

    // The completion-handler form, not the async one: this method's completion
    // handler is optional in the ObjC interface, so Swift does not synthesise an
    // async variant to override.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let request: TunnelIPC.Request
        do {
            request = try TunnelIPC.decodeRequest(messageData)
        } catch {
            completionHandler?(
                TunnelIPC.encode(.failure("Unrecognised request: \(error.localizedDescription)"))
            )
            return
        }

        switch request.kind {
        case .traffic:
            let stats = Tun2Socks.stats
            completionHandler?(
                TunnelIPC.encode(
                    TunnelIPC.Response(
                        uploadBytes: stats.uploadBytes,
                        downloadBytes: stats.downloadBytes
                    )
                )
            )

        case .delay:
            guard let url = request.url else {
                completionHandler?(TunnelIPC.encode(.failure("Delay request carried no URL")))
                return
            }
            // A delay probe makes a network round trip, so keep it off the
            // provider's queue: blocking here stalls every other message.
            DispatchQueue.global(qos: .userInitiated).async {
                // gomobile renders a Go (int64, error) return as a Bool result
                // with the value and the error as out-parameters.
                var measured: Int64 = -1
                var error: NSError?
                let ok = XrayMeasureDelay(url, request.timeoutMillis ?? 10_000, &measured, &error)

                if ok {
                    completionHandler?(
                        TunnelIPC.encode(TunnelIPC.Response(delayMillis: Int(measured)))
                    )
                } else {
                    completionHandler?(
                        TunnelIPC.encode(
                            TunnelIPC.Response(
                                delayMillis: -1,
                                error: error?.localizedDescription ?? "delay probe failed"
                            )
                        )
                    )
                }
            }

        case .logs:
            completionHandler?(TunnelIPC.encode(TunnelIPC.Response(logs: logHandle?.read() ?? [])))

        case .clearLogs:
            logHandle?.clear()
            completionHandler?(TunnelIPC.encode(TunnelIPC.Response()))
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        Self.logger.log("\(message, privacy: .public)")
        logHandle?.logInput(message)
    }
}

// MARK: - Errors

private enum TunnelError: LocalizedError {
    case missingConfiguration
    case noSocksInbound
    case coreStartFailed(String)
    case packetPathFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "The tunnel was started without an Xray configuration."
        case .noSocksInbound:
            return "The Xray configuration has no local SOCKS or HTTP inbound for tun2socks to use."
        case .coreStartFailed(let reason):
            return "Xray could not start: \(reason)"
        case .packetPathFailed(let reason):
            return "The packet path could not be established: \(reason)"
        }
    }
}

// MARK: - Log file

/// Bridges Xray-core's output into a file in the app group container.
///
/// There is no logcat on iOS, so this is how `getLogs()` is served. The file is
/// trimmed rather than rotated: the extension has no memory to spare and the
/// app only ever wants the recent tail.
/// Conforms to `XrayLoggerProtocol`, not `XrayLogger`: gomobile emits both a
/// protocol and a concrete wrapper class under the same Objective-C name, and
/// Swift resolves the bare name to the class, so the protocol gains the suffix.
private final class LogWriter: NSObject, XrayLoggerProtocol {

    private let url: URL?
    private let queue = DispatchQueue(label: "flutter_v2ray_client.tunnel.log")
    private var buffer: [String] = []
    private let bufferLimit = 200

    init(groupIdentifier: String) {
        url = TunnelIPC.logFileURL(groupIdentifier: groupIdentifier)
        super.init()
    }

    /// Called by the core, one line at a time.
    func logInput(_ line: String?) {
        guard let line, !line.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.append(line)
            if self.buffer.count >= self.bufferLimit {
                self.flushLocked()
            }
        }
    }

    func flush() {
        queue.sync { flushLocked() }
    }

    func read() -> [String] {
        queue.sync {
            flushLocked()
            guard let url, let contents = try? String(contentsOf: url, encoding: .utf8) else {
                return []
            }
            return contents.split(separator: "\n").map(String.init)
        }
    }

    func clear() {
        queue.sync {
            buffer.removeAll()
            guard let url else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func flushLocked() {
        guard let url, !buffer.isEmpty else { return }
        let payload = buffer.joined(separator: "\n") + "\n"
        buffer.removeAll(keepingCapacity: true)

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(payload.utf8))
        } else {
            try? payload.write(to: url, atomically: true, encoding: .utf8)
        }

        trimLocked(url: url)
    }

    /// Keeps the tail when the file outgrows its budget.
    private func trimLocked(url: URL) {
        guard
            let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
            size > TunnelIPC.logFileByteLimit,
            let contents = try? String(contentsOf: url, encoding: .utf8)
        else { return }

        let lines = contents.split(separator: "\n")
        let kept = lines.suffix(lines.count / 2).joined(separator: "\n") + "\n"
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }
}
