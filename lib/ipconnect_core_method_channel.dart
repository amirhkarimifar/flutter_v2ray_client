import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ipconnect_core_platform_interface.dart';
import 'model/v2ray_status.dart' show V2RayStatus;

/// An implementation of [IpConnectCorePlatform] that uses method channels.
class MethodChannelIpConnectCore extends IpConnectCorePlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('ipconnect_core');

  /// The event channel used to receive status updates from the native platform.
  final eventChannel = const EventChannel('ipconnect_core/status');

  @override
  Future<void> initializeV2Ray({
    required void Function(V2RayStatus status) onStatusChanged,
    required String notificationIconResourceType,
    required String notificationIconResourceName,
    String providerBundleIdentifier = '',
    String groupIdentifier = '',
  }) async {
    eventChannel.receiveBroadcastStream().distinct().cast().listen((event) {
      if (event != null) {
        onStatusChanged.call(V2RayStatus(
          duration: event[0],
          uploadSpeed: int.parse(event[1]),
          downloadSpeed: int.parse(event[2]),
          upload: int.parse(event[3]),
          download: int.parse(event[4]),
          state: event[5],
        ));
      }
    });
    await methodChannel.invokeMethod(
      'initializeV2Ray',
      {
        'notificationIconResourceType': notificationIconResourceType,
        'notificationIconResourceName': notificationIconResourceName,
        'providerBundleIdentifier': providerBundleIdentifier,
        'groupIdentifier': groupIdentifier,
      },
    );
  }

  @override
  Future<void> startV2Ray({
    required String remark,
    required String config,
    required String notificationDisconnectButtonName,
    List<String>? blockedApps,
    List<String>? bypassSubnets,
    bool proxyOnly = false,
  }) async {
    await methodChannel.invokeMethod('startV2Ray', {
      'remark': remark,
      'config': config,
      'blocked_apps': blockedApps,
      'bypass_subnets': bypassSubnets,
      'proxy_only': proxyOnly,
      'notificationDisconnectButtonName': notificationDisconnectButtonName,
    });
  }

  @override
  Future<void> stopV2Ray() async {
    await methodChannel.invokeMethod('stopV2Ray');
  }

  @override
  Future<int> getServerDelay({
    required String config,
    required String url,
  }) async {
    return await methodChannel.invokeMethod('getServerDelay', {
      'config': config,
      'url': url,
    });
  }

  @override
  Future<int> getConnectedServerDelay(String url) async {
    return await methodChannel
        .invokeMethod('getConnectedServerDelay', {'url': url});
  }

  @override
  Future<bool> requestPermission() async {
    return (await methodChannel.invokeMethod('requestPermission')) ?? false;
  }

  @override
  Future<String> getCoreVersion() async {
    return await methodChannel.invokeMethod('getCoreVersion');
  }

  @override
  Future<String?> consumeLastGoCrash() async {
    return await methodChannel.invokeMethod<String>('consumeLastGoCrash');
  }

  @override
  Future<List<String>> getLogs() async {
    try {
      final result = await methodChannel.invokeMethod('getLogs');
      if (result is List) {
        return result.cast<String>();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  @override
  Future<bool> clearLogs() async {
    try {
      final result = await methodChannel.invokeMethod('clearLogs');
      return result == true;
    } catch (e) {
      return false;
    }
  }
}
