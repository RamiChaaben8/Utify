// ============================================================
// platform/permission_mobile.dart
//
// Runtime permission requesting on Android.
// Uses a direct MethodChannel to avoid depending on
// permission_handler (which breaks Windows builds).
//
// All required permissions are declared in AndroidManifest.xml.
// This call prompts the OS dialog for dangerous permissions on
// Android 6+ so the user explicitly grants storage/audio access.
// ============================================================

import 'package:flutter/services.dart';

const _channel = MethodChannel('com.example.testf/permissions');

Future<void>? _notificationPermissionRequest;

Future<void> requestNotificationPermission() {
  return _notificationPermissionRequest ??= _requestNotificationPermission();
}

Future<void> _requestNotificationPermission() async {
  try {
    await _channel.invokeMethod<void>('requestNotificationPermission');
  } catch (_) {
    // Non-fatal — Android settings can still be used to enable notifications.
  }
}

Future<void> requestStoragePermission() async {
  try {
    await _channel.invokeMethod<void>('requestStoragePermissions');
  } catch (_) {
    // Non-fatal — worst case local scan returns only app-scoped files
  }
}
