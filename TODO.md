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

- [x] **Undo猶予** (I-104)
  - [ ] hub: `StoredTask.status` に `committing` を追加。accept 時は `committing` +
        `commitAt = now + UNDO_GRACE_MS`(既定 5s)、DO alarm で `processed` に確定して
        replyUrl へ転送。`dismissTask` は `committing` 時点で配信(他端末からは即消える)
  - [ ] hub: `POST /api/v1/actions/undo {taskId, nonce}` → `committing` なら `pending` に戻し、
        nonce を作り直して `createTaskCard` を再配信。`processed` 後は `409 too_late`
  - [ ] alarm を「期限切れ掃除」と「commit 確定」の両方に使うため、次回 alarm 時刻の計算を一本化
  - [ ] mobile/web: 処理済みトースト(後で I-120 のトレイに置き換え)に「元に戻す」
  - [ ] vitest: committing→undo / committing→processed / processed→undo=409 / 二重 undo
  - [ ] protocol.md: 状態遷移図と新エンドポイント
- [x] **承認すると行・可逆性** (I-202, I-130)
  - [ ] protocol: `impact: {summary?, reversible?, cost?: {amount, currency}, scope?}` と
        `actions.onSwipeRight.label` / `onSwipeLeft.label`
  - [ ] mobile: カード上部に「承認すると…」と可逆性バッジ。スワイプ中のオーバーレイ文言を
        `label` に(未指定なら従来の APPROVE / REJECT)
  - [ ] web: 同上
  - [ ] mock-agent: サンプル3枚に `impact` と `label` を付ける
- [ ] **リスク連動の重さ** (I-102, I-103)
  - [ ] クライアント共通の `riskLevel(task)` を定義(critical / reversible=false / cost を入力)
  - [ ] mobile: 高リスクの先頭カードではスワイプ閾値を伸ばす。flutter_card_swiper の
        `threshold` が先頭カードごとに変えられるか要調査(不可なら swiper を自前ジェスチャーで包む)
  - [ ] mobile/web: critical+取り消し不可は右スワイプ無効、長押しリングで承認
- [ ] **下部アクションバー** (I-134)
  - [ ] mobile: ✕ / 後で / ✓ を常設(`CardSwiperController.swipe()` を呼ぶだけで動きを揃える)
  - [ ] 高リスク時は ✓ が長押しリングに変わる
- [ ] **触覚の文法** (I-131)
  - [ ] 閾値を越えた瞬間に `selectionClick`、確定で `mediumImpact`、critical 確定で `heavyImpact`、
        409 で二回短く。今は確定時の `mediumImpact` のみ

## Next — 捌く量を減らす(P8)と、エージェントへの返事の質

- [ ] **却下理由チップ** (I-118) — `actions.rejectReasons?: [{id,label}]`、返却 `data.reason`
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
