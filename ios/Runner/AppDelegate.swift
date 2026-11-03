import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // A dash: the screen stays on while the app is in front.
    application.isIdleTimerDisabled = true
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // The dash's own channel. On iOS only Maps is answered: joining the
    // Commander's WiFi, its panel and the rotation hold are Android's.
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TeslaDashNet") else { return }
    FlutterMethodChannel(name: "tesla_dash/net", binaryMessenger: registrar.messenger())
      .setMethodCallHandler { call, result in
        switch call.method {
        case "openMaps": result(AppDelegate.openMaps())
        default: result(FlutterMethodNotImplemented)
        }
      }
  }

  /// No split screen on an iPhone: Maps opens in front, Google's in its
  /// driving mode, Apple's if Google's is not installed. The dash is a swipe
  /// away.
  private static func openMaps() -> String {
    if let google = URL(string: "comgooglemaps://?directionsmode=driving"),
      UIApplication.shared.canOpenURL(google)
    {
      UIApplication.shared.open(google)
      return "opened"
    }
    guard let apple = URL(string: "maps://") else { return "missing" }
    UIApplication.shared.open(apple)
    return "opened"
  }
}
