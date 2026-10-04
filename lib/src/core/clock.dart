import 'dart:math';

abstract interface class Clock {
  double wall();
  double monotonic();
  Future<void> sleep(Duration duration);
}

class SystemClock implements Clock {
  final Stopwatch _watch = Stopwatch()..start();
  @override
  double wall() => DateTime.now().microsecondsSinceEpoch / 1000000;
  @override
  double monotonic() => _watch.elapsedMicroseconds / 1000000;
  @override
  Future<void> sleep(Duration duration) => Future<void>.delayed(duration);
}

String randomId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
