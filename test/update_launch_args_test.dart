// ============================================================
// test/update_launch_args_test.dart
//
// Regression guard for the Windows auto-update failure.
//
// v1.6.3 launched the Inno Setup installer with
//
//     '/LOG="$logPath"'    // e.g. /LOG="C:\Users\...\utify-setup.log"
//
// Dart quotes process arguments itself, so Setup actually received
//
//     /LOG=\"C:\Users\...\utify-setup.log\"
//
// and aborted with
//
//     Error creating log file: The filename, directory name, or volume label
//     syntax is incorrect.
//
// leaving the user stuck on the old version with no way to auto-update.
// Only value-free flags survive Dart's quoting, so this test locks that in.
// ============================================================

import 'package:flutter_test/flutter_test.dart';
import 'package:utify/services/update_service.dart';

void main() {
  group('windowsSetupArgs', () {
    test('every argument is a bare flag: no value, quotes or path', () {
      for (final arg in windowsSetupArgs) {
        expect(arg.startsWith('/'), isTrue, reason: 'not a flag: $arg');
        expect(arg.contains('='), isFalse, reason: 'carries a value: $arg');
        expect(arg.contains('"'), isFalse, reason: 'contains a quote: $arg');
        expect(arg.contains('\\'), isFalse,
            reason: 'contains a backslash: $arg');
        expect(arg.contains(' '), isFalse, reason: 'contains a space: $arg');
        expect(arg.contains(':'), isFalse, reason: 'looks like a path: $arg');
      }
    });

    test('never passes /LOG or /DIR (the v1.6.3 breakage)', () {
      for (final arg in windowsSetupArgs) {
        final upper = arg.toUpperCase();
        expect(upper.startsWith('/LOG'), isFalse, reason: 'found $arg');
        expect(upper.startsWith('/DIR'), isFalse, reason: 'found $arg');
      }
    });

    test('keeps the flags a silent, self-restarting update needs', () {
      expect(windowsSetupArgs, contains('/SILENT'));
      expect(windowsSetupArgs, contains('/SUPPRESSMSGBOXES'));
      expect(windowsSetupArgs, contains('/CLOSEAPPLICATIONS'));
      expect(windowsSetupArgs, contains('/NORESTART'));
    });
  });
}
