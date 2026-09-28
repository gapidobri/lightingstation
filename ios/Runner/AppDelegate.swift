import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var notchChannel: FlutterMethodChannel?
  private var notchSide: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Running a show: the screen stays on while the app is open.
    application.isIdleTimerDisabled = true
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // iOS reports equal left and right insets in landscape, so tell Flutter
    // which edge the notch (or Dynamic Island) is on.
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NotchSide")!
    let channel = FlutterMethodChannel(name: "lightingstation/notch", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "side" {
        result(self?.currentNotchSide())
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    notchChannel = channel
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    NotificationCenter.default.addObserver(
      self, selector: #selector(orientationChanged), name: UIDevice.orientationDidChangeNotification, object: nil)
  }

  @objc private func orientationChanged() {
    // The interface rotates just after the device does; check again once the
    // rotation has settled.
    for delay in [0.0, 0.5] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.pushNotchSide() }
    }
  }

  private func pushNotchSide() {
    let side = currentNotchSide()
    guard side != notchSide else { return }
    notchSide = side
    notchChannel?.invokeMethod("side", arguments: side)
  }

  private func currentNotchSide() -> String? {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    switch scene?.interfaceOrientation {
    // Landscape right: home button (or bottom edge) on the right, top edge on the left.
    case .landscapeRight: return "left"
    case .landscapeLeft: return "right"
    default: return nil
    }
  }
}
