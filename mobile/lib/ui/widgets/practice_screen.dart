import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_card_swiper/flutter_card_swiper.dart';

import '../../models/task_card.dart';
import '../colors.dart';
import 'hold_confirm.dart';
import 'reject_reason_sheet.dart';
import 'swipe_threshold_haptic.dart';
import 'task_card_view.dart';

/// Practice mode (I-129): a fake five-card stack that teaches the swipe
/// vocabulary without ever touching the hub. Cards are local-only — no
/// repository, no API calls. Reachable on first run and from Settings.
class PracticeScreen extends StatefulWidget {
  const PracticeScreen({super.key});

  static Route<void> route() =>
      MaterialPageRoute<void>(builder: (_) => const PracticeScreen());

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends State<PracticeScreen> {
  final CardSwiperController _controller = CardSwiperController();
  final List<TaskCard> _cards = practiceCards();

  int _index = 0;
  bool _done = false;
  String? _secondStage;

  static const List<String> _hints = [
    '① 右にスワイプ → 承認。短く払うだけでOK',
    '② 左にスワイプ → 却下。理由チップを選べます',
    '③ さらに右へ長く引く → 「承認+自動化を提案」(二段スワイプ)',
    '④ 赤いカードは誤操作防止。リングを長押しして承認',
    '⑤ 下にスワイプ → 「あとで」。タップで詳細を開く',
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _locked {
    if (_index < 0 || _index >= _cards.length) return false;
    return riskLevel(_cards[_index]) == RiskLevel.locked;
  }

  void _advance(int? currentIndex) {
    setState(() {
      _index = currentIndex ?? _cards.length;
      if (_index >= _cards.length) _done = true;
    });
  }

  FutureOr<bool> _onSwipe(
    int previousIndex,
    int? currentIndex,
    CardSwiperDirection direction,
  ) {
    if (previousIndex < 0 || previousIndex >= _cards.length) return false;
    final card = _cards[previousIndex];
    if (direction == CardSwiperDirection.right &&
        riskLevel(card) == RiskLevel.locked) {
      return false;
    }
    if (direction == CardSwiperDirection.left && card.rejectReasons.isNotEmpty) {
      showRejectReasonSheet(context, card.rejectReasons);
    }
    if (_secondStage != null) {
      _showHintSnack(_secondStage == 'right'
          ? '二段スワイプ: 承認+自動化を提案します'
          : '二段スワイプ: 却下+同種をミュートします');
    }
    _secondStage = null;
    _advance(currentIndex);
    return true;
  }

  void _showHintSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _confirmLocked() {
    HapticFeedback.mediumImpact();
    if (_index + 1 >= _cards.length) {
      setState(() => _done = true);
      return;
    }
    _controller.moveTo(_index + 1);
    setState(() => _index = _index + 1);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('練習モード',
            style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('スキップ'),
          ),
        ],
      ),
      body: _done
          ? _DoneView(onClose: () => Navigator.of(context).pop())
          : _buildPractice(),
    );
  }

  Widget _buildPractice() {
    final cardWidth = MediaQuery.of(context).size.width - 40;
    final secondStage = ((0.85 * cardWidth) / 50 * 100).ceil();
    final hintIndex = _index.clamp(0, _hints.length - 1).toInt();
    final hint = _hints[hintIndex];

    return Column(
      children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: PopColors.surface2,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            hint,
            style: const TextStyle(fontSize: 13, color: PopColors.text2),
          ),
        ),
        Expanded(
          child: CardSwiper(
            controller: _controller,
            cardsCount: _cards.length,
            isLoop: false,
            numberOfCardsDisplayed: _cards.length >= 3 ? 3 : _cards.length,
            threshold: 50,
            allowedSwipeDirection: AllowedSwipeDirection.only(
              right: !_locked,
              left: true,
              up: false,
              down: true,
            ),
            backCardOffset: const Offset(0, -24),
            onSwipe: _onSwipe,
            cardBuilder: (context, index, percentX, percentY) {
              return SwipeThresholdHaptic(
                percentThresholdX: percentX,
                percentThresholdY: percentY,
                secondThreshold: secondStage,
                onSecondStage: (active, right) =>
                    _secondStage = active ? (right ? 'right' : 'left') : null,
                child: TaskCardView(
                  task: _cards[index],
                  timeAgo: _practiceTimeAgo,
                  swipePercentX: percentX,
                  swipePercentY: percentY,
                  secondStageThreshold: secondStage,
                  onQuickAction: (binding) =>
                      _showHintSnack('練習カードでは実行しません'),
                  onInspect: () => _showHintSnack('本番ではタップで詳細を開きます'),
                ),
              );
            },
          ),
        ),
        if (_locked)
          Padding(
            padding: const EdgeInsets.only(bottom: 24, top: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                HoldConfirmButton(
                  label: '削除する',
                  onConfirmed: _confirmLocked,
                ),
                const Text('長押しで承認',
                    style: TextStyle(fontSize: 10, color: Colors.white38)),
              ],
            ),
          )
        else
          const SizedBox(height: 24),
      ],
    );
  }
}

class _DoneView extends StatelessWidget {
  final VoidCallback onClose;

  const _DoneView({required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.celebration_outlined,
              size: 56, color: PopColors.green),
          const SizedBox(height: 16),
          const Text('練習完了',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text('実際のカードで同じ操作が使えます',
              style: TextStyle(fontSize: 13, color: PopColors.text2)),
          const SizedBox(height: 20),
          FilledButton(onPressed: onClose, child: const Text('はじめる')),
        ],
      ),
    );
  }
}

String _practiceTimeAgo(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inSeconds < 60) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  return '${diff.inDays}d';
}

/// The five fake cards (I-129). They exercise: plain right swipe,
/// reject-reason chips, the two-stage hint, hold-confirm on a locked
/// card, and down-swipe snooze.
List<TaskCard> practiceCards() {
  final now = DateTime.now();
  TaskCard card({
    required String id,
    required String agent,
    required String summary,
    required String severity,
    String? rightLabel,
    String? leftLabel,
    List<RejectReason> rejectReasons = const <RejectReason>[],
    CardImpact? impact,
    List<CardComponent> components = const <CardComponent>[],
    TaskContext? context,
  }) {
    return TaskCard(
      taskId: id,
      nonce: 'practice_nonce',
      agent: AgentInfo(name: agent),
      confidence: 0.9,
      confidenceReasons: const <String>[],
      severity: severity,
      summary: summary,
      surfaceId: null,
      createdAt: now,
      replyUrl: null,
      components: components,
      onSwipeRight: rightLabel == null
          ? null
          : ActionBinding(actionName: 'practice_approve', label: rightLabel),
      onSwipeLeft: leftLabel == null
          ? null
          : ActionBinding(actionName: 'practice_reject', label: leftLabel),
      inspectForm: const <CardComponent>[],
      impact: impact,
      rejectReasons: rejectReasons,
      context: context,
    );
  }

  return <TaskCard>[
    card(
      id: 'practice_1',
      agent: 'Calendar Bot',
      summary: '定例レビューの招待を再送しますか？',
      severity: 'info',
      rightLabel: '再送する',
      leftLabel: '却下',
      components: const <CardComponent>[
        CardComponent(
          id: 'p1_caption',
          component: 'Text',
          properties: <String, dynamic>{
            'text': '参加予定: 佐藤さん、田中さん',
            'variant': 'caption',
          },
        ),
      ],
    ),
    card(
      id: 'practice_2',
      agent: 'Inbox Agent',
      summary: 'このメールを迷惑メールとして処理しますか？',
      severity: 'warning',
      rightLabel: '迷惑メールへ',
      leftLabel: '却下',
      rejectReasons: const <RejectReason>[
        RejectReason(id: 'wrong_sender', label: '送信者が違う'),
        RejectReason(id: 'not_spam', label: '迷惑メールではない'),
      ],
    ),
    card(
      id: 'practice_3',
      agent: 'Draft Agent',
      summary: 'この返信を送信しますか？',
      severity: 'info',
      rightLabel: '送信する',
      leftLabel: '却下',
    ),
    card(
      id: 'practice_4',
      agent: 'Ops Agent',
      summary: '本番データベースを削除します',
      severity: 'critical',
      rightLabel: '削除する',
      impact: const CardImpact(reversible: false, summary: '元に戻せません'),
    ),
    card(
      id: 'practice_5',
      agent: 'Billing Agent',
      summary: '見積もりのレビューをお願いします',
      severity: 'info',
      rightLabel: '承認',
      leftLabel: '却下',
      context: const TaskContext(
        requesterName: '鈴木さん',
        participants: <ContextPerson>[
          ContextPerson(name: '佐藤さん', status: 'free'),
          ContextPerson(name: '田中さん', status: 'busy'),
        ],
        reasoning: '金額が想定より 12% 低く、即時承認の候補です。',
        sourceLabel: '見積もりメール #4821',
      ),
    ),
  ];
}
