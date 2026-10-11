# LiveActivityWidget — Xcode wiring (macOS host required)

`project.pbxproj` was intentionally NOT hand-edited: a Widget Extension
target needs generated IDs Xcode owns. Do these steps once on a Mac —
about 5 minutes. Swift sources here are complete but **not compiled —
no Xcode** on the Linux host.

1. Open `mobile/ios/Runner.xcworkspace` in Xcode.
2. File → New → Target → **Widget Extension** → Next.
3. Product Name: `LiveActivityWidget`. **Uncheck** "Include Live Activity"
   (this folder already provides it). Finish.
4. Delete the Xcode-generated `.swift` + `Info.plist` inside the new
   target folder; move in this folder's files instead:
   `LiveActivityWidget.swift`, `LiveActivityWidgetBundle.swift`,
   `Info.plist` (target membership: LiveActivityWidget ONLY — never
   Runner).
5. Runner target → General → Frameworks, Libraries, and Embedded
   Content: add `LiveActivityWidget.appex` (Embed & Sign).
6. Runner target → Build Settings → `IPHONEOS_DEPLOYMENT_TARGET` ≥ 16.1
   for the LiveActivityWidget target (Runner itself may stay 15.0;
   `LiveActivityManager` degrades via `#available`).
7. Confirm `Runner/Info.plist` contains `NSSupportsLiveActivities = YES`
   (already committed).
8. Build & run on a real device (iOS 16.1+): triage cards appear →
   Lock Screen shows "N waiting / Top: \<title\>", Dynamic Island shows
   the count badge + agent.

No App Group is needed: state flows Dart → Swift (MethodChannel) →
ActivityKit in-process; the extension only renders `ContentState`.
