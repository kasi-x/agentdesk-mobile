import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/task_card.dart';

/// Presents the reject-reason chip row (I-118) and completes with the
/// chosen reason id, or null when ignored / timed out.
Future<String?> showRejectReasonSheet(
  BuildContext context,
  List<RejectReason> reasons,
) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (context) => RejectReasonSheet(reasons: reasons),
  );
}

/// Chip row of agent-supplied reject reasons (I-118). Tapping a chip
/// completes with its id; dismissing or the 4s timer completes with null
/// (reject without a reason).
class RejectReasonSheet extends StatefulWidget {
  final List<RejectReason> reasons;

  const RejectReasonSheet({super.key, required this.reasons});

  @override
  State<RejectReasonSheet> createState() => _RejectReasonSheetState();
}

class _RejectReasonSheetState extends State<RejectReasonSheet> {
  bool _done = false;

  @override
  void initState() {
    super.initState();
    Timer(const Duration(seconds: 4), () {
      if (!_done && mounted) Navigator.of(context).pop();
    });
  }

  void _pick(String? id) {
    if (_done) return;
    _done = true;
    Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '却下の理由 (任意)',
              style: TextStyle(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final reason in widget.reasons)
                  ActionChip(
                    label: Text(reason.label),
                    onPressed: () => _pick(reason.id),
                  ),
                ActionChip(
                  label: const Text('理由なしで却下'),
                  onPressed: () => _pick(null),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
