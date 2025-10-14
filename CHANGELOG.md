# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0]

### Added
- **Security**: Implemented app-specific broadcast isolation for V2Ray connections

### Changed
- **Build**: Enabled legacy JNI library packaging for better compatibility
- **Build**: Pinned NDK version to 27.0.12077973 for consistent builds
- **Performance**: Optimized server delay checks with parallel execution

## [1.1.0]

### Added
- **Enhanced VPN Protection**: Implemented robust Android VPN socket protector to prevent connection loops
- **IPv6 Support**: Added IPv6 preference option for server connections
- **Socket Management**: Introduced outbound socket management with automatic IP failover
- **Cross-Platform Builds**: Android-only build tags for seamless development across platforms

### Changed
- **Dependencies**: Updated to `golang.org/x/sys` for Android unix syscalls
- **Core Integration**: Improved Java/Go integration for better reliability
- **Documentation**: Added comprehensive guide for VPN protector implementation

### Fixed
- **Connection Stability**: Resolved issues with VPN socket routing
- **Build System**: Ensured compatibility with non-Android platforms

## [1.0.0]

### Added
- **Initial Release**: Comprehensive Flutter plugin for V2Ray/Xray client functionality
- **VPN & Proxy Modes**: Support for both VPN tunneling and proxy-only connections on Android
- **Server Delay Testing**: Built-in functionality to measure outbound and connected server delays
- **URL Parsing**: Robust parsers for VMess, VLess, Trojan, Socks, and ShadowSocks protocols
- **Configuration Editing**: Flexible API to modify V2Ray inbound/outbound settings, DNS, and routing
- **Live Status Monitoring**: Real-time updates for connection state, upload/download speeds, traffic data, and duration
- **Socket Protection**: Built-in Android VPN socket protection for secure tunneling
- **App Exclusion**: Ability to exclude specific Android apps from VPN traffic (blockedApps)
- **LAN Traffic Bypass**: Support for bypassing local network traffic with custom subnet lists
- **Notification Integration**: Customizable VPN notifications with icon resources
- **Permission Handling**: Automatic Android VPN permission requests
- **Event-Based Updates**: Callback system for status changes and connection events
- **Modernized API**: Clean, documented API with comprehensive Dartdoc comments
- **Example Application**: Complete Flutter app demonstrating all features and usage patterns
- **Android Compatibility**: Full support for Android 16 KB page size (required for Google Play)
- **Cross-Platform Foundation**: Platform interface architecture ready for iOS/Windows/Linux/macOS expansion

### Changed
- **Flutter Compatibility**: Upgraded to Flutter 3.16.0+ and Dart 3.1.0+
- **Code Quality**: Improved lint compliance with flutter_lints and comprehensive documentation
- **Build System**: Gradle 7.4 integration with Android NDK 26.3 support

### Technical Details
- **Android Implementation**: Xray 25.9.11 integration with method channels
- **Plugin Architecture**: Extends plugin_platform_interface for platform abstraction
- **Dependencies**: Minimal external dependencies for stability
- **Testing**: flutter_test integration for unit and widget testing
- **Licensing**: Open-source MIT license for community adoption

### Roadmap Highlights
- **Performance**: Planned integration with hev-socks5-tunnel for enhanced speed and efficiency
- **Multi-Platform**: Foundation laid for iOS, Windows, Linux, and macOS support (community-driven via donations)
- **Advanced Features**: Traffic routing, filtering, and UI components in development

### Attribution
This project builds upon third-party libraries and open-source contributions. See [ATTRIBUTION.md](./ATTRIBUTION.md) for detailed credits.

### Notes
- Android is the primary supported platform; other platforms marked as "Coming Soon"
- Community contributions welcome for accelerating multi-platform development
