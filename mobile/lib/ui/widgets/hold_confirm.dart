import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Hold-to-confirm ring (I-103): the user must press and hold until the
/// ring fills to trigger [onConfirmed]. Releasing early resets with no
/// action — used for locked (critical + irreversible) approvals where a
/// plain swipe is disabled (I-102).
class HoldConfirmButton extends StatefulWidget {
  final String label;
  final VoidCallback onConfirmed;

  /// Ring fill duration. Kept intentionally long so a tap can never
  /// confirm by accident.
  final Duration duration;

  const HoldConfirmButton({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.duration = const Duration(milliseconds: 1200),
  });

  @override
  State<HoldConfirmButton> createState() => _HoldConfirmButtonState();
}

class _HoldConfirmButtonState extends State<HoldConfirmButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        HapticFeedback.heavyImpact();
        widget.onConfirmed();
      }
    });

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _controller.forward(),
      onPointerUp: (_) => _controller.reverse(),
      onPointerCancel: (_) => _controller.reverse(),
      child: SizedBox(
        width: 64,
        height: 64,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: _controller.value,
                strokeWidth: 4,
                backgroundColor: Colors.white12,
                valueColor: const AlwaysStoppedAnimation(Color(0xFFFF5C5C)),
              ),
              Icon(
                _controller.value > 0 ? Icons.lock_open : Icons.lock_outline,
                size: 26,
                color: Colors.white70,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
