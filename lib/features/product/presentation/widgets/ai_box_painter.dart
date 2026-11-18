import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:zytama_data/core/constants/app_colors.dart';

/// Draws the AI's product box on a still photo: thin outline + corner
/// brackets, the same look as the live camera frame, in the app's theme
/// colour (Blue Green, [AppColors.secondary]) by default.
///
/// [box] is normalised (0..1) to the photo. The photo is assumed to be laid
/// out with [fit] (`fill`, `contain` or `cover`) in the painted area, and
/// [aspect] is its width / height, so the box lands on the product however
/// the photo is shown.
class AiBoxPainter extends CustomPainter {
  final Rect box;
  final double aspect;
  final BoxFit fit;
  final Color color;

  const AiBoxPainter(
    this.box, {
    required this.aspect,
    this.fit = BoxFit.fill,
    this.color = AppColors.secondary,
  });

  /// Where the photo itself sits inside [size] for [fit].
  static Rect photoRect(Size size, double aspect, BoxFit fit) {
    if (fit == BoxFit.fill || aspect <= 0) return Offset.zero & size;
    final sx = size.width / aspect, sy = size.height;
    final s = fit == BoxFit.cover ? math.max(sx, sy) : math.min(sx, sy);
    final w = aspect * s, h = s;
    return Rect.fromLTWH(
        (size.width - w) / 2, (size.height - h) / 2, w, h);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final p = photoRect(size, aspect, fit);
    final r = Rect.fromLTRB(
      p.left + box.left * p.width,
      p.top + box.top * p.height,
      p.left + box.right * p.width,
      p.top + box.bottom * p.height,
    ).inflate(2).intersect(Offset.zero & size);
    if (r.width <= 0 || r.height <= 0) return;

    canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(8)),
        Paint()
          ..color = color.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2);
    final len = math.min(24.0, r.shortestSide * 0.22);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final (c, dx, dy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomLeft, 1.0, -1.0),
      (r.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawPath(
          Path()
            ..moveTo(c.dx, c.dy + len * dy)
            ..lineTo(c.dx, c.dy)
            ..lineTo(c.dx + len * dx, c.dy),
          paint);
    }
  }

  @override
  bool shouldRepaint(AiBoxPainter old) =>
      old.box != box ||
      old.aspect != aspect ||
      old.fit != fit ||
      old.color != color;
}
