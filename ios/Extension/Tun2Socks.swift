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
/// runs, so `getpeername(2)` plus `ioctl(CTLIOCGINFO)` identifies it with
/// nothing but public BSD interfaces.
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

    private static func tunnelFileDescriptor() -> Int32? {
        var controlInfo = ctl_info()
        withUnsafeMutablePointer(to: &controlInfo.ctl_name) { namePointer in
            namePointer.withMemoryRebound(
                to: CChar.self,
                capacity: MemoryLayout.size(ofValue: namePointer.pointee)
            ) { name in
                _ = strcpy(name, "com.apple.net.utun_control")
            }
        }

        for descriptor in Int32(0)...maxDescriptor {
            var address = sockaddr_ctl()
            var length = socklen_t(MemoryLayout.size(ofValue: address))
            var result: Int32 = -1

            withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    result = getpeername(descriptor, generic, &length)
                }
            }

            // Not a socket, or not a kernel control socket: keep looking.
            guard result == 0, address.sc_family == AF_SYSTEM else { continue }

            if controlInfo.ctl_id == 0 {
                guard ioctl(descriptor, CTLIOCGINFO, &controlInfo) == 0 else { continue }
            }
            if address.sc_id == controlInfo.ctl_id {
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
          log-file: null
          log-level: \(logLevel)
        """
    }
}
