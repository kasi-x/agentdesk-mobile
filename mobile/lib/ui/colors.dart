import 'package:flutter/material.dart';

/// Color-pop design tokens — mirror of `web/style.css :root`.
///
/// The card surface itself carries severity (lime = info, amber =
/// warning, coral = critical) with near-black ink text; white pills
/// carry content components; dark pills carry actions. Chrome stays
/// warm-dark and quiet.
abstract final class PopColors {
  // Warm dark chrome.
  static const Color bg = Color(0xFF191B16);
  static const Color chrome = Color(0xFF23251F);
  static const Color chrome2 = Color(0xFF2B2E27);
  static const Color borderColor = Color(0xFF3A3D34);
  static const Color text = Color(0xFFEEF0E9);
  static const Color muted = Color(0xFFA8AD9F);
  static const Color faint = Color(0xFF77806B);

  /// Amber CTA (pending pill, 修正して承認, segmented selection).
  static const Color amber = Color(0xFFF5C842);

  // Ink on colored cards.
  static const Color ink = Color(0xFF1B1E16);
  static const Color inkSoft = Color(0xB81B1E16);
  static const Color pill = Color(0xEDFFFFFF);
  static const Color pillInk = Color(0xFF22251D);
  static const Color darkPill = Color(0xEB14170F);

  // Severity card gradients (top → bottom).
  static const Color infoTop = Color(0xFFD6EC86);
  static const Color infoBottom = Color(0xFFC2DF5F);
  static const Color warningTop = Color(0xFFF7D452);
  static const Color warningBottom = Color(0xFFEFBA2F);
  static const Color criticalTop = Color(0xFFF4695C);
  static const Color criticalBottom = Color(0xFFE94A3D);

  static const Color lime = Color(0xFFC9E26B);
  static const Color coral = Color(0xFFFF8D7E);

  static const Color diffBefore = Color(0xFFC2321F);
  static const Color diffAfter = Color(0xFF1C7A3A);

  /// (top, bottom) gradient pair for a severity card surface.
  static (Color, Color) severityCard(String severity) => switch (severity) {
        'critical' => (criticalTop, criticalBottom),
        'warning' => (warningTop, warningBottom),
        _ => (infoTop, infoBottom),
      };

  /// Ambient glow behind the card, tinted by severity.
  static Color severityGlow(String severity) => switch (severity) {
        'critical' => const Color(0x5CE94A3D),
        'warning' => const Color(0x52EFBA2F),
        _ => const Color(0x57C6DF5F),
      };
}
