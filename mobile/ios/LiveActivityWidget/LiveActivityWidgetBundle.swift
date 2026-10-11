import SwiftUI
import WidgetKit

/// Entry point for the LiveActivityWidget extension target.
/// Add this file to the Widget Extension target in Xcode (see SETUP.md);
/// do NOT add it to the Runner target.
@main
struct LiveActivityWidgetBundle: WidgetBundle {
  var body: some Widget {
    if #available(iOS 16.1, *) {
      LiveActivityWidget()
    }
  }
}
