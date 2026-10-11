import ActivityKit
import SwiftUI
import WidgetKit

/// Shared ActivityKit attributes — DUPLICATE of
/// `Runner/AgentDeskActivityAttributes` (Widget extensions cannot import
/// Runner code, so the struct is copied verbatim; keep both in sync).
@available(iOS 16.1, *)
struct AgentDeskActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var pendingCount: Int
    var topTitle: String?
    var topAgent: String?
  }

  var appName: String = "AgentDesk"
}

/// Lock Screen + Dynamic Island presentation for the waiting stack:
/// "N agents waiting — top: <title>".
@available(iOS 16.1, *)
struct LiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: AgentDeskActivityAttributes.self) { context in
      // Lock Screen / banner: count + top card title.
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text("\(context.state.pendingCount) waiting")
            .font(.headline)
          Spacer()
          if let agent = context.state.topAgent {
            Text(agent)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        if let title = context.state.topTitle {
          Text("Top: \(title)")
            .font(.subheadline)
            .lineLimit(2)
        }
      }
      .padding()
      .activityBackgroundTint(Color(.systemBackground))
      .activitySystemActionForegroundColor(Color.primary)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Text("\(context.state.pendingCount)")
            .font(.title2)
            .fontWeight(.bold)
            .padding(.leading)
        }
        DynamicIslandExpandedRegion(.trailing) {
          if let agent = context.state.topAgent {
            Text(agent)
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.trailing)
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          if let title = context.state.topTitle {
            Text(title)
              .font(.subheadline)
              .lineLimit(2)
              .padding(.horizontal)
          }
        }
      } compactLeading: {
        Text("\(context.state.pendingCount)")
          .font(.caption)
          .fontWeight(.semibold)
      } compactTrailing: {
        Image(systemName: "tray.full")
      } minimal: {
        Image(systemName: "tray.full")
      }
      .keylineTint(Color.accentColor)
    }
  }
}
