import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let liveActivities = LiveActivityManager()
  // NATIVE-PUSH: plain-APNs manager (channel `dev.agentdesk/push`).
  // Independent of the Live Activities block above — keep both.
  private var nativePush: NativePushManager?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Live Activities channel on the app-level messenger (NOT the plugin
    // registry — sibling plugin lanes are unaffected).
    liveActivities.register(with: engineBridge.applicationRegistrar.messenger())
    // NATIVE-PUSH: same accessor, second channel for APNs registration.
    nativePush = NativePushManager(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
  }

  // NATIVE-PUSH: forward the APNs token (or failure) to the manager,
  // which completes the pending Dart `register()` call.
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    nativePush?.didRegister(deviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    nativePush?.didFailToRegister(error: error)
  }
}
