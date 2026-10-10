// ============================================================
// platform/permission_stub.dart
//
// No-op stub used on platforms where permission_handler is not
// supported (Windows, Linux, macOS, web).
// The real implementation lives in permission_mobile.dart and
// is only compiled on Android/iOS.
// ============================================================

Future<void> requestNotificationPermission() async {}

Future<void> requestStoragePermission() async {
  // Nothing to do on desktop — the OS grants file access by default.
}
