import Foundation
import NetworkExtension

/// App-side control surface for the packet tunnel.
///
/// The tunnel runs in its own process, so nothing here starts or stops Xray
/// directly: it installs and drives a VPN profile, and talks to the running
/// extension over `sendProviderMessage`.
final class PacketTunnelManager {

    /// Bundle identifier of the packet tunnel extension. Must match the
    /// extension target's identifier exactly, or the profile loads and then
    /// refuses to start.
    private let providerBundleIdentifier: String
    private let groupIdentifier: String

    private var manager: NETunnelProviderManager?
    private var observers: [NSObjectProtocol] = []

    /// Called on the main queue whenever the VPN status changes.
    var onStatusChange: (() -> Void)?

    init(providerBundleIdentifier: String, groupIdentifier: String) {
        self.providerBundleIdentifier = providerBundleIdentifier
        self.groupIdentifier = groupIdentifier
        observe()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - State

    var status: NEVPNStatus {
        manager?.connection.status ?? .invalid
    }

    var connectedDate: Date? {
        manager?.connection.connectedDate
    }

    /// The three states the Dart layer knows about. Android reports the same
    /// vocabulary, so the two platforms stay interchangeable.
    var state: String {
        switch status {
        case .connected:
            return "CONNECTED"
        case .connecting, .reasserting:
            return "CONNECTING"
        case .disconnecting, .disconnected, .invalid:
            return "DISCONNECTED"
        @unknown default:
            return "DISCONNECTED"
        }
    }

    // MARK: - Profile

    /// The app's display name, used as the profile's name in Settings > VPN.
    static var profileName: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleDisplayName"] as? String
            ?? info?["CFBundleName"] as? String
            ?? "VPN"
    }

    /// Loads the existing profile for this extension, if one is installed.
    @discardableResult
    func reload() async -> NETunnelProviderManager? {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let match = managers.first { candidate in
                (candidate.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == providerBundleIdentifier
            }
            if let match {
                try await match.loadFromPreferences()
            }
            manager = match
            return match
        } catch {
            manager = nil
            return nil
        }
    }

    /// Installs or updates the VPN profile.
    ///
    /// The first call is what triggers the system's VPN permission sheet, which
    /// is why `requestPermission()` on the Dart side lands here.
    func save(
        xrayConfig: Data,
        socksPort: Int?,
        mtu: Int?,
        dnsServers: [String]?,
        logLevel: String?
    ) async throws {
        let target = manager ?? NETunnelProviderManager()

        // One fixed name for the profile, whatever server is in use. The link's
        // remark (the part after #) is an internal server tag, and using it
        // renamed the profile in Settings > VPN on every server change.
        target.localizedDescription = Self.profileName

        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = providerBundleIdentifier
        // Shown in Settings > VPN as "Server". Not a real address; Xray picks
        // the outbound from its own config.
        configuration.serverAddress = Self.profileName

        var providerConfiguration: [String: Any] = [
            TunnelIPC.ConfigKey.xrayConfig: xrayConfig,
            TunnelIPC.ConfigKey.groupIdentifier: groupIdentifier,
        ]
        if let socksPort { providerConfiguration[TunnelIPC.ConfigKey.socksPort] = socksPort }
        if let mtu { providerConfiguration[TunnelIPC.ConfigKey.mtu] = mtu }
        if let dnsServers { providerConfiguration[TunnelIPC.ConfigKey.dnsServers] = dnsServers }
        if let logLevel { providerConfiguration[TunnelIPC.ConfigKey.logLevel] = logLevel }
        configuration.providerConfiguration = providerConfiguration

        // Keeps LAN traffic — printers, AirPlay, router admin pages — off the
        // tunnel, which is what users expect and what Xray would otherwise have
        // to route around.
        configuration.excludeLocalNetworks = true

        target.protocolConfiguration = configuration
        target.isEnabled = true

        try await target.saveToPreferences()
        // Re-reading is required: a freshly saved profile has no usable
        // connection object until it is loaded back.
        try await target.loadFromPreferences()
        manager = target
    }

    /// Saves a placeholder profile purely to provoke the permission sheet, then
    /// reports whether it stuck.
    func requestPermission() async -> Bool {
        await reload()
        do {
            try await save(
                xrayConfig: existingConfig() ?? Data("{}".utf8),
                socksPort: nil,
                mtu: nil,
                dnsServers: nil,
                logLevel: nil
            )
            return true
        } catch {
            return false
        }
    }

    private func existingConfig() -> Data? {
        (manager?.protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration?[TunnelIPC.ConfigKey.xrayConfig] as? Data
    }

    // MARK: - Connection

    func start() throws {
        guard let manager else {
            throw ManagerError.noProfile
        }
        try manager.connection.startVPNTunnel()
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    // MARK: - Messaging

    /// Sends a request to the running extension. Returns nil when the tunnel is
    /// not up, which callers treat as "no data" rather than an error.
    func send(_ request: TunnelIPC.Request) async throws -> TunnelIPC.Response? {
        guard
            let session = manager?.connection as? NETunnelProviderSession,
            status == .connected || status == .reasserting
        else { return nil }

        let payload = try TunnelIPC.encode(request)

        let response: Data? = try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(payload) { data in
                    continuation.resume(returning: data)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }

        guard let response else { return nil }
        return try TunnelIPC.decodeResponse(response)
    }

    // MARK: - Observation

    private func observe() {
        let center = NotificationCenter.default

        // Status is the authority on what the UI shows, so react to the system
        // rather than guessing from whether start() was called.
        observers.append(
            center.addObserver(
                forName: .NEVPNStatusDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.onStatusChange?()
            }
        )

        // A profile edited elsewhere — Settings, another device — invalidates
        // the cached manager.
        observers.append(
            center.addObserver(
                forName: .NEVPNConfigurationChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { [weak self] in
                    await self?.reload()
                    await MainActor.run { self?.onStatusChange?() }
                }
            }
        )
    }

    enum ManagerError: LocalizedError {
        case noProfile

        var errorDescription: String? {
            switch self {
            case .noProfile:
                return "No VPN profile is installed. Call requestPermission() first."
            }
        }
    }
}
