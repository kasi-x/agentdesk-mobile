# TODO.md — 実行計画

[IDEA.md](IDEA.md) で採用したものをタスクにして並べる。各項目の `(I-xxx)` は
アイデアID、`P#` は [docs/philosophy.md](docs/philosophy.md) の原則番号。

## 運用ルール

- 上から順にやる。順番を変えるときは理由を一行添える。
- `protocol` に触れるタスクは protocol.md / `backend/src/protocol.ts` /
  `mobile/lib/models/task_card.dart` を同じコミットで更新する(AGENTS.md)。
- 完了したら `[x]` にして「Done」へ移し、IDEA.md 側の状態を `done` にする。
- 新しく思いついたことは、まず IDEA.md へ。ここには直接書かない。

---

## Now — 安全に速く払える土台(P2・P5)

誤操作に強くするのが最優先。スワイプUIの最大の弱点を先に潰す。


## Next — 捌く量を減らす(P8)と、エージェントへの返事の質

- [ ] **期限** (I-203) — `expiresAt` / `onExpire`、カウントダウン表示、hub の alarm で既定動作
- [ ] **並び順を緊急順に** (I-123, I-206) — 今は新しい順固定
- [ ] **サーバー側スヌーズ** (既知の逸脱) — `POST /api/v1/actions` に `snooze` アクションと `until`、
      全端末で同期、DO alarm で再浮上
- [ ] **カードの更新と取り下げ** (I-204, I-205) — `updateTaskCard` / `withdrawTask`、nonce の作り直し
- [ ] **replyUrl の信頼性** (I-604, I-801) — 再試行(指数バックオフ、最大N回)、HMAC 署名ヘッダ、
      最終失敗をカード履歴に表示。今は `deliverToAgent` が失敗をログに出すだけ
- [ ] **まとめカード** (I-201, I-110) — `groupKey`、例外の自動切り出し、一括承認
- [ ] **二段スワイプ** (I-101) — まず「承認+自動化を提案」までに留め、ルール保存は Later の I-807 と同時に
- [ ] **Web キーボード拡充** (I-136) — 既存 ←/→/i/s に j/k/z/1-9/? を追加
- [ ] **練習モード** (I-129) — 新しい操作を増やす前に入れておく

## Later — 広げる

- [ ] 処理済みトレイ (I-120) と履歴・監査ログ (I-512)
- [ ] Fleet タブ (I-603, I-122)
- [ ] ピンチで俯瞰 / カードを裏返す / ドロップゾーン (I-105, I-107, I-108)
- [ ] 二択カード・行単位の選択・カード上の値調整 (I-111, I-112, I-114)
- [ ] 自動承認ルールと権限リース (I-304, I-807, I-602)
- [ ] ラバースタンプ検知 (I-401) と おやすみ時間 (I-402)
- [ ] 緊急停止 (I-403)
- [ ] SDK と MCP サーバー (I-901, I-902)
- [ ] QR ペアリング・端末ごとのトークン・ユーザーごとの DO (I-808, I-809)
- [ ] PWA + Web Push (I-701)
- [ ] 委任・二人承認 (I-501, I-502)

## Phase 3(既存ロードマップ)

- [ ] iOS Live Activities / Dynamic Island(WidgetKit via MethodChannel、macOS/Xcode 環境待ち)
- [ ] APNs / FCM プッシュ
- [ ] マルチデバイス同期の磨き込み

## 雑務・技術的負債

- [ ] mobile: `flutter create` 後のプラットフォームフォルダをコミットするか方針を決める
- [ ] mobile: `withOpacity` の非推奨警告(Flutter 3.27+ は `withValues`)
- [ ] web/app.js(約700行)をモジュール分割するか検討(ゼロビルドは維持)
- [ ] ペイロードのファジングテスト (I-909)
- [ ] プロトコルのバージョン番号 (I-606) — Now の変更で v0 を逸脱し始めるので早めに

## Done

- [x] Phase 1 MVP: カードスタック、webhook → DO → SSE、楽観的UI、オフラインキュー、
      nonce + 楽観ロック、他端末への dismiss 配信、エージェントへの返送
- [x] Phase 2: genui インスペクトフォーム、DiffBox の `rows` / `inline`、Web トリアージUI、
      同一オリジン POST の修正
- [x] docs/philosophy.md / IDEA.md / TODO.md を作成 (I-404)
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
