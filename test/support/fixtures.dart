// Offline synthetic safety coverage. Never constructs native state or a real API.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show FileSystemException, OSError;

import 'package:openai_autoreset/autoreset.dart' as ar;
import 'package:test/test.dart';

const now = 1800000000.0;
const week = 604800;
Map<String, dynamic> usage(num remaining, {num boundary = now + 10000}) => {
  'rate_limit': <String, dynamic>{
    'primary_window': <String, dynamic>{
      'limit_window_seconds': 18000,
      'used_percent': 100,
      'reset_at': now + 1000,
    },
    'secondary_window': <String, dynamic>{
      'limit_window_seconds': week,
      'used_percent': 100 - remaining,
      'reset_at': boundary,
    },
  },
};
Map<String, dynamic> inventory([String status = 'available']) => {
  'available_count': status == 'available' ? 1 : 0,
  'credits': <dynamic>[
    <String, dynamic>{
      'id': 'synthetic-credit',
      'status': status,
      'reset_type': 'codex_rate_limits',
      'expires_at':
          DateTime.fromMillisecondsSinceEpoch(
            ((now + 86400) * 1000).toInt(),
            isUtc: true,
          ).toIso8601String(),
    },
  ],
};
Map<String, dynamic> clone(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

class FakeClock implements ar.Clock {
  List<double> ticks;
  double currentWall = now;
  final sleeps = <Duration>[];
  FakeClock([this.ticks = const []]);
  @override
  double wall() => currentWall;
  @override
  double monotonic() {
    if (ticks.isEmpty) return 42;
    final result = ticks.first;
    ticks = ticks.skip(1).toList();
    return result;
  }

  @override
  Future<void> sleep(Duration duration) async {
    sleeps.add(duration);
  }
}

class MemoryStore implements ar.StateStore {
  final saved = <Map<String, dynamic>>[];
  FutureOr<void> Function(Map<String, dynamic>)? beforeSave;
  @override
  Future<void> save(Map<String, dynamic> state) async {
    await beforeSave?.call(state);
    saved.add(clone(state));
  }
}

class FakeApi implements ar.Api {
  final List<num> readings;
  final calls = <(String, Map<String, dynamic>?)>[];
  bool posted = false;
  bool failPost = false;
  String afterStatus = 'consumed';
  void Function()? onPost;
  Map<String, dynamic> Function(int, Map<String, dynamic>)? transformUsage;
  Map<String, dynamic>? creditOverride;
  Map<String, dynamic> Function(int, Map<String, dynamic>)? transformInventory;
  int creditCalls = 0;
  int usageCalls = 0;
  FakeApi([List<num>? readings]) : readings = List.of(readings ?? [0, 0, 100]);
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    calls.add((path, body));
    if ((body != null) != (path == 'rate-limit-reset-credits/consume')) {
      throw StateError('Unexpected synthetic API method/body pairing');
    }
    if (path == 'usage') {
      final data = usage(readings.removeAt(0));
      usageCalls++;
      return transformUsage?.call(usageCalls, data) ?? data;
    }
    if (path == 'rate-limit-reset-credits/consume') {
      onPost?.call();
      posted = true;
      if (failPost) throw ar.Refusal('Synthetic ambiguous timeout');
      return {'success': true};
    }
    if (path == 'rate-limit-reset-credits') {
      final data =
          creditOverride ?? inventory(posted ? afterStatus : 'available');
      creditCalls++;
      return transformInventory?.call(creditCalls, data) ?? data;
    }
    throw StateError('Unexpected synthetic API endpoint: $path');
  }
}

class GuardedFakeApi extends FakeApi implements ar.GuardedApi {
  void Function()? beforePermit;
  int consumeCalls = 0;
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    Map<String, dynamic>? body,
  }) {
    if (path.endsWith('/consume'))
      throw StateError('Guarded POST bypass prohibited');
    return super.request(path, body: body);
  }

  @override
  Future<Map<String, dynamic>> consume(
    Map<String, dynamic> body, {
    required bool Function() permit,
  }) async {
    consumeCalls++;
    beforePermit?.call();
    if (!permit()) throw const ar.ConsumeNotSent();
    return super.request('rate-limit-reset-credits/consume', body: body);
  }
}

class Harness {
  final state = <String, dynamic>{
    'version': 1,
    'account': 'synthetic',
    'attempts': <dynamic>[],
  };
  final store = MemoryStore();
  FakeClock clock = FakeClock();
  bool Function()? stopping;
  Future<void> check(FakeApi api, {bool execute = true, int? maximum = 1}) =>
      ar.check(
        api,
        execute: execute,
        maxResets: maximum,
        state: state,
        store: store,
        clock: clock,
        stopping: stopping,
        output: (_) {},
        requestId: () => 'synthetic-request',
      );
  List<dynamic> get attempts => state['attempts'] as List<dynamic>;
  void prior(String status, num age, [int count = 1]) {
    state['attempts'] = List.generate(
      count,
      (i) => <String, dynamic>{
        'status': status,
        'time': now - age - i,
        'credit_id': 'older-$i',
        'request_id': 'older-request-$i',
      },
    );
  }
}

final refusal = throwsA(isA<ar.Refusal>());
Matcher refusalWith(String text) => throwsA(
  isA<ar.Refusal>().having((e) => e.message, 'message', contains(text)),
);
