# TODO.md — 実行計画

[IDEA.md](IDEA.md) で採用したものをタスクにして並べる。各項目の `(I-xxx)` は
アイデアID、`P#` は [docs/philosophy.md](docs/philosophy.md) の原則番号。

> **作業中メモ**: 本ブランチの進捗・環境再現手順・委託中タスクの契約は
> [HANDOFF.md](HANDOFF.md) に集約。引き継ぎはそこから読む。

## 運用ルール

- 上から順にやる。順番を変えるときは理由を一行添える。
- `protocol` に触れるタスクは protocol.md / `backend/src/protocol.ts` /
  `mobile/lib/models/task_card.dart` を同じコミットで更新する(AGENTS.md)。
- 完了したら `[x]` にして「Done」へ移し、IDEA.md 側の状態を `done` にする。
- 新しく思いついたことは、まず IDEA.md へ。ここには直接書かない。

---

## Now — 安全に速く払える土台(P2・P5)

誤操作に強くするのが最優先。スワイプUIの最大の弱点を先に潰す。
- [ ] **デザインシステムをWeb／Flutterへ反映 (I-1004)**: セマンティック色・文字・余白・カード階層を揃え、仕様値をCSSとFlutterテーマに反映する。通常／高リスク／同期状態の意味を両クライアントで統一。
- [ ] **動きと高度な操作を段階的に整える (I-1004)**: カード遷移、詳細展開、スワイプ／長押しの応答を仕様に合わせ、追加機能は隠しジェスチャーに頼らず発見可能にする。
- [ ] **操作可能性と仕上がりを検証 (I-1004)**: タッチ・キーボード・読み上げ、文字拡大、動きの軽減を確認し、モバイル／Web双方で色・状態・操作結果の一貫性を検証する。
- [ ] **判断から安全なルール育成 (I-1003, I-1005)**: 承認・却下直後に「今回だけ／同種を自動許可／金額・範囲・期間つき」を選択。適用範囲・期限・影響プレビュー・取り消しを必須化。戦略は [docs/strategy.md](docs/strategy.md)。
- [ ] **5分で最初の実タスク接続 (I-1006, I-903)**: 主要エージェント向け完成済み導線を用意し、初回接続から実タスク承認→動作再開までを5分以内に体験可能にする。
- [ ] **身元確認と実行前プレビュー (I-804, I-208)**: 登録済みエージェントの身元確認、実行対象・権限範囲の検証、送信内容のドライランプレビューを高価値操作の前提にする。


## Next — 「The Executive Desk」動的ガードレールとネゴシエーションの基盤

- [x] **ガードレールの視覚的プレビュー (I-1002)**: `protocol` (Rules API 拡張, 推定トラフィック割合の計算), `client` (スライダー/トグルによる閾値調整UI, ファネルアニメーション)
- [ ] **スワイプによるルール生成 (I-1003)**: `hub` (アクションからのRule学習ロジック), `client` (上段スワイプ時のアクション追加「Approve & Auto-allow」)
- [ ] **高帯域コンテキスト(音声/画像)のフィードバック (I-1001)**: `protocol` (A2UIフォーム拡張: `audio`, `image`), `client` (マイク・カメラネイティブ呼び出し, プレビューと送信)

## Next — 捌く量を減らす(P8)と、エージェントへの返事の質

(全項目完了 — 詳細は Done へ移動)

## Later — 広げる

(全項目完了 — 詳細は Done へ移動)

## Phase 3(既存ロードマップ)

- [ ] iOS Live Activities / Dynamic Island(実装済み: MethodChannel `dev.agentdesk/live_activities` + `ios/Runner/LiveActivityManager.swift` + `ios/LiveActivityWidget/` extension (SETUP.md)。Xcode ターゲット追加と実機検証は macOS ホスト待ち)
- [ ] APNs / FCM ネイティブプッシュ(基盤実装済み: `POST/DELETE /api/v1/push/native` + APNs ES256 / FCM v1 送信 (シークレット未設定時は登録のみ保存) + iOS `NativePushManager.swift` + 設定画面 + docs/push.md。Android FCM クライアントは google-services.json 待ち。Apple/Firebase クレデンシャル待ち)
- [x] マルチデバイス同期の磨き込み (snapshot reconcile、own-echo デデュープ、revised カード更新アニメーション)

## 雑務・技術的負債

- [x] mobile: `flutter create` 後のプラットフォームフォルダをコミットするか方針を決める (コミット方針決定: ios/android を追跡し、IDE 設定ファイルのみ除外)
- [x] mobile: `withOpacity` の非推奨警告 (Flutter 3.27+ `withValues` 移行完了)
- [x] web/app.js をモジュール分割 (1219行を 13本のネイティブ ES モジュールに分割、ゼロビルド維持)
- [x] ペイロードのファジングテスト (I-909: vitest 18件 + flutter 5件)
- [x] プロトコルのバージョン番号 (I-606: protocolVersion: 1 をカードおよび snapshot エンベロープに導入)

## Done

- [x] **並び順を緊急順に** (I-123, I-206): `priority` スコア（severity + 期限近接 + confidence + 経過時間）算出と優先度降順ソート（ハブ算出 — 初期スナップショットの並び順に使用）
- [x] **優先度スコアのクライアント側算出** (I-123, I-206): 緊急順(既定)/新しい順/エージェント順の
      切替。優先度スコアはクライアント側で算出(プロトコル変更なし):
      期限40・severity25・金額15(log10)・信頼度の逆数10・待ち時間15。
      JS (`web/priority.js`) と Dart (`mobile/lib/services/priority.dart`) で同一式。
      web はトップバーのサイクルボタン + localStorage 永続化、mobile は AppBar の
      PopupMenuButton + SharedPreferences 永続化。スヌーズ済みは全モードで末尾固定、
      escalate 再配信でスコア再計算して再整列。node:test 7件 + flutter_test 11件追加。
- [x] **サーバー側スヌーズ**: `POST /api/v1/actions` の `snooze` アクション、全端末 dismiss 同期、DO alarm での自動再浮上
- [x] **カードの更新と取り下げ** (I-204, I-205): `POST /api/v1/tasks/{id}/update` (nonce 再発行 + revised:true) / `withdraw` (全端末 dismiss)
- [x] **replyUrl の信頼性** (I-604, I-801): 指数バックオフ再試行 (最大5回) + HMAC-SHA256 署名ヘッダ、最終失敗を `deliveryFailed` SSE + `/state` に記録
- [x] **まとめカード** (I-201, I-110): `groupKey` passthrough、`POST /api/v1/actions/bulk` 一括承認、例外の自動個別化、二本指スワイプ
- [x] **二段スワイプ** (I-101): 奥まで引いて「承認+自動化を提案」「却下+ミュート」、触覚 selectionClick
- [x] **Web キーボード拡充** (I-136): `j`/`k` 移動、`z` Undo、`1`〜`9` チップ選択、`?` ショートカット一覧、`Shift+→` 二段承認
- [x] **練習モード** (I-129): オンボーディング用 5枚のダミーカード、設定画面から再演可能
- [x] **処理済みトレイと履歴・監査ログ** (I-120, I-512): 下部帯、日別グループ化された履歴パネル、localStorage / SharedPreferences 永続化
- [x] **Fleet タブ** (I-603, I-122): エージェント別の待ち件数レーン表示とスタックのフィルタリング
- [x] **ピンチで俯瞰 / カードを裏返す / ドロップゾーン** (I-105, I-107, I-108): ピンチイン一覧タイル、ダブルタップで裏面コンテキスト表示、長押し四隅ドロップゾーン
- [x] **二択カード・行単位の選択・カード上の値調整** (I-111, I-112, I-114): 上下スワイプの選択カード、DiffBox の行選択チェック、stepper / slider インライン値調整
- [x] **自動承認ルールと権限リース** (I-304, I-807, I-602): `GET/PUT /api/v1/rules`、match / lease 条件判定、新規カードの enqueue 自動承認
- [x] **ラバースタンプ検知とおやすみ時間** (I-401, I-402): 1秒未満の連続承認ロック、夜間の非クリティカルカード退避
- [x] **緊急停止** (I-403): `POST /api/v1/pause` / `resume`、全端末赤バナー + 承認ロック
- [x] **SDK と MCP サーバー** (I-901, I-902): TypeScript SDK, Python SDK, Stdio MCP サーバー, docs/sdk.md
- [x] **QR ペアリング・端末ごとのトークン・ユーザーごとの DO** (I-808, I-809): `POST /api/v1/pair` / `redeem`、device:<sha256> トークン、user:<u> DO ルーティング
- [x] **PWA + Web Push** (I-701): `manifest.webmanifest`, `sw.js`, WebCrypto RFC 8291 aes128gcm + VAPID 送信
- [x] **委任・二人承認** (I-501, I-502): `action: "delegate"`、`requiredApprovals: 2` (1人目で nonce ローテ + progress、2人目で commit)

- [x] **期限** (I-203): protocol に `expiresAt` / `onExpire`(approve/reject/escalate/drop、
      既定 drop、malformed は 400)。hub の統合 alarm に期限を追加 — approve/reject は
      宣言済みスワイプバインディングを undo 猶予なしで即実行、drop は replyUrl へ
      `expire/EXPIRED` を返信、escalate は nonce ローテ+severity critical で再配信
      (クライアントは createTaskCard を同一 taskId なら差し替え)。
      自動実行は `source: "on_expire"` / `dismissTask.by: "on_expire"` で記録。
      mobile/web にカウントダウンストリップ(緊急度配色)、mock-agent サンプルと
      smoke に期限ケース追加。
      (順番変更: 雑務の withValues 移行を同梱 — Flutter 3.47 をローカル導入したため
      `flutter analyze` を完全緑にしてから以降の作業を行う)

- [x] Phase 1 MVP: カードスタック、webhook → DO → SSE、楽観的UI、オフラインキュー、
      nonce + 楽観ロック、他端末への dismiss 配信、エージェントへの返送
- [x] Phase 2: genui インスペクトフォーム、DiffBox の `rows` / `inline`、Web トリアージUI、
      同一オリジン POST の修正
- [x] docs/philosophy.md / docs/design-philosophy.md / IDEA.md / TODO.md を作成・体系化 (I-404)
- [x] **フロントエンド洗練の設計原則** (docs/design-philosophy.md): 余計な情報を出さない（信頼度・二重表示の完全排除）、必要な情報を端的に出す（Impact First）、拡張ビューの一本化（詳細を見る）、ドメイン最適グラフィック（カレンダー・タイムライン、DiffBox、Quote Block）の4本柱を言語化
- [x] **Undo猶予** (I-104): `committing` 状態 + `commitAt`、alarm 一本化、
      `POST /api/v1/actions/undo` (nonce ローテ + 再配信、processed 後は `409 too_late`)、
      mobile/web の「元に戻す」トースト、vitest + smoke 追加
- [x] **承認すると行・可逆性** (I-202, I-130): `impact {summary?, reversible?, cost?, scope?}` +
      `actions.*.label`。mobile はカード上部バッジ + スワイプオーバーレイ文言、
      web は同バッジ + ボタン文言、mock-agent 3 枚に付与
- [x] **リスク連動の重さ** (I-102, I-103): 共通 `riskLevel` (normal/high/locked) を
      task_card.dart と web/app.js に。high = threshold 90、locked (critical + 取り消し不可) =
      右スワイプ無効 + 長押しリング承認 (mobile `HoldConfirmButton`, web pointer-hold
      progress, `source: "hold_confirm"`)。flutter_card_swiper は `didUpdateWidget` が
      `widget.*` を再読するためビルド時差し替えで十分
- [x] **下部アクションバー** (I-134): ✕/あとで/✓ をカード下に常設、
      `CardSwiperController.swipe()` でジェスチャーと同じアニメーション。
      locked 時は ✓ スロットが `HoldConfirmButton` に変わる
- [x] **触覚の文法** (I-131): 閾値到達で `selectionClick` (`_ThresholdHaptic`,
      40% 未満でリアーム)、確定 `mediumImpact` / critical `heavyImpact`、
      409 で `onConflict` → 二連 `selectionClick`
- [x] **却下理由チップ** (I-118): hub が `actions.rejectReasons` を検証・中継
      (malformed 捨て、非配列は 400)。mobile は左スワイプ後に `_RejectReasonSheet`
      (4s 自動確定)、web はインラインチップ + 4s タイムアウト。選択 id は
      `data.reason` でエージェントに届く (E2E 確認済み: `"reason": "wrong_amount"`)
