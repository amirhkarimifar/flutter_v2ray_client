# Xray core for iOS

This module builds `Xray.xcframework`, the Xray-core binding the iOS packet
tunnel extension links against. It is the iOS counterpart of
`android/libs/libv2ray.aar` — keep the two on the same Xray-core release so the
platforms behave identically.

## Why the core is built here

The framework is deliberately not vendored as a prebuilt binary:

- Xray-core is MPL-2.0, so a distributed binary needs corresponding source. The
  source is this directory plus the pinned upstream commit, recorded in
  `BUILD_INFO.txt` inside every built framework.
- You need to patch the core and track releases yourself, which a third-party
  blob prevents.

## Building

`gomobile` requires macOS and Xcode. If you are not on a Mac, use CI:

> Actions → **Build Xray.xcframework (iOS)** → Run workflow → pick the
> Xray-core tag → download the artifact → unzip to `ios/Xray.xcframework`.

Locally, from this directory:

```bash
# Pin the core. Release tags such as v26.2.6 are not resolvable as semver,
# because xray-core keeps the module path github.com/xtls/xray-core above
# major version 1 — so pin the tag's commit and let go record a pseudo-version.
SHA=$(git ls-remote https://github.com/XTLS/Xray-core refs/tags/v26.2.6 | cut -f1)
go get "github.com/xtls/xray-core@${SHA}"
go get golang.org/x/mobile/bind
go mod tidy

go install golang.org/x/mobile/cmd/gomobile@latest
gomobile init

gomobile bind -target=ios,iossimulator -iosversion=15.0 \
  -o ../Xray.xcframework -trimpath -ldflags="-s -w" .
```

## The Swift surface

gomobile prefixes everything with the package name, so Swift sees:

| Swift | Purpose |
| --- | --- |
| `XrayVersion()` | Core version string |
| `XrayIsRunning()` | Whether an instance is started |
| `XraySetMemoryLimit(_ megabytes: Int)` | Cap the heap under the jetsam budget; call before `XrayStart` |
| `XraySetAssetPath(_ path: String) throws` | Point at geoip/geosite — only if a config needs them |
| `XrayStart(_ config: Data, _ logger: XrayLogger?) throws` | Start the instance |
| `XrayStop() throws` | Stop it; safe to call when nothing runs |
| `XrayMeasureDelay(_ url: String, _ timeoutMillis: Int) throws -> Int64` | Delay through the running instance |
| `XrayMeasureOutboundDelay(_ config: Data, _ url: String, _ timeoutMillis: Int) throws -> Int64` | Delay through a throwaway instance; needs no tunnel, so it runs in the app process |

`XrayLogger` is a protocol with `logInput(_ line: String)`; the extension
implements it to forward core logs to the host app.

## Memory

The extension is held to **50 MiB** on iOS 15+ (15 MiB on iOS 14 and earlier),
enforced per process and killed by jetsam with
`per-process-limit`. Two consequences:

- `XraySetMemoryLimit` sets `GOGC=10` and a hard `debug.SetMemoryLimit`, and
  `XrayStart` runs `debug.FreeOSMemory()` once a second.
- **Do not load geo data in the extension.** `geoip.dat` and `geosite.dat` will
  exhaust the budget on their own. Write routing rules that do not need them.
