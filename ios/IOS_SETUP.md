# iOS setup

On Android the VPN runs inside the app process, so the plugin ships everything.
iOS does not allow that: the tunnel must run in a **Network Extension**, which
is a separate process with its own bundle identifier, its own entitlements and a
**50 MiB memory cap** enforced by the system.

A pod is linked into the app target only, so the plugin cannot create that
extension for you. The extension's sources ship in `ios/Extension/` and you add
them to a target in your own project. This is a one-time setup.

A physical device is required. `NEPacketTunnelProvider` does not function in the
Simulator — the simulator slice of the tun2socks library is a stub that fails
cleanly so builds still link.

---

## 1. Build the two frameworks

Neither is vendored as a prebuilt binary: Xray-core is MPL-2.0 and needs
corresponding source, and a binary of unknown provenance inside your signed app
is a liability. Both are built from pinned upstream commits by CI.

> GitHub → **Actions** → **Build Xray.xcframework (iOS)** → *Run workflow* →
> keep the Xray-core tag in step with Android (currently `v26.2.6`).
>
> Then **Build HevSocks5Tunnel.xcframework (iOS)** → *Run workflow*.

Download both artifacts and unzip them into this folder:

```
ios/Xray.xcframework
ios/HevSocks5Tunnel.xcframework
```

Each contains a `BUILD_INFO.txt` naming the exact upstream commit it came from —
keep it, it is your MPL compliance record.

To build locally instead (macOS + Xcode required), see `ios/core/README.md`.

## 2. App target

Open `Runner.xcworkspace`.

- Minimum Deployment Target: **iOS 15.0**
- In `ios/Podfile`: `platform :ios, '15.0'`
- **Signing & Capabilities** → add:
  - **App Groups** → create one, e.g. `group.com.yourcompany.yourapp`
  - **Network Extensions** → tick **Packet Tunnel**

Then `cd ios && pod install`.

> The Network Extension entitlement needs an **explicit App ID** — a wildcard
> provisioning profile will build and then fail at runtime with a permission
> error rather than a build error.

## 3. Extension target

- **File → New → Target → Network Extension**, name it **`XrayTunnel`**
- Minimum Deployment Target: **iOS 15.0**
- Its bundle identifier must be a child of the app's, e.g.
  `com.yourcompany.yourapp.XrayTunnel`
- **Signing & Capabilities** → add **App Groups** (select the *same* group) and
  **Network Extensions** → **Packet Tunnel**

Copy these three files from `ios/Extension/` of this plugin into the target:

| File | Purpose |
| --- | --- |
| `PacketTunnelProvider.swift` | The tunnel itself |
| `Tun2Socks.swift` | Moves packets between utun and Xray's SOCKS inbound |
| `TunnelIPC.swift` | Message contract shared with the app |

Replace Xcode's generated `PacketTunnelProvider.swift` with the one you copied,
and delete the generated stub.

In the **XrayTunnel** target's **General → Frameworks and Libraries**, add:

- `Xray.xcframework`
- `HevSocks5Tunnel.xcframework`
- `libresolv.tbd`

Finally, in the **Runner** target's **Build Phases**, drag **Embed Foundation
Extensions** below **Copy Bundle Resources**. Out of order, the extension is
embedded before the app's resources exist and the build fails intermittently.

### Extension `Info.plist`

```xml
<key>NSExtension</key>
<dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.networkextension.packet-tunnel</string>
    <key>NSExtensionPrincipalClass</key>
    <string>$(PRODUCT_MODULE_NAME).PacketTunnelProvider</string>
</dict>
```

## 4. Dart

Pass the extension's bundle identifier and the app group:

```dart
final v2ray = V2ray(onStatusChanged: (status) => setState(() => _status = status));

await v2ray.initialize(
  // Android
  notificationIconResourceType: 'mipmap',
  notificationIconResourceName: 'ic_launcher',
  // iOS
  providerBundleIdentifier: 'com.yourcompany.yourapp.XrayTunnel',
  groupIdentifier: 'group.com.yourcompany.yourapp',
);

// On iOS this installs the VPN profile, which is what shows the system sheet.
if (await v2ray.requestPermission()) {
  await v2ray.startV2Ray(remark: 'My server', config: config);
}
```

Both values are ignored on Android, so one call serves both platforms.

---

## Behaviour differences from Android

| API | iOS |
| --- | --- |
| `blockedApps` | **Ignored.** Per-app VPN is MDM-only on iOS. |
| `proxyOnly` | **Throws `UNSUPPORTED_ON_IOS`.** No app can set a system proxy for other apps. |
| `bypassSubnets` | Not applied as routes; LAN is excluded via `excludeLocalNetworks`. |
| `notificationIcon*`, `notificationDisconnectButtonName` | Ignored — the system owns the VPN UI. |
| `getLogs` / `clearLogs` | Served from a capped log file in the app group, not logcat. |
| `getServerDelay` | Runs in the app process, so it works while disconnected. |
| `getConnectedServerDelay` | Asks the running extension; returns `-1` when disconnected. |

## Memory

The extension is killed by jetsam (`per-process-limit`) if it exceeds 50 MiB.
The core is already tuned for this — a hard `SetMemoryLimit`, `GOGC=10`,
per-second `FreeOSMemory`, and reduced tun2socks buffers and session caps.

**Do not add `geoip.dat` or `geosite.dat` to a config used on iOS.** Loading geo
data will exhaust the budget on its own. Write routing rules that do not need
it.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `permission denied` at start, builds fine | Wildcard App ID, or extension bundle ID is not a child of the app's |
| Profile installs, tunnel never connects | App group not identical on both targets |
| `NOT_INITIALIZED` | `initialize()` not called, or called without the two iOS values |
| Connects, no traffic | Xray config has no local `socks` inbound for tun2socks to reach |
| Tunnel dies after seconds | Memory cap — check for geo data in the config |
| Works on device, not Simulator | Expected; packet tunnels are device-only |

## Third-party code

| Component | License |
| --- | --- |
| [Xray-core](https://github.com/XTLS/Xray-core) | MPL-2.0 |
| [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel) | MIT |

The utun descriptor lookup in `Tun2Socks.swift` uses only public BSD interfaces
(`getpeername`, `getsockopt`). It deliberately avoids the common
`packetFlow.value(forKeyPath: "socket.fileDescriptor")` approach, which reads a
private ivar through KVC and is a plausible App Store rejection.
