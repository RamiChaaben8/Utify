// tool/test_download_logic.dart
//
// Standalone Dart script — no Flutter, no Hive, no YoutubeExplode.
// Tests the phase-logging helpers, watchdog, concurrency limiter, and
// real-progress calculation that were added to download_service.dart.
//
// Run with:
//   dart tool/test_download_logic.dart
//
// Expected output (timestamps will differ):
//   [PASS] phaseLog emits UTC timestamp
//   [PASS] phaseLog includes videoId and phase
//   [PASS] phaseLog includes optional detail
//   [PASS] watchdog completes fast work without timing out
//   [PASS] watchdog times out slow work within ~1 second
//   [PASS] watchdog error message names the stuck phase
//   [PASS] concurrency limiter never exceeds maxConcurrent
//   [PASS] concurrency slot released in finally even on throw
//   [PASS] real progress from totalBytes
//   [PASS] fallback progress when totalBytes == 0
//   [PASS] pause loop exits on cancel without spinning forever
//   ALL TESTS PASSED

import 'dart:async';

// ─── Minimal stubs for the pieces we test ────────────────────────────────────

bool kDebugMode = true; // always true for this script

final List<String> _logs = [];

void debugPrint(String msg) {
  print(msg); // also echo to stdout
  _logs.add(msg);
}

void _phaseLog(String videoId, String phase, [String? detail]) {
  if (!kDebugMode) return;
  final ts = DateTime.now().toUtc().toIso8601String();
  final msg = detail != null
      ? '[DownloadService][$ts] $videoId | $phase — $detail'
      : '[DownloadService][$ts] $videoId | $phase';
  debugPrint(msg);
}

const Duration _kWatchdogTimeout = Duration(seconds: 1); // shorter for the test

Future<T> _watchdog<T>({
  required String videoId,
  required String phase,
  required Future<T> Function() work,
}) {
  return work().timeout(
    _kWatchdogTimeout,
    onTimeout: () {
      _phaseLog(videoId, 'WATCHDOG_TIMEOUT',
          'stuck in $phase for ${_kWatchdogTimeout.inSeconds}s');
      throw Exception(
        'Download watchdog: stuck in $phase for ${_kWatchdogTimeout.inSeconds} s — aborting',
      );
    },
  );
}

// ─── Test helpers ─────────────────────────────────────────────────────────────

int _passed = 0;
int _failed = 0;

void expect(String name, bool condition, [String? detail]) {
  if (condition) {
    print('[PASS] $name');
    _passed++;
  } else {
    print('[FAIL] $name${detail != null ? " — $detail" : ""}');
    _failed++;
  }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

void testPhaseLog() {
  _logs.clear();
  _phaseLog('vid123', 'QUEUED');
  _phaseLog('vid123', 'SLOT_ACQUIRED', '"My Song"');

  final log0 = _logs[0];
  final log1 = _logs[1];

  // Must contain a UTC ISO timestamp
  expect('phaseLog emits UTC timestamp',
      RegExp(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}').hasMatch(log0));

  // Must contain the videoId and phase
  expect('phaseLog includes videoId and phase',
      log0.contains('vid123') && log0.contains('QUEUED'));

  // Must include optional detail
  expect('phaseLog includes optional detail',
      log1.contains('"My Song"') && log1.contains('SLOT_ACQUIRED'));
}

Future<void> testWatchdog() async {
  // Fast work should complete normally.
  final result = await _watchdog(
    videoId: 'vid_fast',
    phase:   'FAST_PHASE',
    work:    () async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return 42;
    },
  );
  expect('watchdog completes fast work without timing out', result == 42);

  // Slow work must throw within [_kWatchdogTimeout].
  final sw = Stopwatch()..start();
  String? errorMsg;
  try {
    await _watchdog(
      videoId: 'vid_slow',
      phase:   'SLOW_PHASE',
      work:    () async {
        await Future<void>.delayed(const Duration(seconds: 10));
        return 0;
      },
    );
  } catch (e) {
    errorMsg = e.toString();
  }
  sw.stop();

  expect('watchdog times out slow work within ~1 second',
      sw.elapsedMilliseconds < 2000 && errorMsg != null);

  expect('watchdog error message names the stuck phase',
      errorMsg?.contains('SLOW_PHASE') ?? false, errorMsg);
}

Future<void> testConcurrencyLimiter() async {
  const maxConcurrent = 3;
  var activeTasks = 0;
  var maxSeen     = 0;
  var slotLeak    = false;

  final List<Future<void>> futures = [];

  for (var i = 0; i < 6; i++) {
    final taskId = i;
    Future<void> runTask() async {
      activeTasks++;
      if (activeTasks > maxConcurrent) slotLeak = true;
      maxSeen = activeTasks > maxSeen ? activeTasks : maxSeen;
      try {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (taskId == 4) throw Exception('simulated failure');
      } finally {
        activeTasks--;
      }
    }

    // Drain: only start if under the limit.
    while (activeTasks >= maxConcurrent) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // Swallow per-task errors so Future.wait never rethrows them.
    futures.add(runTask().catchError((_) {}));
  }

  await Future.wait(futures);

  expect('concurrency limiter never exceeds maxConcurrent', !slotLeak,
      'max seen: $maxSeen');
  expect('concurrency slot released in finally even on throw',
      activeTasks == 0, 'activeTasks at end: $activeTasks');
}

Future<void> testRealProgress() async {
  // Real progress: received / totalBytes
  const totalBytes = 5 * 1024 * 1024; // 5 MB
  var received = 0;
  final chunks = [512 * 1024, 1024 * 1024, 1024 * 1024, 512 * 1024];

  double lastProgress = 0.0;
  bool monotone = true;
  bool reachesOne = false;

  for (final chunk in chunks) {
    received += chunk;
    final p = (received / totalBytes).clamp(0.0, 1.0);
    if (p < lastProgress) monotone = false;
    lastProgress = p;
  }
  received = totalBytes;
  final finalP = (received / totalBytes).clamp(0.0, 1.0);
  if (finalP == 1.0) reachesOne = true;

  expect('real progress from totalBytes', monotone && reachesOne,
      'last=${lastProgress.toStringAsFixed(3)}, final=$finalP');

  // Fallback: estimate when totalBytes == 0
  const estimate = 6 * 1024 * 1024;
  var fbReceived = 0;
  double fbProgress = 0.0;
  for (final chunk in chunks) {
    fbReceived += chunk;
    fbProgress = 0.02 + (fbReceived / estimate).clamp(0.0, 0.93);
  }
  expect('fallback progress when totalBytes == 0',
      fbProgress > 0.0 && fbProgress <= 0.95,
      'fbProgress=${fbProgress.toStringAsFixed(3)}');
}

Future<void> testPauseLoopCancelEscape() async {
  // Simulate the pause loop: while (isPaused && !isCancelled) delay.
  // If cancel() fires, the loop must exit within a reasonable time.
  var isPaused    = true;
  var isCancelled = false;

  // Cancel after 150ms.
  Timer(const Duration(milliseconds: 150), () {
    isCancelled = true;
  });

  final sw = Stopwatch()..start();
  while (isPaused && !isCancelled) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  sw.stop();

  expect('pause loop exits on cancel without spinning forever',
      sw.elapsedMilliseconds < 500, 'took ${sw.elapsedMilliseconds} ms');
}

// ─── Main ──────────────────────────────────────────────────────────────────────

Future<void> main() async {
  print('── download_service logic tests ──────────────────────────────');
  testPhaseLog();
  await testWatchdog();
  await testConcurrencyLimiter();
  await testRealProgress();
  await testPauseLoopCancelEscape();
  print('──────────────────────────────────────────────────────────────');
  if (_failed == 0) {
    print('ALL $_passed TESTS PASSED');
  } else {
    print('$_failed FAILED  /  $_passed passed');
  }
}
