import Flutter
import UIKit
import UserNotifications

// NATIVE-PUSH: plain-APNs registration behind the `dev.agentdesk/push`
// MethodChannel. No Firebase — the app never needs google-services.json.
//
// Wiring (see AppDelegate.swift NATIVE-PUSH block): the manager is
// created with the implicit engine's binary messenger and owns the
// channel handler + the APNs token handoff. `register` (Dart → native)
// requests authorization and calls `registerForRemoteNotifications`;
// the resulting hex device token completes the pending result, or an
// error if permission is denied / registration fails.
//
// NOTE: not compiled — no Xcode on this host. Uses only the stable
// `applicationRegistrar.messenger()` accessor + public
// UNUserNotificationCenter / UIApplication APIs.
final class NativePushManager: NSObject {
  private let channel: FlutterMethodChannel
  private var pendingResult: FlutterResult?

  init(messenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(
      name: "dev.agentdesk/push",
      binaryMessenger: messenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "register":
      requestRegistration(result: result)
    case "unregister":
      // Nothing device-side to tear down; the Dart side deletes the hub
      // row explicitly. Kept so the Dart API never hits "not implemented".
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestRegistration(result: @escaping FlutterResult) {
    // One in-flight registration at a time; a second `register` call
    // while one is pending answers "already_in_progress" instead of
    // clobbering the first caller.
    if pendingResult != nil {
      result(
        FlutterError(
          code: "already_in_progress",
          message: "APNs registration already in progress",
          details: nil
        )
      )
      return
    }
    pendingResult = result
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] granted, _ in
      guard let self else { return }
      guard granted else {
        self.complete(
          with: FlutterError(
            code: "permission_denied",
            message: "Notification permission denied",
            details: nil
          )
        )
        return
      }
      DispatchQueue.main.async {
        UIApplication.shared.registerForRemoteNotifications()
      }
    }
  }

  /// Called from AppDelegate's
  /// `didRegisterForRemoteNotificationsWithDeviceToken`.
  func didRegister(deviceToken: Data) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    complete(with: hex)
  }

  /// Called from AppDelegate's `didFailToRegisterForRemoteNotifications`.
  func didFailToRegister(error: Error) {
    complete(
      with: FlutterError(
        code: "registration_failed",
        message: error.localizedDescription,
        details: nil
      )
    )
  }

  private func complete(with value: Any?) {
    guard let pending = pendingResult else { return }
    pendingResult = nil
    // FlutterMethodChannel results must settle on the main thread.
    if Thread.isMainThread {
      pending(value)
    } else {
      DispatchQueue.main.async { pending(value) }
    }
  }
}
