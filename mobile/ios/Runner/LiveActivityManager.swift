import ActivityKit
import Flutter
import UIKit

/// Dart-facing Live Activities bridge (Phase 3).
///
/// Channel `dev.agentdesk/live_activities`, methods:
///   `update {pendingCount, topTitle?, topAgent?}` — start the activity
///     when none is running, otherwise refresh its content state.
///   `end` — finish immediately.
///
/// Requires iOS 16.1+ (`ActivityKit`). Older systems and missing
/// entitlements resolve `notImplemented`/ack silently so Dart treats
/// the mirror as best-effort.
///
/// NOTE (Linux host, no Xcode): written carefully against the iOS 16.1
/// ActivityKit API but NOT compiled — see `LiveActivityWidget/SETUP.md`.
@available(iOS 16.1, *)
struct AgentDeskActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var pendingCount: Int
    var topTitle: String?
    var topAgent: String?
  }

  /// Static (launch-time) attributes — displayed identity of the app.
  var appName: String = "AgentDesk"
}

/// `NSObject` host so `AppDelegate` stays one call site; all ActivityKit
/// work is `#available`-gated for iOS 16.1+.
final class LiveActivityManager: NSObject {
  static let channelName = "dev.agentdesk/live_activities"

  private var channel: FlutterMethodChannel?
  private var current: Any?  // Activity<AgentDeskActivityAttributes>, type-erased

  @available(iOS 16.1, *)
  private var activity: Activity<AgentDeskActivityAttributes>? {
    get { current as? Activity<AgentDeskActivityAttributes> }
    set { current = newValue }
  }

  func register(with messenger: NSObjectProtocol & FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "update":
      let args = call.arguments as? [String: Any] ?? [:]
      let count = args["pendingCount"] as? Int ?? 0
      let topTitle = args["topTitle"] as? String
      let topAgent = args["topAgent"] as? String
      update(pendingCount: count, topTitle: topTitle, topAgent: topAgent, result: result)
    case "end":
      end(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func update(
    pendingCount: Int,
    topTitle: String?,
    topAgent: String?,
    result: @escaping FlutterResult
  ) {
    if #available(iOS 16.1, *) {
      let state = AgentDeskActivityAttributes.ContentState(
        pendingCount: pendingCount,
        topTitle: topTitle,
        topAgent: topAgent
      )
      do {
        if let running = activity {
          Task {
            await running.update(
              ActivityContent(state: state, staleDate: nil)
            )
            result(nil)
          }
        } else {
          let attributes = AgentDeskActivityAttributes()
          activity = try Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil
          )
          result(nil)
        }
      } catch {
        // System denied the start (e.g. Live Activities disabled).
        // Best-effort mirror: never fail triage for it.
        result(nil)
      }
    } else {
      result(FlutterMethodNotImplemented)
    }
  }

  private func end(result: @escaping FlutterResult) {
    if #available(iOS 16.1, *) {
      Task {
        if let running = self.activity {
          await running.end(
            ActivityContent(
              state: AgentDeskActivityAttributes.ContentState(
                pendingCount: 0,
                topTitle: nil,
                topAgent: nil
              ),
              staleDate: nil
            ),
            dismissalPolicy: .immediate
          )
          self.activity = nil
        }
        result(nil)
      }
    } else {
      result(FlutterMethodNotImplemented)
    }
  }
}
