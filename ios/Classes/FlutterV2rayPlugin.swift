import Flutter
import Foundation
import NetworkExtension
import UIKit
import Xray

/// iOS implementation of the flutter_v2ray_client method and event channels.
///
/// The split from Android is the important part: there, the VPN runs inside the
/// app process and the plugin can call the core directly. Here the tunnel lives
/// in a separate Network Extension process, so this class installs and drives a
/// VPN profile and polls the extension for numbers. The only thing it runs
/// in-process is a standalone delay test, which needs no tunnel.
public class FlutterV2rayPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private static let methodChannelName = "flutter_v2ray_client"
    private static let eventChannelName = "flutter_v2ray_client/status"

    private var tunnel: PacketTunnelManager?
    private var eventSink: FlutterEventSink?
    private var timer: Timer?

    /// Cumulative counters as last reported by the extension, used to turn
    /// totals into per-second speeds.
    private var totalUpload = 0
    private var totalDownload = 0
    private var uploadSpeed = 0
    private var downloadSpeed = 0

    /// Suppresses duplicate events; the Dart side applies `distinct()` too, but
    /// not sending is cheaper than not using.
    private var lastEvent: [String]?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FlutterV2rayPlugin()

        let methodChannel = FlutterMethodChannel(
            name: methodChannelName,
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let eventChannel = FlutterEventChannel(
            name: eventChannelName,
            binaryMessenger: registrar.messenger()
        )
        eventChannel.setStreamHandler(instance)
    }

    // MARK: - Event channel

    public func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        // Report where things stand right now, so a UI that subscribes after
        // the tunnel is already up does not sit on a stale disconnected state.
        emitCurrentState()
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - Method channel

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initializeV2Ray":
            initialize(call: call, result: result)
        case "requestPermission":
            requestPermission(result: result)
        case "startV2Ray":
            start(call: call, result: result)
        case "stopV2Ray":
            stop(result: result)
        case "getCoreVersion":
            result(XrayVersion())
        case "getServerDelay":
            serverDelay(call: call, result: result)
        case "getConnectedServerDelay":
            connectedServerDelay(call: call, result: result)
        case "getLogs":
            logs(result: result)
        case "clearLogs":
            clearLogs(result: result)
        case "getPlatformVersion":
            result("iOS " + UIDevice.current.systemVersion)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Initialization

    private func initialize(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard
            let arguments = call.arguments as? [String: Any],
            let providerBundleIdentifier = arguments["providerBundleIdentifier"] as? String,
            !providerBundleIdentifier.isEmpty,
            let groupIdentifier = arguments["groupIdentifier"] as? String,
            !groupIdentifier.isEmpty
        else {
            result(
                FlutterError(
                    code: "MISSING_IOS_IDENTIFIERS",
                    message: """
                    initializeV2Ray needs providerBundleIdentifier and groupIdentifier on iOS. \
                    Pass the packet tunnel extension's bundle identifier and the app group \
                    shared by the app and the extension. See ios/IOS_SETUP.md.
                    """,
                    details: nil
                )
            )
            return
        }

        let manager = PacketTunnelManager(
            providerBundleIdentifier: providerBundleIdentifier,
            groupIdentifier: groupIdentifier
        )
        manager.onStatusChange = { [weak self] in
            self?.handleStatusChange()
        }
        tunnel = manager

        Task { [weak self] in
            await manager.reload()
            await MainActor.run {
                self?.handleStatusChange()
                result(nil)
            }
        }
    }

    private func requestPermission(result: @escaping FlutterResult) {
        guard let tunnel else {
            result(false)
            return
        }
        Task {
            let granted = await tunnel.requestPermission()
            await MainActor.run { result(granted) }
        }
    }

    // MARK: - Connection

    private func start(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let tunnel else {
            result(uninitialized())
            return
        }
        guard
            let arguments = call.arguments as? [String: Any],
            let remark = arguments["remark"] as? String,
            let config = arguments["config"] as? String,
            let configData = config.data(using: .utf8)
        else {
            result(
                FlutterError(
                    code: "INVALID_ARGUMENTS",
                    message: "startV2Ray needs a remark and a config.",
                    details: nil
                )
            )
            return
        }

        // Proxy-only has no meaning on iOS: there is no system-wide HTTP proxy
        // an app can set for other apps, and the tunnel is the only way to move
        // traffic. Fail loudly instead of silently starting a full tunnel.
        if arguments["proxy_only"] as? Bool == true {
            result(
                FlutterError(
                    code: "UNSUPPORTED_ON_IOS",
                    message: "proxyOnly is not available on iOS; use VPN mode.",
                    details: nil
                )
            )
            return
        }

        resetCounters()

        Task { [weak self] in
            do {
                try await tunnel.save(
                    remark: remark,
                    xrayConfig: configData,
                    socksPort: arguments["socksPort"] as? Int,
                    mtu: arguments["mtu"] as? Int,
                    dnsServers: arguments["dnsServers"] as? [String],
                    logLevel: arguments["logLevel"] as? String
                )
                try tunnel.start()
                await MainActor.run {
                    self?.startPolling()
                    result(nil)
                }
            } catch {
                await MainActor.run {
                    self?.stopPolling()
                    result(
                        FlutterError(
                            code: "VPN_ERROR",
                            message: "Failed to start the tunnel: \(error.localizedDescription)",
                            details: nil
                        )
                    )
                }
            }
        }
    }

    private func stop(result: @escaping FlutterResult) {
        tunnel?.stop()
        stopPolling()
        resetCounters()
        emit(state: "DISCONNECTED", duration: "00:00:00")
        result(nil)
    }

    // MARK: - Delay

    /// Runs in the app process against a throwaway instance, so it works while
    /// disconnected — which is the whole point of testing a server list.
    private func serverDelay(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard
            let arguments = call.arguments as? [String: Any],
            let url = arguments["url"] as? String,
            let config = arguments["config"] as? String,
            let configData = config.data(using: .utf8)
        else {
            result(
                FlutterError(
                    code: "INVALID_ARGUMENTS",
                    message: "getServerDelay needs a config and a url.",
                    details: nil
                )
            )
            return
        }

        let timeout = (arguments["timeoutMillis"] as? Int) ?? 10_000
        DispatchQueue.global(qos: .userInitiated).async {
            // gomobile renders a Go (int64, error) return as a Bool result with
            // the value and the error as out-parameters, so this cannot be
            // called as a Swift throwing function.
            var measured: Int64 = -1
            var error: NSError?
            let ok = XrayMeasureOutboundDelay(configData, url, timeout, &measured, &error)
            let delay = ok ? Int(measured) : -1
            DispatchQueue.main.async { result(delay) }
        }
    }

    private func connectedServerDelay(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard tunnel != nil else {
            result(-1)
            return
        }
        let arguments = call.arguments as? [String: Any]
        guard let url = arguments?["url"] as? String else {
            result(-1)
            return
        }

        Task {
            let response = await request(
                TunnelIPC.Request(
                    kind: .delay,
                    url: url,
                    timeoutMillis: arguments?["timeoutMillis"] as? Int
                )
            )
            let delay = response?.delayMillis ?? -1
            await MainActor.run { result(delay) }
        }
    }

    // MARK: - Logs

    private func logs(result: @escaping FlutterResult) {
        guard tunnel != nil else {
            result([String]())
            return
        }
        Task {
            let response = await request(TunnelIPC.Request(kind: .logs))
            let lines = response?.logs ?? []
            await MainActor.run { result(lines) }
        }
    }

    private func clearLogs(result: @escaping FlutterResult) {
        guard tunnel != nil else {
            result(true)
            return
        }
        Task {
            _ = await request(TunnelIPC.Request(kind: .clearLogs))
            await MainActor.run { result(true) }
        }
    }

    // MARK: - Status polling

    private func handleStatusChange() {
        guard let tunnel else { return }
        switch tunnel.status {
        case .connected:
            startPolling()
        case .connecting, .reasserting:
            emitCurrentState()
        case .disconnected, .disconnecting, .invalid:
            stopPolling()
            resetCounters()
            emitCurrentState()
        @unknown default:
            emitCurrentState()
        }
    }

    private func startPolling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        // Emit immediately from cached counters so the UI ticks once a second
        // even if the extension is slow to answer.
        emitCurrentState()

        Task { [weak self] in
            guard
                let response = await self?.request(TunnelIPC.Request(kind: .traffic)),
                let upload = response.uploadBytes,
                let download = response.downloadBytes
            else { return }

            await MainActor.run {
                guard let self else { return }
                // Counters are cumulative for the life of the tunnel, so a
                // decrease means the extension restarted underneath us.
                self.uploadSpeed = max(0, upload - self.totalUpload)
                self.downloadSpeed = max(0, download - self.totalDownload)
                self.totalUpload = upload
                self.totalDownload = download
            }
        }
    }

    private func resetCounters() {
        totalUpload = 0
        totalDownload = 0
        uploadSpeed = 0
        downloadSpeed = 0
    }

    // MARK: - Events

    private func emitCurrentState() {
        guard let tunnel else {
            emit(state: "DISCONNECTED", duration: "00:00:00")
            return
        }
        emit(state: tunnel.state, duration: formatted(since: tunnel.connectedDate))
    }

    private func emit(state: String, duration: String) {
        guard let eventSink else { return }
        // Order matches the Android broadcast and what Dart unpacks:
        // duration, upload speed, download speed, upload, download, state.
        let event = [
            duration,
            "\(uploadSpeed)",
            "\(downloadSpeed)",
            "\(totalUpload)",
            "\(totalDownload)",
            state,
        ]
        guard event != lastEvent else { return }
        lastEvent = event
        eventSink(event)
    }

    private func formatted(since date: Date?) -> String {
        guard let date else { return "00:00:00" }
        let elapsed = max(0, Int(Date().timeIntervalSince(date)))
        return String(
            format: "%02d:%02d:%02d",
            elapsed / 3600,
            (elapsed / 60) % 60,
            elapsed % 60
        )
    }

    /// Single place where extension round trips are made. `send` returns nil
    /// when the tunnel is down and throws when the round trip fails; callers
    /// treat both the same way, so collapse them here rather than juggling a
    /// doubly-optional result at every call site.
    private func request(_ request: TunnelIPC.Request) async -> TunnelIPC.Response? {
        guard let tunnel else { return nil }
        do {
            return try await tunnel.send(request)
        } catch {
            return nil
        }
    }

    private func uninitialized() -> FlutterError {
        FlutterError(
            code: "NOT_INITIALIZED",
            message: "Call initializeV2Ray() before using the tunnel.",
            details: nil
        )
    }
}
