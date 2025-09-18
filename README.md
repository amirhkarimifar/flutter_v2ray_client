# flutter_v2ray_client

[![Open Source Love](https://badges.frapsoft.com/os/v1/open-source.svg?v=103)](#)
![](https://img.shields.io/github/license/amir-zr/flutter_v2ray_client)
![](https://img.shields.io/github/stars/amir-zr/flutter_v2ray_client)
![](https://img.shields.io/github/forks/amir-zr/flutter_v2ray_client)
![](https://img.shields.io/github/tag/amir-zr/flutter_v2ray_client)
![](https://img.shields.io/github/release/amir-zr/flutter_v2ray_client)
![](https://img.shields.io/github/issues/amir-zr/flutter_v2ray_client)

## Table of contents
- [flutter\_v2ray\_client](#flutter_v2ray_client)
  - [Table of contents](#table-of-contents)
  - [⚡ Features](#-features)
  - [📸 Screenshots](#-screenshots)
  - [📱 Supported Platforms](#-supported-platforms)
  - [🚀 Get started](#-get-started)
    - [🔗 Add dependency](#-add-dependency)
    - [💡 Examples](#-examples)
      - [URL Parser](#url-parser)
      - [Edit Configuration](#edit-configuration)
      - [Making V2Ray connection](#making-v2ray-connection)
      - [Exclude specific apps from VPN (blockedApps)](#exclude-specific-apps-from-vpn-blockedapps)
      - [Bypass LAN Traffic](#bypass-lan-traffic)
  - [🤖 Android configuration before publish to Google Play🚀](#-android-configuration-before-publish-to-google-play)
    - [Android 16 KB Page Size Support](#android-16-kb-page-size-support)
    - [gradle.properties](#gradleproperties)
    - [build.gradle (app)](#buildgradle-app)
  - [🔮 Roadmap \& Future Enhancements](#-roadmap--future-enhancements)
    - [🚀 Performance Improvements](#-performance-improvements)
    - [🌟 Planned Features](#-planned-features)
    - [💡 Community Contributions](#-community-contributions)
  - [📋 Attribution](#-attribution)
  - [💰 Donation](#-donation)

## ⚡ Features
- Run V2Ray Proxy & VPN Mode
- Get Server Delay (outbound and connected)
- Parsing V2Ray sharing links and making changes to them
- Built-in socket protection for Android VPN tunneling
- Live status updates: connection state, speeds, traffic, duration

<br>

## 📸 Screenshots

| Main Screen |
|-------------|
|<img src="screenshots/main_screen.png" alt="Main Screen" width="300"/>|

*Example app demonstrating flutter_v2ray_client features*

<br>

## 📱 Supported Platforms
| Platform  | Status    | Info |
| --------- | --------- | ---- |
| Android   | Done ✅   | Xray 25.9.11 |
| iOS       | Coming Soon | Support via [Donations](#donation) |
| Windows   | Coming Soon | Support via [Donations](#donation) |
| Linux     | Coming Soon | Support via [Donations](#donation) |
| macOS     | Coming Soon | Support via [Donations](#donation) |

*Note: Support for iOS, Windows, Linux, and macOS can be accelerated through [Donations](#donation). Please see the [Donation](#donation) section below to contribute and help prioritize platform development.*

<br>

## 🚀 Get started

### 🔗 Add dependency
You can use the command to add flutter_v2ray_client as a dependency with the latest stable version:

```console
$ flutter pub add flutter_v2ray_client
```

Or you can manually add flutter_v2ray_client into the dependencies section in your pubspec.yaml:

```yaml
dependencies:
  flutter_v2ray_client: ^1.0.0
```

<br>

### 💡 Examples

#### URL Parser
``` dart
import 'package:flutter_v2ray_client/flutter_v2ray.dart';

// v2ray share link like vmess://, vless://, ...
String link = "link_here";
V2RayURL parser = V2ray.parseFromURL(link);

// Remark of the v2ray
print(parser.remark);

// generate full v2ray configuration (json)
print(parser.getFullConfiguration());
```

#### Edit Configuration
``` dart
// Change v2ray listening port
parser.inbound['port'] = 10890;
// Change v2ray listening host
parser.inbound['listen'] = '0.0.0.0';
// Change v2ray log level
parser.log['loglevel'] = 'info';
// Change v2ray dns
parser.dns = {
    "servers": ["1.1.1.1"]
};
// and ...

// generate configuration with new settings
parser.getFullConfiguration()
```

<br>

#### Making V2Ray connection
``` dart
import 'package:flutter_v2ray_client/flutter_v2ray.dart';

final V2ray v2ray = V2ray(
    onStatusChanged: (status) {
        // Handle status changes: connected, disconnected, etc.
        print('V2Ray status: ${status.state}');
    },
);

// You must initialize V2Ray before using it.
await v2ray.initialize(
    notificationIconResourceType: "mipmap",
    notificationIconResourceName: "ic_launcher",
);

// v2ray share link like vmess://, vless://, ...
String link = "link_here";
V2RayURL parser = V2ray.parseFromURL(link);

// Get Server Delay
print('${await v2ray.getServerDelay(config: parser.getFullConfiguration())}ms');

// Permission is not required if using proxy only
if (await v2ray.requestPermission()){
    v2ray.startV2Ray(
        remark: parser.remark,
        // The use of parser.getFullConfiguration() is not mandatory,
        // and you can enter the desired V2Ray configuration in JSON format
        config: parser.getFullConfiguration(),
        blockedApps: null,
        bypassSubnets: null,
        proxyOnly: false,
    );
}

// Disconnect
v2ray.stopV2Ray();
```

<br>

#### Exclude specific apps from VPN (blockedApps)
```dart
// Provide Android package names to exclude from VPN tunneling.
// Traffic from these apps will NOT go through the VPN tunnel.
final List<String> blockedApps = <String>[
  'com.whatsapp',
  'com.google.android.youtube',
  'com.instagram.android',
];

await v2ray.startV2Ray(
  remark: parser.remark,
  config: parser.getFullConfiguration(),
  blockedApps: blockedApps, // <— excluded from VPN
  bypassSubnets: null,
  proxyOnly: false,
);
```

Tips:
- Android package names are required (e.g., `com.example.app`).
- To find a package name, you can:
  - Use: `adb shell pm list packages | grep <keyword>`
  - Or check Play Store URL (e.g., `id=com.whatsapp`).
- If you want to make this user-selectable, let users pick apps then store their package names and pass them as `blockedApps`.
- This mirrors how the app code uses `blockedApps` in `lib/services/v2ray_service.dart` when starting V2Ray.

<br>

#### Bypass LAN Traffic
```dart
final List<String> subnets = [
    "0.0.0.0/5",
    "8.0.0.0/7",
    "11.0.0.0/8",
    "12.0.0.0/6",
    "16.0.0.0/4",
    "32.0.0.0/3",
    "64.0.0.0/2",
    "128.0.0.0/3",
    "160.0.0.0/5",
    "168.0.0.0/6",
    "172.0.0.0/12",
    "172.32.0.0/11",
    "172.64.0.0/10",
    "172.128.0.0/9",
    "173.0.0.0/8",
    "174.0.0.0/7",
    "176.0.0.0/4",
    "192.0.0.0/9",
    "192.128.0.0/11",
    "192.160.0.0/13",
    "192.169.0.0/16",
    "192.170.0.0/15",
    "192.172.0.0/14",
    "192.176.0.0/12",
    "192.192.0.0/10",
    "193.0.0.0/8",
    "194.0.0.0/7",
    "196.0.0.0/6",
    "200.0.0.0/5",
    "208.0.0.0/4",
    "240.0.0.0/4",
];

v2ray.startV2Ray(
    remark: parser.remark,
    config: parser.getFullConfiguration(),
    blockedApps: null,
    bypassSubnets: subnets,
    proxyOnly: false,
);
```

<br>

## 🤖 Android configuration before publish to Google Play🚀

### Android 16 KB Page Size Support
This package fully supports Android's 16 KB page size, ensuring compatibility with the latest Android devices and requirements for Google Play Store publishing. The plugin is built with modern Android development practices that handle both 4 KB and 16 KB page sizes seamlessly.

### gradle.properties
- add this line
```gradle
android.bundle.enableUncompressedNativeLibs = false
```

### build.gradle (app)
- Find the buildTypes block:
```gradle
buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
               signingConfig signingConfigs.release
        }
    }
```
- And replace it with the following configuration info:
```gradle
splits {
        abi {
            enable true
            reset()
            //noinspection ChromeOsAbiSupport
            include "x86_64", "armeabi-v7a", "arm64-v8a"

            universalApk true
        }
    }

   buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
               signingConfig signingConfigs.release
               ndk {
                //noinspection ChromeOsAbiSupport
                abiFilters "x86_64", "armeabi-v7a", "arm64-v8a"
                debugSymbolLevel 'FULL'
            }
        }
    }
```

## 🔮 Roadmap & Future Enhancements

### 🚀 Performance Improvements
- **hev-socks5-tunnel Integration**: Implement [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel) for significantly better performance in terms of speed and resource usage
- High-performance SOCKS5 tunneling with lower CPU and memory consumption
- Enhanced connection stability and throughput

### 🌟 Planned Features
- Enhanced multi-platform support (iOS, Windows, Linux, macOS)
- Advanced traffic routing and filtering options
- Improved user interface components
- Extended protocol support

### 💡 Community Contributions
We welcome contributions from the community! If you're interested in helping implement any of these features, please check our [contribution guidelines](./CONTRIBUTING.md) and feel free to open issues or pull requests.

---

## 📋 Attribution
This project uses third-party libraries and resources.
See [📋 ATTRIBUTION.md](./ATTRIBUTION.md) for details.

All rights reserved.

## 💰 Donation
<style>.donation-link:hover img { transform: scale(1.05); transition: transform 0.3s ease; }</style>
If you liked this package and want to accelerate the development of iOS and desktop platform support, consider supporting the project with a donation below. Your contributions will directly help bring flutter_v2ray_client to more platforms faster!

<div style="display: flex; gap: 10px; align-items: center;">
<a href="https://nowpayments.io/donation?api_key=1194fbf5-0420-4156-bc86-2d49033517c5" target="_blank" rel="noreferrer noopener" class="donation-link">
   <img src="https://nowpayments.io/images/embeds/donation-button-black.svg" alt="Cryptocurrency & Bitcoin donation button by NOWPayments" width="150" style="border: 2px solid white; border-radius: 8px;">
</a>
</div>