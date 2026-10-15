// ============================================================
// utils/text_metrics.dart
//
// Measuring helpers for fixed-height card rows.
// ============================================================

import 'package:flutter/widgets.dart';

/// Height that [lines] lines of [style] occupy at the current text scale,
/// measured with the real font metrics.
///
/// Horizontal card rows use a fixed height (a horizontal ListView needs one),
/// so measuring the text instead of hard-coding a number keeps the row from
/// overflowing when the user has a large system font.
double scaledTextHeight(BuildContext context, TextStyle style, int lines) {
  // Mirror `Text`: merge the card style over the ambient default so inherited
  // properties (family, height) are accounted for.
  final effective = DefaultTextStyle.of(context).style.merge(style);
  final painter = TextPainter(
    text: TextSpan(text: 'X', style: effective),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  return painter.height * lines;
}
