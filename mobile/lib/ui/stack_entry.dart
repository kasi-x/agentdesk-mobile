import '../models/task_card.dart';

/// One position in the rendered stack: either a single card or a group
/// bundle (I-201). Cards sharing a `groupKey` collapse into one bundle;
/// members with `severity == critical` or `confidence < 0.5` are always
/// auto-split and render as their own cards (exceptions).
class StackEntry {
  final TaskCard? single;
  final List<TaskCard>? bundle;

  const StackEntry.single(TaskCard task)
      : single = task,
        bundle = null;

  const StackEntry.bundle(List<TaskCard> tasks)
      : single = null,
        bundle = tasks;

  bool get isBundle => bundle != null && bundle!.length >= 2;

  /// Stable identity for CardSwiper / animation keys.
  String get key => isBundle ? 'bundle:$groupKey' : single!.taskId;

  String? get groupKey =>
      isBundle ? (bundle!.first.groupKey) : single!.groupKey;

  /// Cards that render individually (the visible stack for this entry).
  List<TaskCard> get members => isBundle ? bundle! : <TaskCard>[single!];

  /// A card must never be bundled with others when it is critical or the
  /// hub is unsure about it (I-201 exceptions).
  static bool isException(TaskCard task) =>
      task.severity == 'critical' || task.confidence < 0.5;

  /// Builds the display stack from the repository's visible cards,
  /// preserving server order (priority desc / createdAt asc). A group
  /// bundle is emitted at the position of its first member; groups that
  /// collapse to a single non-exception card stay single.
  static List<StackEntry> build(List<TaskCard> tasks, {Set<String> ungrouped = const <String>{}}) {
    final grouped = <String, List<TaskCard>>{};
    for (final task in tasks) {
      final key = task.groupKey;
      if (key == null ||
          ungrouped.contains(task.taskId) ||
          isException(task)) {
        continue;
      }
      grouped.putIfAbsent(key, () => <TaskCard>[]).add(task);
    }

    final emitted = <String>{};
    final entries = <StackEntry>[];
    for (final task in tasks) {
      final key = task.groupKey;
      final members = key == null ||
              isException(task) ||
              ungrouped.contains(task.taskId)
          ? null
          : grouped[key];
      if (members != null && members.length >= 2) {
        if (emitted.add(task.groupKey!)) entries.add(StackEntry.bundle(members));
        continue;
      }
      entries.add(StackEntry.single(task));
    }
    return entries;
  }
}
