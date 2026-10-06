import 'dart:math' as math;

import '../models/task_card.dart';

/// 山札の並び順モード（I-123 / I-206）。
///
/// * `urgent`（既定）— 緊急度スコア降順、同点は createdAt 降順、
///   さらに taskId 昇順で完全に決定。
/// * `newest` — createdAt 降順、taskId 昇順。
/// * `agent` — agent.name で昇順にグループ化、グループ内は緊急度スコア
///   降順 → createdAt 降順 → taskId 昇順。
enum StackOrder { urgent, newest, agent }

const int _msPerDay = 86400000;

/// 緊急度スコア（0..~100、大きいほど緊急）。山札の並び順の主キー。
/// 各要素は期限・重大度・影響額・信頼度・経過時間の合計:
///   deadline    = expiresAt あり → 40 * (1 - clamp((exp - now)/24h, 0, 1))
///                 （期限が近いほど大きい。24h以上先→0、期限切れ/到達→40）
///   severity    = critical→25 / warning→15 / info・なし→0
///   cost        = impact.cost.amount > 0 → 15 * min(log10(amount+1)/5, 1)
///   confidence  = 0..1 の数値 → 10 * (1 - confidence)（信頼度が低いほど大きい）
///   wait        = createdAt あり → 15 * clamp((now - created)/24h, 0, 1)
///                 （24hで飽和）
/// 欠損・不正なフィールドは 0 扱いで、例外を投げない。
double priorityScore(TaskCard task, DateTime now) {
  final nowMs = now.millisecondsSinceEpoch;

  // deadline: 期限が近いほど大きい
  final expires = task.expiresAt;
  final double deadline;
  if (expires != null) {
    final frac = (expires.millisecondsSinceEpoch - nowMs) / _msPerDay;
    deadline = 40 * (1 - _clamp01(frac));
  } else {
    deadline = 0;
  }

  // severity
  final double severity;
  switch (task.severity) {
    case 'critical':
      severity = 25;
    case 'warning':
      severity = 15;
    default:
      severity = 0;
  }

  // cost: 影響額（USD）が大きいほど大きい。~$99,999 で飽和
  final amount = task.impact?.costAmount;
  final double cost;
  if (amount != null && amount > 0) {
    final log10 = math.log(amount + 1) / math.ln10;
    cost = 15 * math.min(log10 / 5, 1);
  } else {
    cost = 0;
  }

  // confidence: 信頼度が低いほど大きい
  final double confidenceTerm;
  if (task.confidence >= 0 && task.confidence <= 1) {
    confidenceTerm = 10 * (1 - task.confidence);
  } else {
    confidenceTerm = 0;
  }

  // wait: 作成から24hで飽和
  final created = task.createdAt;
  final frac = (nowMs - created.millisecondsSinceEpoch) / _msPerDay;
  final wait = 15 * _clamp01(frac);

  return deadline + severity + cost + confidenceTerm + wait;
}

double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

/// [mode] に従って 2 枚を比較。`a` が山札の上（前）なら負を返す。
int compareTasks(TaskCard a, TaskCard b, StackOrder mode, DateTime now) {
  switch (mode) {
    case StackOrder.urgent:
      final byScore = priorityScore(b, now).compareTo(priorityScore(a, now));
      if (byScore != 0) return byScore;
      final byCreated = b.createdAt.compareTo(a.createdAt);
      if (byCreated != 0) return byCreated;
      return a.taskId.compareTo(b.taskId);
    case StackOrder.newest:
      final byCreated = b.createdAt.compareTo(a.createdAt);
      if (byCreated != 0) return byCreated;
      return a.taskId.compareTo(b.taskId);
    case StackOrder.agent:
      final byAgent =
          a.agent.name.toLowerCase().compareTo(b.agent.name.toLowerCase());
      if (byAgent != 0) return byAgent;
      final byScore = priorityScore(b, now).compareTo(priorityScore(a, now));
      if (byScore != 0) return byScore;
      final byCreated = b.createdAt.compareTo(a.createdAt);
      if (byCreated != 0) return byCreated;
      return a.taskId.compareTo(b.taskId);
  }
}

/// [tasks] の新しい並び替え済みコピーを返す（先頭が山札の最上段）。
List<TaskCard> sortTasks(List<TaskCard> tasks, StackOrder mode, DateTime now) {
  final sorted = List<TaskCard>.of(tasks);
  sorted.sort((a, b) => compareTasks(a, b, mode, now));
  return sorted;
}