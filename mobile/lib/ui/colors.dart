import 'package:flutter/material.dart';

/// Calm-iOS design tokens — mirror of `web/style.css :root`.
///
/// Apple-style minimal card: a neutral elevated surface, iOS system
/// grays, color reserved for meaning (severity dot, diff highlight,
/// approve/reject). Really necessary information on the front; the
/// rest (理由/誰が/参加者/出典) expands in the details panel.
abstract final class PopColors {
  // iOS dark system grays.
  static const Color bg = Color(0xFF0A0A0B);
  static const Color surface = Color(0xFF1C1C1E); // elevated card
  static const Color surface2 = Color(0xFF2C2C2E); // inset grouped list
  static const Color fill = Color(0x5C787880); // tertiarySystemFill
  static const Color fill2 = Color(0x3D787880); // quaternary fill — chips
  static const Color separator = Color(0xA6545458);
  static const Color borderColor = Color(0xFF2C2C2E);
  static const Color borderSoft = Color(0x14FFFFFF);

  static const Color text = Color(0xFFFFFFFF); // label
  static const Color text2 = Color(0x99EBEBF5); // secondaryLabel
  static const Color text3 = Color(0x4DEBEBF5); // tertiaryLabel

  // System colors (dark).
  static const Color blue = Color(0xFF0A84FF);
  static const Color green = Color(0xFF30D158);
  static const Color red = Color(0xFFFF453A);
  static const Color orange = Color(0xFFFF9F0A);
  static const Color yellow = Color(0xFFFFD60A);

  // I-1004 semantic roles — meanings, not just values. Mirrors the
  // semantic block in web/style.css :root. Sync/communication states
  // never borrow severity hues; external content is isolated by
  // border+surface, not a danger color (design-system.md §2).
  static const Color accent = blue; // action/focus accent
  static const Color approve = green; // approve/success result
  static const Color reject = red; // reject/destructive (not severity)
  static const Color syncPending = text3; // unsent / queued
  static const Color syncSending = orange; // in flight
  static const Color syncOk = green; // delivered / connected
  static const Color syncFailed = red; // delivery failed
  static const Color syncConflict = yellow; // 409 conflict
  static const Color externalBorder = fill; // external-quote separator
  static const Color externalSurface = surface2; // quote-block fill
  static const Color verified = green; // hub-verified agent identity
  static const Color unverified = text3; // unregistered agent
  static const Color scopeWarn = orange; // unregistered scope request

  /// Severity dot colors. Severity is its own meaning axis — `info`
  /// aliases the accent hue but keeps a separate role so a future
  /// accent change can't silently recolor severity (design-system.md §2).
  static const Color severityInfo = blue;
  static Color severityDot(String severity) => switch (severity) {
        'critical' => red,
        'warning' => orange,
        _ => severityInfo,
      };
}
