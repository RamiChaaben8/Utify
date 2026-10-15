import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:utify/utils/text_metrics.dart';

void main() {
  testWidgets('scaledTextHeight tracks the text scale and line count',
      (tester) async {
    late double oneLine;
    late double twoLines;
    late double oneLineScaled;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Builder(
          builder: (context) {
            oneLine = scaledTextHeight(context, const TextStyle(fontSize: 12), 1);
            twoLines = scaledTextHeight(context, const TextStyle(fontSize: 12), 2);
            return const SizedBox();
          },
        ),
      ),
    );

    // Two lines are twice one line, and a line is at least the font size.
    expect(twoLines, closeTo(oneLine * 2, 0.01));
    expect(oneLine, greaterThanOrEqualTo(12.0));

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: Builder(
          builder: (context) {
            oneLineScaled =
                scaledTextHeight(context, const TextStyle(fontSize: 12), 1);
            return const SizedBox();
          },
        ),
      ),
    );

    expect(oneLineScaled, closeTo(oneLine * 2, 0.01));
  });
}
