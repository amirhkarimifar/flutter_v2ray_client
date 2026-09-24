#
# Podspec for the app-side half of the plugin.
#
# The packet tunnel extension is NOT built by this pod: a pod is linked into the
# host app target, and the tunnel has to live in its own Network Extension
# target. The extension's sources are shipped in ios/Extension/ and added to
# that target by the host app. See ios/IOS_SETUP.md.
#
# Xray.xcframework must be built before `pod install` — it is not vendored as a
# prebuilt binary. See ios/core/README.md.
#
# Run `pod lib lint ipconnect_core.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'ipconnect_core'
  s.version          = '3.3.0'
  s.summary          = 'Xray/V2Ray core for IP Connect'
  s.description      = <<-DESC
App-side control of the IP Connect VPN. On iOS the tunnel runs in a
NEPacketTunnelProvider extension; this pod is the app-side control surface.
                       DESC
  s.homepage         = 'https://github.com/amirhkarimifar/flutter_v2ray_client'
  s.license          = { :file => '../LICENSE' }
  # Maintained by NEOMANERA LTD; derived from Amir Ziari's flutter_v2ray_client
  # (MIT, see LICENSE and ATTRIBUTION.md).
  s.authors          = ['NEOMANERA LTD', 'Amir Ziari']
  s.source           = { :path => '.' }

  # Classes/ is the app side. TunnelIPC is the only file shared with the
  # extension: it defines the message contract, so both processes compile the
  # same definition and cannot drift apart.
  s.source_files = 'Classes/**/*', 'Extension/TunnelIPC.swift'

  s.dependency 'Flutter'

  # NEPacketTunnelProvider and the async NetworkExtension APIs used here need
  # iOS 15. The memory cap for a packet tunnel is also 50 MiB from 15 onward,
  # versus 15 MiB before it, which the core is tuned against.
  s.platform = :ios, '15.0'

  s.frameworks = 'NetworkExtension'

  # Go's resolver calls into libresolv on Apple platforms.
  s.libraries = 'resolv'

  # The app links the core as well as the extension does, because
  # getServerDelay() tests an arbitrary config while disconnected and so has to
  # run in the app process.
  s.vendored_frameworks = 'Xray.xcframework'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.0'
end
