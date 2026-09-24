import Foundation
import HevSocks5Tunnel

/// Moves IP packets between the tunnel interface and Xray's SOCKS inbound.
///
/// `NEPacketTunnelProvider` hands out an `NEPacketTunnelFlow`, not a file
/// descriptor, and there is no supported API that turns one into the other. The
/// widely copied `packetFlow.value(forKeyPath: "socket.fileDescriptor")` trick
/// reads a private ivar through KVC and is a plausible App Store rejection.
///
/// Instead this finds the descriptor the way any process can find its own
/// sockets: walk the process's descriptors and ask each one what it is. The
/// extension already owns a `utun` control socket by the time `startTunnel`
/// runs, so `getpeername(2)` plus a `getsockopt(2)` for the interface name
/// identifies it with nothing but public BSD interfaces.
enum Tun2Socks {

    /// Byte counters for the tunnel interface, as seen by the tun2socks layer.
    struct Stats {
        let uploadBytes: Int
        let downloadBytes: Int

        static let zero = Stats(uploadBytes: 0, downloadBytes: 0)
    }

    enum Failure: LocalizedError {
        case tunnelDescriptorNotFound
        case exited(code: Int32)

        var errorDescription: String? {
            switch self {
            case .tunnelDescriptorNotFound:
                return "Could not locate the utun descriptor for this tunnel."
            case .exited(let code):
                return "tun2socks exited with code \(code)."
            }
        }
    }

    /// Highest descriptor to probe. The utun socket is opened early, so it sits
    /// far below this, but the walk is cheap and bounded either way.
    private static let maxDescriptor: Int32 = 1024

    // `sockaddr_ctl`, `ctl_info` and `CTLIOCGINFO` live in
    // <sys/kern_control.h>, which the iOS Darwin module does not export to
    // Swift. Rather than drag in a bridging header, these three values are
    // spelled out and the socket is identified by the interface name it
    // reports, which is a stronger check than matching a control id anyway.
    private static let addressFamilySystem = sa_family_t(32)  // AF_SYSTEM
    private static let systemProtocolControl: Int32 = 2       // SYSPROTO_CONTROL
    private static let utunOptionInterfaceName: Int32 = 2     // UTUN_OPT_IFNAME
    private static let interfaceNameLimit = 16                // IFNAMSIZ

    private static func tunnelFileDescriptor() -> Int32? {
        for descriptor in Int32(0)...maxDescriptor {
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)

            let connected = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    getpeername(descriptor, generic, &length)
                }
            }

            // Not a socket, or not a kernel control socket: keep looking.
            guard connected == 0, address.ss_family == addressFamilySystem else { continue }

            // The extension holds other kernel control sockets, so confirm this
            // one is the tunnel by asking it for its interface name.
            var name = [CChar](repeating: 0, count: interfaceNameLimit + 1)
            var nameLength = socklen_t(name.count)
            guard
                getsockopt(
                    descriptor,
                    systemProtocolControl,
                    utunOptionInterfaceName,
                    &name,
                    &nameLength
                ) == 0
            else { continue }

            if String(cString: name).hasPrefix("utun") {
                return descriptor
            }
        }
        return nil
    }

    /// Runs the tunnel. Blocks until ``quit()`` is called or the tunnel fails,
    /// so call it off the main queue.
    static func run(configuration: String) throws {
        guard let descriptor = tunnelFileDescriptor() else {
            throw Failure.tunnelDescriptorNotFound
        }

        let bytes = Array(configuration.utf8)
        let code = bytes.withUnsafeBufferPointer { buffer in
            hev_socks5_tunnel_main_from_str(
                buffer.baseAddress,
                UInt32(bytes.count),
                descriptor
            )
        }
        if code != 0 {
            throw Failure.exited(code: code)
        }
    }

    static func quit() {
        hev_socks5_tunnel_quit()
    }

    static var stats: Stats {
        var uploadPackets = 0
        var uploadBytes = 0
        var downloadPackets = 0
        var downloadBytes = 0
        hev_socks5_tunnel_stats(&uploadPackets, &uploadBytes, &downloadPackets, &downloadBytes)
        return Stats(uploadBytes: uploadBytes, downloadBytes: downloadBytes)
    }

    /// Builds the tun2socks configuration.
    ///
    /// The buffer and session limits are deliberately below the library's
    /// defaults: a packet tunnel provider is capped at 50 MiB on iOS 15+ (15 MiB
    /// on iOS 14 and earlier) and jetsam kills the process outright when it goes
    /// over. Defaults sized for a desktop will not survive here.
    ///
    /// `log-file` must be `stdout` or `stderr`: anything else, `null` included,
    /// is opened as a file path relative to `/`, which the sandbox refuses, and
    /// tun2socks exits with -2 before moving a packet.
    static func configuration(socksPort: Int, mtu: Int, logLevel: String = "warn") -> String {
        """
        tunnel:
          mtu: \(mtu)
        socks5:
          port: \(socksPort)
          address: 127.0.0.1
          udp: 'udp'
        misc:
          task-stack-size: 20480
          tcp-buffer-size: 32768
          udp-recv-buffer-size: 262144
          max-session-count: 256
          connect-timeout: 5000
          tcp-read-write-timeout: 300000
          udp-read-write-timeout: 60000
          limit-nofile: 16384
          log-file: stderr
          log-level: \(logLevel)
        """
    }
}
