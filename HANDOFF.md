# HANDOFF — feat/todo-multiplatform

Worktree: `/home/user/dev/agentdesk-mobile/.worktrees/feat-todo-multiplatform`
(branch `feat/todo-multiplatform`, created via `dev-wt`). 何もコミットしていない —
すべて作業ツリー内。親チェックアウト (main) にはユーザー自身の未コミット変更
(TODO.md / IDEA.md / docs/philosophy.md) があり、それをこの worktree に取り込み済み。

## 環境(再現に必要なパス)

```bash
export PATH=~/llvm-local/usr/lib/llvm-18/bin:~/sdk/flutter/bin:$PATH
export ANDROID_HOME=~/android-sdk
export JAVA_HOME=~/jdk-21
# Linux デスクトップビルドのみ必要:
export PKG_CONFIG_PATH=~/deb-dev/usr/lib/x86_64-linux-gnu/pkgconfig
export LIBRARY_PATH=~/deb-dev/usr/lib/x86_64-linux-gnu
export CPATH=~/deb-dev/usr/include/gstreamer-1.0:~/deb-dev/usr/include/glib-2.0:~/deb-dev/usr/lib/x86_64-linux-gnu/glib-2.0/include
```

- `~/llvm-local` — clang-18 (apt .deb を dpkg-deb -x で展開、sudo なし)
- `~/deb-dev` — gstreamer/glib 系 dev+runtime .deb の展開先 (.pc の prefix は
  全件 `/home/user/deb-dev/usr` に書き換え済み。再展開したら
  `find ~/deb-dev -name "*.pc" | xargs sed -i 's|^prefix=.*|prefix=/home/user/deb-dev/usr|'` を再実行)
- `~/android-sdk` — cmdline-tools + platform-tools + platforms;android-34 + build-tools;34.0.0
- `~/jdk-21` — Temurin JDK (/usr/lib/jvm の java-21 は JRE のみで javac なし)
- Linux ビルド時の注意: `build/native_assets/linux` ディレクトリが無いと
  install ステップが失敗する → `mkdir -p build/native_assets/linux` してから再ビルド。

## 検証済み (親セッションで実施済み・現在のツリー上)

- `flutter analyze` → 0 issues / `flutter test` → 66/66 (※ ExecDesk 系エージェントが
  さらにファイルを増やしている途中なので最終状態では再実行必須)
- `flutter build web` → OK
- `flutter build apk --debug` → `app-debug.apk` OK
- `flutter build linux --debug` → `build/linux/x64/debug/bundle/agentdesk_mobile` OK
- `backend`: `npm install` 済み, `npm run typecheck` OK, `npm test` → 92/92
- Swift (LiveActivityManager/NativePushManager/LiveActivityWidget) は未コンパイル
  (Xcode 不在)。iOS での初回ビルドは macOS ホスト必須。

## 完了した作業 (DONE)

1. **マルチプラットフォーム土台** — `flutter create --platforms=linux,windows,macos,web`
   で 4 フォルダ生成 (追跡方針どおり。`.idea/` `*.iml` は除去済み)。
   `dart:io` を lib から排除 (SocketException→ClientException)。
   SSE を conditional import に分割:
   `sse_client.dart` (export) / `sse_client_io.dart` / `sse_client_web.dart`
   (package:web fetch + ReadableStream) / `sse_parser.dart` (共有パーサ)。
   `web: ^1.0.0` を pubspec に追加。
2. **iOS Live Activities / Dynamic Island** — MethodChannel
   `dev.agentdesk/live_activities`、`LiveActivitiesService` (TaskRepository から
   pending 数+先頭タイトルを同期、0 で end)、`ios/Runner/LiveActivityManager.swift`、
   `ios/LiveActivityWidget/` (extension 一式 + SETUP.md — Xcode で手動ターゲット追加
   が必要。pbxproj は未編集)、`NSSupportsLiveActivities` in Info.plist。
3. **ネイティブプッシュ基盤 (APNs/FCM)** —
   `backend/src/nativepush.ts` (APNs ES256 JWT / FCM v1 RS256+OAuth 交換、
   シークレット未設定時は登録だけ保存して送信スキップ)、
   `POST/DELETE /api/v1/push/native`、`mobile/lib/services/native_push.dart`
   (MethodChannel `dev.agentdesk/push`)、`ios/Runner/NativePushManager.swift`
   (UNUserNotificationCenter→hex トークン)、設定画面に push 行、docs/push.md。
   Android FCM クライアントは google-services.json 依存のため意図的に未実装
   (docs/push.md に有効化手順)。秘密鍵待ちは解消不可のまま → gated。
4. **Executive Desk バックエンド (I-1002/I-1003/I-1001 の hub+protocol 側)** —
   protocol.ts: `RuleMatch.minConfidence`、`Rule.action` ("approve"|"reject")、
   `Rule.source` ("manual"|"learned")、`ActionReply.learnRule`、
   `validateSimulateRequest`、`validateAttachmentUpload` (2MiB 上限)。
   task-hub.ts: auto-reject ルール、`learnRuleFromSwipe`、履歴リングバッファ
   (~100 件、DO storage 永続)、`rulesSimulate`、native 登録/解除、
   attachment put/get、新規カード時の native push fan-out。
   index.ts: `POST /api/v1/rules/simulate`、`POST /api/v1/attachments`、
   `GET /api/v1/attachments/{id}` (client OR agent token)。
   テスト: `backend/src/hub-extensions.test.ts` 新規 21 件 (合計 92)。
   docs/protocol.md 更新済み。

## 進行中 (委託中のサブエージェント2件 — 完了通知を待つ)

- `ExecDeskMobile`: mobile 側 I-1001/I-1002/I-1003 —
  `guardrails_screen.dart` (simulate プレビュー付きルール編集)、
  deep-swipe に `learnRule: true`、AudioCapture/ImageCapture コンポーネント
  (record/image_picker/just_audio)、Android/iOS パーミッション、
  `uploadAttachment`/`simulateRules` in hub_api.dart、`guardrails_test.dart`。
  ※ task_repository.dart は LiveActivities 分 (`_syncLiveActivity`) を保持するよう
  指示済み。Info.plist の NSSupportsLiveActivities も保持。
- `ExecDeskWeb`: web/ 側 — `guardrails.js` (パネル + simulate バー)、
  二段スワイプに learnRule、AudioCapture (MediaRecorder) / ImageCapture
  (`<input capture>`) コンポーネント、attachments POST。

両者の報告は下記コントラクトに従う(親セッションが固定した API 契約):

```
RuleMatch.minConfidence? 0-1 / Rule.action "approve"|"reject" (default approve)
Rule.source? "manual"|"learned"
POST /api/v1/rules/simulate {match?,action?} → {sampleSize,autoApprove,autoReject,hitl}
POST /api/v1/actions {learnRule:true} → commit 時に Rule(source:"learned") 生成
POST /api/v1/attachments {kind:"audio"|"image",contentType,dataBase64} → {id,url}
GET  /api/v1/attachments/{id} → bytes (client OR agent token)
A2UI 新コンポーネント種: AudioCapture / ImageCapture →
  data に {componentId:{attachmentId,kind,contentType}}
POST/DELETE /api/v1/push/native {platform:"apns"|"fcm",token}
```

## 残りの仕事 (受け取り側でやること)

1. ExecDeskMobile / ExecDeskWeb の完了を待ち、統合ツリーで再検証:
   `flutter analyze` / `flutter test` / `flutter build web` /
   `backend npm run typecheck && npm test` / `flutter build apk --debug` /
   `flutter build linux --debug`。
2. 実機スモーク: `cd backend && npm run dev` (wrangler, 要 .dev.vars) +
   `node tools/mock-agent.mjs send` → web UI (http://127.0.0.1:8787) で
   カード表示・スワイプ・Guardrails パネルを目視確認。Flutter web 版も
   `flutter run -d chrome` で立ち上げて SSE が動くか確認
   (sse_client_web は実行時未検証 — 最初に試すべき箇所)。
3. TODO.md / IDEA.md のステータス確定 (下記「文書の整合」参照)。
4. コミット。protocol 変更あり → protocol.md / protocol.ts / task_card.dart が
   同一コミットに入っていることを確認 (ExecDeskMobile が task_card.dart を
   触ったか要 git status 確認)。
5. `mobile/web/index.html` 等は flutter create のデフォルト文言のまま
   (タイトル "agentdesk_mobile")。必要なら整える。
6. iOS: macOS ホストで Xcode に LiveActivityWidget ターゲット追加
   (ios/LiveActivityWidget/SETUP.md) + Push capability + aps-environment。
   APNs/FCM シークレットを wrangler secret put。

## 文書の整合 (TODO.md / IDEA.md の現状)

- TODO.md の Phase3 2項目は**チェックを付けていない**: Live Activities は
  「実装済み・Xcode 検証待ち」、ネイティブプッシュは「基盤実装済み・
  クレデンシャル待ち」。受け取り側で状態に合わせて [x] にするか判断。
- IDEA.md の I-1001/I-1003 は `accepted` のまま (クライアント側が完了したら
  `done` に)。I-1002 はユーザーが既に TODO で [x] と記載 (hub 側は本セッションで
  実装。モバイル Guardrails 画面は ExecDeskMobile 完了待ち)。
- docs/philosophy.md / TODO.md / IDEA.md の差分は親チェックアウトのユーザー
  編集を取り込んだもの。元の場所のファイルは手を付けていない (ユーザーのもの)。

## 既知リスク

- sse_client_web.dart: コンパイル検証のみ。チャンク境界のパースは未実行テスト。
- Swift 系 4 ファイルは未コンパイル (API は標準的だが初回は Xcode で修正が
  入りうる)。
- auto-reject ルールの enqueue 応答に `autoRejected:true` を追加
  (autoApproved:false)。既存クライアントは tolerant に読むはずだが
  mock-agent/SDK 側の表示確認は未実施。
- NativePush agent が settings_screen.dart に push 行を追加済み — ExecDeskMobile
  の同ファイル編集とマージ状態を確認すること。
