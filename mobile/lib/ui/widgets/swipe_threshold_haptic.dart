import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Fires `selectionClick` the moment the drag crosses the swipe threshold
/// (I-131) and again when it crosses the optional second-stage threshold
/// (I-101). `percentThreshold*` are 0-100+ values handed down by
/// CardSwiper; the click re-arms only after the card falls back below a
/// lower bound so a jittery finger cannot spam the click.
class SwipeThresholdHaptic extends StatefulWidget {
  final int percentThresholdX;
  final int percentThresholdY;

  /// Percent of the threshold at which the second stage begins; 0
  /// disables the second-stage detection.
  final int secondThreshold;

  /// Called when the second-stage state changes: `active` is true once
  /// the horizontal drag passes [secondThreshold] (and false when it
  /// falls back below 75% of it); `right` tells which way the card is
  /// being dragged.
  final void Function(bool active, bool right)? onSecondStage;

  final Widget child;

  const SwipeThresholdHaptic({
    super.key,
    required this.percentThresholdX,
    required this.percentThresholdY,
    required this.child,
    this.secondThreshold = 0,
    this.onSecondStage,
  });

  @override
  State<SwipeThresholdHaptic> createState() => _SwipeThresholdHapticState();
}

class _SwipeThresholdHapticState extends State<SwipeThresholdHaptic> {
  bool _armed = true;
  bool _secondActive = false;

  @override
  void didUpdateWidget(SwipeThresholdHaptic oldWidget) {
    super.didUpdateWidget(oldWidget);
    final percentX = widget.percentThresholdX;
    final percent = max(percentX.abs(), widget.percentThresholdY.abs());
    if (_armed && percent >= 100) {
      _armed = false;
      HapticFeedback.selectionClick();
    } else if (!_armed && percent < 40) {
      _armed = true;
    }

    final second = widget.secondThreshold;
    if (second > 0) {
      final magnitude = percentX.abs();
      if (!_secondActive && magnitude >= second) {
        _secondActive = true;
        HapticFeedback.selectionClick();
        widget.onSecondStage?.call(true, percentX > 0);
      } else if (_secondActive && magnitude < second * 0.75) {
        _secondActive = false;
        widget.onSecondStage?.call(false, percentX > 0);
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
