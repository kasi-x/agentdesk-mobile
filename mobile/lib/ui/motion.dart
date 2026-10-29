import 'package:flutter/widgets.dart';

/// Central reduced-motion check (I-1004 / design-system.md §5).
///
/// Returns true when the OS asks for reduced motion (iOS "Reduce
/// Motion", Android "Remove animations" surfaces via
/// `MediaQuery.disableAnimations`). Callers collapse decorative motion —
/// fades/slides/rotations drop to ~0ms — but keep state and progress
/// readable (a hold-to-confirm ring still fills; the fill IS the
/// meaning, so it never gets skipped, only made instant at completion).
bool reduceMotion(BuildContext context) =>
    MediaQuery.of(context).disableAnimations;

/// Duration helper: decorative `d`, or ~instant when reduced motion.
Duration animDuration(BuildContext context, Duration d) =>
    reduceMotion(context) ? Duration.zero : d;
