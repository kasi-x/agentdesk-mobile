# Native push: APNs / FCM (I-701 follow-up)

The hub fans out to native devices on every **new** pending card, in
addition to Web Push. Registration always stores; delivery silently
skips while the provider secrets are unset (same pattern as VAPID).

## Apple (APNs) — supported today

Client (no Firebase, plain `UNUserNotificationCenter`):

1. Settings → 「プッシュ通知」→「有効にする」 (iOS only; other
   platforms no-op). The app requests authorization, receives the APNs
   device token via `NativePushManager.swift`, and posts it:
   `POST /api/v1/push/native {platform: "apns", token: "<64 hex>"}`.
2. Xcode project requirements (need a macOS/Xcode host — **not done
   in this repo**): enable the **Push Notifications** capability
   (adds the `aps-environment` entitlement) for the Runner target;
   use a matching provisioning profile. Sandbox (`APNS_SANDBOX=1`)
   for development-signed builds, production host otherwise.

Hub secrets (`wrangler secret put …`, see
`backend/.dev.vars.example`):

| Variable | Meaning |
|---|---|
| `APNS_KEY_ID` | 10-char key ID from Apple Developer → Keys |
| `APNS_TEAM_ID` | 10-char Team ID |
| `APNS_PRIVATE_KEY` | The `.p8` P-256 key (PEM armor or base64/DER) |
| `APNS_BUNDLE_ID` | App bundle id (= `apns-topic`, e.g. `dev.agentdesk.app`) |
| `APNS_SANDBOX` | `1`/`true` for development builds (sandbox host) |

Protocol: the hub mints an ES256 provider JWT (`alg`/`kid` header,
`iss` = team id, `iat`; cached ~50 min) and POSTs
`https://api.push.apple.com/3/device/<token>` (or the sandbox host)
with `apns-push-type: alert`, `apns-priority: 10`,
`{aps: {alert: {title: "AgentDesk", body: <summary>}, sound: "default"},
taskId}`. `400`/`410` prune the token.

## Android (FCM) — server ready, client not yet

The hub implements FCM v1 sends (`FCM_PROJECT_ID`,
`FCM_CLIENT_EMAIL`, `FCM_PRIVATE_KEY` → RS256 service-account JWT →
OAuth token exchange → `POST
https://fcm.googleapis.com/v1/projects/<id>/messages:send
{message: {token, notification: {title, body}, data: {taskId}}}`),
including `NOT_FOUND`/`UNREGISTERED` pruning — but the Flutter app has
**no** Firebase client yet, deliberately: adding `firebase_core` +
`firebase_messaging` + `google-services.json` would break every build
without the uploader's credentials.

To enable later:

1. `flutterfire configure` (writes `google-services.json` /
   `GoogleService-Info.plist` — keep them out of git or in a private
   flavor), add `firebase_core` + `firebase_messaging` to
   `mobile/pubspec.yaml`, initialize in `main()`.
2. Get the FCM registration token via
   `FirebaseMessaging.instance.getToken()`, then post it with the
   existing Dart API: `HttpHubApi.registerNativePush(platform: "fcm",
   token: …)` — no hub changes needed.
3. Set the three `FCM_*` hub secrets.

## API

```
POST   /api/v1/push/native    Authorization: Bearer $CLIENT_TOKEN
body = { "platform": "apns" | "fcm", "token": "…" }
→ 201 {ok: true}   (malformed → 400)

DELETE /api/v1/push/native    Authorization: Bearer $CLIENT_TOKEN
body = { "platform": "apns" | "fcm", "token": "…" }
→ 204
```

Tokens are stored hashed per auth scope (global vs per-user DO), same
as webpush subscriptions.
