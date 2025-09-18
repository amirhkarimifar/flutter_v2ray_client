import Flutter
import UIKit

public class FlutterV2rayPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    // iOS support is currently not implemented; keeping channel for API parity.
    let channel = FlutterMethodChannel(name: "flutter_v2ray_client", binaryMessenger: registrar.messenger())
    let instance = FlutterV2rayPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
