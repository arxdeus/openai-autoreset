// Offline synthetic safety coverage. Never constructs native state or a real API.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show FileSystemException, OSError;

import 'package:openai_autoreset/autoreset.dart' as ar;
import 'package:test/test.dart';

const now = 1800000000.0;
const week = 604800;
Map<String, dynamic> usage(num remaining, {num boundary = now + 10000}) => {
  'rate_limit': {
    'primary_window': {
      'limit_window_seconds': 18000,
      'used_percent': 100,
      'reset_at': now + 1000,
    },
    'secondary_window': {
      'limit_window_seconds': week,
      'used_percent': 100 - remaining,
      'reset_at': boundary,
    },
  },
};
Map<String, dynamic> inventory([String status = 'available']) => {
  'available_count': status == 'available' ? 1 : 0,
  'credits': [
    {
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

void main() {
  group('Synthetic auth data only', () {
    final account = <String, dynamic>{
      'account_id': 'pinned-account',
      'access_token': 'fake-pinned',
    };
    test('pinned account wins over active account', () {
      expect(
        ar.authToken({
          'active_openai_account': 'other',
          'openai_accounts': [
            {'account_id': 'other-account', 'access_token': 'fake-other'},
            account,
          ],
        }, 'pinned-account'),
        'fake-pinned',
      );
    });
    test('missing and duplicate pinned accounts fail closed', () {
      for (final entries in [
        [],
        [
          {'account_id': 'other', 'access_token': 'fake'},
        ],
        [account, account],
      ]) {
        expect(
          () => ar.authToken({'openai_accounts': entries}, 'pinned-account'),
          refusal,
        );
      }
    });
    test('malformed credential stores fail closed', () {
      for (final data in [
        null,
        [],
        {'openai_accounts': {}},
        {
          'openai_accounts': [null],
        },
        {
          'openai_accounts': [
            {'account_id': 'pinned-account'},
          ],
        },
        {
          'openai_accounts': [
            {'account_id': 'pinned-account', 'access_token': ''},
          ],
        },
      ]) {
        expect(() => ar.authToken(data, 'pinned-account'), refusal);
      }
    });
    test('Codex nested and flat credentials retained', () {
      for (final data in [
        account,
        {'tokens': account},
      ]) {
        expect(ar.authToken(data, 'pinned-account'), 'fake-pinned');
      }
    });
    test('header newline injection refused in tokens and account IDs', () {
      for (final suffix in ['\r', '\n', '\r\nInjected: yes']) {
        expect(
          () => ar.authToken({
            ...account,
            'access_token': 'fake$suffix',
          }, 'pinned-account'),
          refusal,
        );
        expect(
          () => ar.authToken({
            ...account,
            'account_id': 'pinned-account$suffix',
          }, 'pinned-account$suffix'),
          refusal,
        );
      }
    });
    test('flat and nested account mismatch refused', () {
      for (final data in [
        account,
        {'tokens': account},
      ]) {
        expect(() => ar.authToken(data, 'other'), refusal);
      }
    });
  });
  group('Schema and numerical safety', () {
    test('non-numeric and unbounded Dart numeric representations refused', () {
      for (final value in [
        true,
        '100',
        BigInt.one << 4096,
        double.infinity,
        double.nan,
      ]) {
        expect(() => ar.number(value), refusal);
      }
    });
    test('fractional ISO timestamps and explicit offsets stay eligible', () {
      for (final expiry in [
        '2027-02-01T00:00:00.123Z',
        '2027-02-01T08:00:00.123+08:00',
      ]) {
        final data = inventory();
        data['credits'][0]['expires_at'] = expiry;
        final credit = ar.availableCredits(data, now).single;
        expect(credit.id, 'synthetic-credit');
        expect(
          credit.expiresAt,
          DateTime.parse(expiry).microsecondsSinceEpoch / 1000000,
        );
      }
    });
    test('threshold accepts zero through exactly one percent', () {
      for (final value in [0, 0.5, 1]) {
        ar.requireThreshold(value);
      }
    });
    test('threshold refuses values above one percent', () {
      for (final value in [1.000001, 1.01, 2, 50, 100]) {
        expect(() => ar.requireThreshold(value), refusalWith('WARNING'));
      }
    });
    test('bad numeric usage values fail closed', () {
      for (final value in [
        null,
        true,
        '100',
        double.nan,
        double.infinity,
        double.negativeInfinity,
        -1,
        101,
      ]) {
        final data = usage(0);
        data['rate_limit']['secondary_window']['used_percent'] = value;
        expect(() => ar.weekly(data, now), refusal);
      }
    });
    test('missing duplicate and expired weekly windows refused', () {
      final missing = {
        'rate_limit': {
          'primary_window': usage(0)['rate_limit']['primary_window'],
        },
      };
      final duplicate = usage(0);
      duplicate['rate_limit']['primary_window'] =
          duplicate['rate_limit']['secondary_window'];
      for (final data in [
        missing,
        duplicate,
        usage(0, boundary: now - 1),
        usage(0, boundary: now),
      ]) {
        expect(() => ar.weekly(data, now), refusal);
      }
    });
    test('only weekly window controls remaining', () {
      final result = ar.weekly(usage(80), now);
      expect(result.remaining, 80);
      expect(result.resetAt, now + 10000);
    });
    test('inventory count mismatch refused', () {
      final data = inventory()..['available_count'] = 2;
      expect(() => ar.availableCredits(data, now), refusal);
    });
    test('malformed inventory fails closed', () {
      for (final data in [
        null,
        [],
        {'available_count': true, 'credits': []},
        {
          'available_count': 1,
          'credits': [null],
        },
        {'available_count': 1, 'credits': []},
      ]) {
        expect(() => ar.availableCredits(data, now), refusal);
      }
    });
    test('expired credit is ineligible', () {
      final data = inventory();
      data['credits'][0]['expires_at'] = '2020-01-01T00:00:00Z';
      expect(ar.availableCredits(data, now), isEmpty);
    });
    test('timezone-less malformed and impossible expiries refused', () {
      for (final expiry in [
        '2027-01-01T00:00:00',
        'not-a-date',
        '2027-02-30T00:00:00Z',
        '2030-01-42T00:00:00Z',
        null,
        42,
      ]) {
        final data = inventory();
        data['credits'][0]['expires_at'] = expiry;
        expect(() => ar.availableCredits(data, now), refusal);
      }
    });
    test('duplicate available credit IDs refused', () {
      final data = inventory();
      data['available_count'] = 2;
      data['credits'].add(Map<String, dynamic>.from(data['credits'][0] as Map));
      expect(() => ar.availableCredits(data, now), refusal);
    });
    test('eligible credits sorted by expiry and unrelated types excluded', () {
      final data = inventory();
      final late = Map<String, dynamic>.from(data['credits'][0] as Map)
        ..['id'] = 'late';
      final early =
          Map<String, dynamic>.from(late)
            ..['id'] = 'early'
            ..['expires_at'] =
                DateTime.fromMillisecondsSinceEpoch(
                  ((now + 3600) * 1000).toInt(),
                  isUtc: true,
                ).toIso8601String();
      final unrelated =
          Map<String, dynamic>.from(late)
            ..['id'] = 'unrelated'
            ..['reset_type'] = 'other';
      data['available_count'] = 3;
      data['credits'] = [late, unrelated, early];
      expect(ar.availableCredits(data, now).map((c) => c.id), [
        'early',
        'late',
      ]);
    });
    test('state header and attempts are validated without native state', () {
      final valid = <String, dynamic>{
        'version': 1,
        'account': 'synthetic-hash',
        'attempts': <dynamic>[],
      };
      expect(ar.validateState(valid, 'synthetic-hash')['attempts'], isEmpty);
      for (final data in [
        null,
        [],
        {...valid, 'version': true},
        {...valid, 'version': 1.0},
        {...valid, 'account': 'other'},
        {...valid, 'attempts': {}},
        {
          ...valid,
          'attempts': [null],
        },
        {
          ...valid,
          'attempts': [
            {
              'status': 'unknown',
              'time': now,
              'credit_id': 'x',
              'request_id': 'r',
            },
          ],
        },
        {
          ...valid,
          'attempts': [
            {
              'status': 'pending',
              'time': -1,
              'credit_id': 'x',
              'request_id': 'r',
            },
          ],
        },
      ]) {
        expect(() => ar.validateState(data, 'synthetic-hash'), refusal);
      }
    });
    test('clock sleep backwards movement and boundary expiry are stale', () {
      for (final wall in [now + 60, now - 1, now + 10000]) {
        final clock = FakeClock()..currentWall = wall;
        expect(ar.preflightStale(clock, 42, now, now + 10000), isTrue);
      }
    });
  });
  group('Reset transaction with in-memory state', () {
    late Harness h;
    setUp(() {
      h = Harness();
    });
    test('natural reset within five minutes preserves credit', () async {
      for (final seconds in [1, 299, 300]) {
        final api = FakeApi([0])
          ..transformUsage = (_, data) {
            data['rate_limit']['secondary_window']['reset_at'] = now + seconds;
            return data;
          };
        await expectLater(h.check(api), refusal);
        expect(api.posted, isFalse);
        expect(h.store.saved, isEmpty);
      }
    });
    test('previously attempted selected credit is never retried', () async {
      h.prior('verified', 30000);
      h.attempts[0]['credit_id'] = 'synthetic-credit';
      final api = FakeApi();
      await expectLater(h.check(api, maximum: null), refusal);
      expect(api.posted, isFalse);
      expect(h.store.saved, isEmpty);
    });
    test(
      'selected credit disappearing during preflight prevents POST',
      () async {
        final api = FakeApi();
        api.transformInventory =
            (count, data) =>
                count == 2 ? {'available_count': 0, 'credits': []} : data;
        await expectLater(h.check(api), refusal);
        expect(api.posted, isFalse);
        expect(h.store.saved, isEmpty);
      },
    );
    test('consumed receipt without recovered quota stays pending', () async {
      final api = FakeApi([0, 0, 1]);
      await expectLater(h.check(api), refusalWith('not verified'));
      expect(api.posted, isTrue);
      expect(h.store.saved.last['attempts'][0]['status'], 'pending');
    });
    test('receipt absence is not proof of consumption', () async {
      final api = FakeApi();
      api.transformInventory =
          (count, data) =>
              api.posted ? {'available_count': 0, 'credits': []} : data;
      await expectLater(h.check(api), refusalWith('not verified'));
      expect(api.posted, isTrue);
      expect(h.store.saved.last['attempts'][0]['status'], 'pending');
    });
    test(
      'execute requires explicit journal and store without native fallback',
      () async {
        final api = FakeApi([0]);
        await expectLater(
          ar.check(
            api,
            execute: true,
            clock: h.clock,
            output: (_) {},
            requestId: () => 'synthetic-request',
          ),
          refusal,
        );
        expect(api.calls, [('usage', null)]);
        expect(api.posted, isFalse);
      },
    );
    test('guarded transport cannot bypass final permit', () async {
      final api = GuardedFakeApi();
      await h.check(api);
      expect(api.consumeCalls, 1);
      expect(api.posted, isTrue);
      expect(h.store.saved.first['attempts'][0]['status'], 'pending');
      expect(h.store.saved.last['attempts'][0]['status'], 'verified');
    });
    test(
      'transport delay makes final permit stale and cancels unsent intent',
      () async {
        final api =
            GuardedFakeApi()
              ..beforePermit = () {
                h.clock.currentWall = now + 6;
              };
        await expectLater(h.check(api), refusalWith('unsent intent cancelled'));
        expect(api.consumeCalls, 1);
        expect(api.posted, isFalse);
        expect(h.store.saved.first['attempts'][0]['status'], 'pending');
        expect(h.store.saved.last['attempts'], isEmpty);
      },
    );
    test(
      'stop at transport permit cancels only provably unsent intent',
      () async {
        var stopped = false;
        h.stopping = () => stopped;
        final api =
            GuardedFakeApi()
              ..beforePermit = () {
                stopped = true;
              };
        await expectLater(h.check(api), refusalWith('unsent intent cancelled'));
        expect(api.posted, isFalse);
        expect(h.store.saved.last['attempts'], isEmpty);
      },
    );
    test('session exhaustion alone never triggers reset', () async {
      final api = FakeApi([80]);
      await expectLater(h.check(api), refusalWith('WARNING'));
      expect(api.calls, [('usage', null)]);
      expect(h.store.saved, isEmpty);
    });
    test('dry run never posts or persists', () async {
      final api = FakeApi([0]);
      await h.check(api, execute: false);
      expect(api.posted, isFalse);
      expect(h.store.saved, isEmpty);
      expect(h.attempts, isEmpty);
    });
    test('fresh usage above threshold blocks POST', () async {
      final api = FakeApi([0, 2]);
      await expectLater(h.check(api), refusalWith('WARNING'));
      expect(api.posted, isFalse);
      expect(h.store.saved, isEmpty);
    });
    test('durable pending intent precedes exactly one POST', () async {
      final api = FakeApi([1, 1, 100]);
      api.onPost = () {
        expect(h.store.saved.last['attempts'][0]['status'], 'pending');
      };
      await h.check(api);
      final posts = api.calls.where((c) => c.$1.endsWith('/consume')).toList();
      expect(posts, hasLength(1));
      expect(posts.single.$2!['credit_id'], 'synthetic-credit');
      expect(
        posts.single.$2!['redeem_request_id'],
        h.store.saved.first['attempts'][0]['request_id'],
      );
      expect(h.store.saved.last['attempts'][0]['status'], 'verified');
    });
    test(
      'ambiguous POST preserves pending and blocks next invocation',
      () async {
        final api = FakeApi()..failPost = true;
        await expectLater(h.check(api), refusal);
        expect(h.store.saved.last['attempts'][0]['status'], 'pending');
        final second = FakeApi();
        await expectLater(
          h.check(second, maximum: 10),
          refusalWith('Unresolved'),
        );
        expect(second.posted, isFalse);
      },
    );
    test('initial persistence failure prevents POST', () async {
      final api = FakeApi();
      h.store.beforeSave = (_) {
        throw StateError('Synthetic disk failure');
      };
      await expectLater(h.check(api), throwsStateError);
      expect(api.posted, isFalse);
    });
    test('unverified receipt leaves durable pending', () async {
      final api = FakeApi()..afterStatus = 'unknown';
      await expectLater(h.check(api), refusalWith('not verified'));
      expect(h.store.saved.last['attempts'][0]['status'], 'pending');
    });
    test('cap and cooldown each independently block', () async {
      for (final example in [(30000, 1), (100, 2)]) {
        h = Harness()..prior('verified', example.$1);
        final api = FakeApi();
        await expectLater(h.check(api, maximum: example.$2), refusal);
        expect(api.posted, isFalse);
      }
    });
    test('uncapped permits another verified cycle', () async {
      h.prior('verified', 30000, 3);
      final api = FakeApi();
      await h.check(api, maximum: null);
      expect(api.posted, isTrue);
      expect(h.attempts, hasLength(4));
      expect(h.attempts.last['status'], 'verified');
    });
    test('uncapped still blocks pending', () async {
      h.prior('pending', 30000);
      final api = FakeApi();
      await expectLater(h.check(api, maximum: null), refusalWith('Unresolved'));
      expect(api.posted, isFalse);
    });
    test('uncapped still enforces cooldown', () async {
      h.prior('verified', 100);
      final api = FakeApi();
      await expectLater(h.check(api, maximum: null), refusalWith('cooldown'));
      expect(api.posted, isFalse);
    });
    test('uncapped still requires available credits', () async {
      final api =
          FakeApi()..creditOverride = {'available_count': 0, 'credits': []};
      await expectLater(
        h.check(api, maximum: null),
        refusalWith('No eligible'),
      );
      expect(api.posted, isFalse);
    });
    test('slow final read blocks before journal', () async {
      h.clock = FakeClock([0, 6]);
      final api = FakeApi();
      await expectLater(h.check(api), refusalWith('stale'));
      expect(api.posted, isFalse);
      expect(h.store.saved, isEmpty);
      expect(h.attempts, isEmpty);
    });
    test('slow journal rolls back only unsent intent', () async {
      h.clock = FakeClock([0, 0, 6]);
      final api = FakeApi();
      await expectLater(h.check(api), refusalWith('unsent intent cancelled'));
      expect(api.posted, isFalse);
      expect(h.store.saved.first['attempts'][0]['status'], 'pending');
      expect(h.store.saved.last['attempts'], isEmpty);
    });
    test('stop before poll issues no requests', () async {
      h.stopping = () => true;
      final api = FakeApi();
      await expectLater(h.check(api), refusalWith('stopping'));
      expect(api.calls, isEmpty);
    });
    test('stop during journal cancels unsent intent', () async {
      var stopped = false;
      h.stopping = () => stopped;
      h.store.beforeSave = (_) {
        stopped = true;
      };
      final api = FakeApi();
      await expectLater(h.check(api), refusalWith('unsent intent cancelled'));
      expect(api.posted, isFalse);
      expect(h.store.saved.last['attempts'], isEmpty);
    });
    test(
      'unsent rollback preserves all pre-existing verified attempts',
      () async {
        h.prior('verified', 30000, 2);
        final before = clone(h.state);
        h.clock = FakeClock([0, 0, 6]);
        final api = FakeApi();
        await expectLater(
          h.check(api, maximum: null),
          refusalWith('unsent intent cancelled'),
        );
        expect(api.posted, isFalse);
        expect(h.state, before);
        expect(h.store.saved.last, before);
      },
    );
    test(
      'stop after entering ambiguous POST never rolls back pending',
      () async {
        var stopped = false;
        h.stopping = () => stopped;
        final api = FakeApi()..failPost = true;
        api.onPost = () {
          stopped = true;
        };
        await expectLater(h.check(api), refusal);
        expect(api.posted, isTrue);
        expect(h.store.saved.last['attempts'][0]['status'], 'pending');
        expect(h.attempts.single['status'], 'pending');
      },
    );
    test('failed rollback preserves persisted pending', () async {
      h.clock = FakeClock([0, 0, 6]);
      h.store.beforeSave = (_) {
        if (h.store.saved.isNotEmpty)
          throw StateError('Synthetic rollback failure');
      };
      final api = FakeApi();
      await expectLater(h.check(api), throwsStateError);
      expect(api.posted, isFalse);
      expect(h.store.saved.single['attempts'][0]['status'], 'pending');
    });
    test('changed weekly boundary prevents POST', () async {
      final api = FakeApi();
      api.transformUsage = (count, data) {
        if (count == 2)
          data['rate_limit']['secondary_window']['reset_at'] += 100;
        return data;
      };
      await expectLater(h.check(api), refusalWith('window changed'));
      expect(api.posted, isFalse);
      expect(h.store.saved, isEmpty);
    });
    test('verification persistence failure keeps durable pending', () async {
      h.store.beforeSave = (_) {
        if (h.store.saved.isNotEmpty)
          throw StateError('Synthetic final save failure');
      };
      final api = FakeApi();
      await expectLater(h.check(api), throwsStateError);
      expect(api.posted, isTrue);
      expect(h.store.saved.single['attempts'][0]['status'], 'pending');
    });
    test('asynchronous journal must complete before POST', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var first = true;
      h.store.beforeSave = (_) async {
        if (first) {
          first = false;
          entered.complete();
          await release.future;
        }
      };
      final api = FakeApi();
      final operation = h.check(api);
      await entered.future;
      try {
        expect(api.posted, isFalse);
        expect(h.store.saved, isEmpty);
      } finally {
        release.complete();
      }
      await operation;
      expect(api.posted, isTrue);
    });
    test('post callback observes snapshot rather than mutable alias', () async {
      final api = FakeApi();
      await h.check(api);
      expect(h.store.saved.first['attempts'][0]['status'], 'pending');
      expect(h.store.saved.last['attempts'][0]['status'], 'verified');
    });
  });
  group('Background orchestration with synthetic callbacks', () {
    test(
      'poll warnings continue on one minute cadence without immediate retry',
      () async {
        var runs = 0;
        var stopped = false;
        final waits = <Duration>[];
        final errors = <Object>[];
        await ar.pollLoop(
          run: () async {
            runs++;
            throw ar.Refusal('WARNING: above 1%');
          },
          stopping: () => stopped,
          clock: FakeClock([0, 4, 60, 62]),
          wait: (duration) async {
            waits.add(duration);
            if (waits.length == 2) stopped = true;
          },
          output: (_) {},
          onError: errors.add,
        );
        expect(runs, 2);
        expect(errors, hasLength(2));
        expect(waits, [
          const Duration(seconds: 56),
          const Duration(seconds: 58),
        ]);
      },
    );
    test('stopped poll loop never runs or waits', () async {
      var runs = 0;
      final clock = FakeClock();
      await ar.pollLoop(
        run: () async {
          runs++;
        },
        stopping: () => true,
        clock: clock,
        output: (_) {},
        onError: (_) {},
      );
      expect(runs, 0);
      expect(clock.sleeps, isEmpty);
    });
    test('long poll duration clamps wait to zero', () async {
      var stopped = false;
      final waits = <Duration>[];
      await ar.pollLoop(
        run: () async {},
        stopping: () => stopped,
        clock: FakeClock([0, 61]),
        wait: (duration) async {
          waits.add(duration);
          stopped = true;
        },
        output: (_) {},
        onError: (_) {},
      );
      expect(waits, [Duration.zero]);
    });
    test('invalid local auth prevents readiness', () async {
      final events = <String>[];
      await expectLater(
        ar.localStartup(
          authCheck: () {
            events.add('auth');
            throw ar.Refusal('Invalid local auth');
          },
          stateCheck: () {
            events.add('state');
          },
          ready: () async {
            events.add('ready');
          },
        ),
        refusal,
      );
      expect(events, ['auth']);
    });
    test('invalid journal prevents readiness after auth', () async {
      final events = <String>[];
      await expectLater(
        ar.localStartup(
          authCheck: () {
            events.add('auth');
          },
          stateCheck: () {
            events.add('state');
            throw ar.Refusal('Invalid journal');
          },
          ready: () async {
            events.add('ready');
          },
        ),
        refusal,
      );
      expect(events, ['auth', 'state']);
    });
    test(
      'readiness awaits successful local checks and acknowledgment',
      () async {
        final events = <String>[];
        final entered = Completer<void>();
        final acknowledgment = Completer<void>();
        final startup = ar.localStartup(
          authCheck: () {
            events.add('auth');
          },
          stateCheck: () {
            events.add('state');
          },
          ready: () async {
            events.add('ready');
            entered.complete();
            await acknowledgment.future;
            events.add('ack');
          },
        );
        await entered.future;
        expect(events, ['auth', 'state', 'ready']);
        acknowledgment.complete();
        await startup;
        expect(events, ['auth', 'state', 'ready', 'ack']);
      },
    );
    test('readiness validates exact child PID token and framing', () {
      const token = 'synthetic-readiness-token';
      expect(ar.validReadyMessage('READY $token 444\n', token, 444), isTrue);
      for (final message in [
        '',
        'READY\n',
        'READY wrong 444\n',
        'READY $token 445\n',
        'READY $token 444',
        'READY $token 444\ntrailing',
        'READY $token 444\r\n',
      ]) {
        expect(ar.validReadyMessage(message, token, 444), isFalse);
      }
    });
  });
  group('Pure portable state directory paths', () {
    test('home selection uses HOME on Unix and USERPROFILE on Windows', () {
      const env = {
        'HOME': '/synthetic/unix',
        'USERPROFILE': r'C:\Synthetic\User',
      };
      expect(
        ar.homeFor(operatingSystem: 'linux', environment: env),
        '/synthetic/unix',
      );
      expect(
        ar.homeFor(operatingSystem: 'macos', environment: env),
        '/synthetic/unix',
      );
      expect(
        ar.homeFor(operatingSystem: 'windows', environment: env),
        r'C:\Synthetic\User',
      );
    });
    test('missing or empty platform home is refused', () {
      for (final os in ['macos', 'linux', 'windows']) {
        expect(() => ar.homeFor(operatingSystem: os, environment: {}), refusal);
        expect(
          () => ar.homeFor(
            operatingSystem: os,
            environment: {'HOME': '', 'USERPROFILE': ''},
          ),
          refusal,
        );
      }
    });
    test('default auth path retains Codex location on every OS', () {
      for (final os in ['macos', 'linux']) {
        expect(
          ar.authPathFor(home: '/synthetic/home', operatingSystem: os),
          '/synthetic/home/.codex/auth.json',
        );
      }
      expect(
        ar.authPathFor(home: r'C:\Synthetic\User', operatingSystem: 'windows'),
        r'C:\Synthetic\User\.codex\auth.json',
      );
    });
    test('aggregate platform paths use only supplied environment', () {
      final paths = ar.platformPathsFor('windows', {
        'USERPROFILE': r'C:\Synthetic\User',
        'LOCALAPPDATA': r'C:\Synthetic\Local',
      });
      expect(paths.home, r'C:\Synthetic\User');
      expect(paths.auth, r'C:\Synthetic\User\.codex\auth.json');
      expect(paths.state, r'C:\Synthetic\Local\openai-autoreset');
    });
    test('only genuine missing-file OS errors permit an empty journal', () {
      const absent = FileSystemException(
        'Synthetic missing',
        '/synthetic/journal',
        OSError('Synthetic ENOENT', 2),
      );
      const missingParent = FileSystemException(
        'Synthetic missing parent',
        '/synthetic/journal',
        OSError('Synthetic path missing', 3),
      );
      const denied = FileSystemException(
        'Synthetic denied',
        '/synthetic/journal',
        OSError('Synthetic access denied', 13),
      );
      const generic = FileSystemException(
        'Synthetic unknown',
        '/synthetic/journal',
      );
      for (final os in ['macos', 'linux', 'windows']) {
        expect(ar.isMissingFileError(absent, operatingSystem: os), isTrue);
        expect(ar.isMissingFileError(denied, operatingSystem: os), isFalse);
        expect(ar.isMissingFileError(generic, operatingSystem: os), isFalse);
        expect(
          ar.isMissingFileError(
            StateError('Synthetic error'),
            operatingSystem: os,
          ),
          isFalse,
        );
        expect(
          ar.isMissingFileError(missingParent, operatingSystem: os),
          os == 'windows',
        );
      }
    });
    test('macOS retains legacy journal directory', () {
      expect(
        ar.stateDirectoryFor(home: '/synthetic/home', operatingSystem: 'macos'),
        '/synthetic/home/Library/Application Support/openai-autoreset',
      );
    });
    test('Linux uses absolute XDG_STATE_HOME', () {
      expect(
        ar.stateDirectoryFor(
          home: '/synthetic/home',
          operatingSystem: 'linux',
          environment: {'XDG_STATE_HOME': '/synthetic/state'},
        ),
        '/synthetic/state/openai-autoreset',
      );
    });
    test('Linux ignores relative or empty XDG overrides', () {
      for (final env in <Map<String, String>>[
        {},
        {'XDG_STATE_HOME': ''},
        {'XDG_STATE_HOME': 'relative'},
      ]) {
        expect(
          ar.stateDirectoryFor(
            home: '/synthetic/home',
            operatingSystem: 'linux',
            environment: env,
          ),
          '/synthetic/home/.local/state/openai-autoreset',
        );
      }
    });
    test('Windows uses LOCALAPPDATA with Windows separators', () {
      expect(
        ar.stateDirectoryFor(
          home: r'C:\Synthetic\User',
          operatingSystem: 'windows',
          environment: {'LOCALAPPDATA': r'C:\Synthetic\Local'},
        ),
        r'C:\Synthetic\Local\openai-autoreset',
      );
    });
    test('Windows falls back to supplied user profile AppData', () {
      for (final env in <Map<String, String>>[
        {},
        {'LOCALAPPDATA': ''},
      ]) {
        expect(
          ar.stateDirectoryFor(
            home: r'C:\Synthetic\User',
            operatingSystem: 'windows',
            environment: env,
          ),
          r'C:\Synthetic\User\AppData\Local\openai-autoreset',
        );
      }
    });
  });
  group('Pure transport response safety', () {
    test('redirects are refused without forwarding credentials', () {
      for (final status in [301, 302, 303, 307, 308]) {
        expect(() => ar.validateResponseHeaders(status, null), refusal);
      }
    });
    test('non-success and cached responses fail closed', () {
      for (final status in [201, 204, 400, 401, 429, 500]) {
        expect(() => ar.validateResponseHeaders(status, null), refusal);
      }
      for (final ages in <List<String>>[
        ['1'],
        ['00'],
        ['bad'],
        ['0', '0'],
        [],
      ]) {
        expect(() => ar.validateResponseHeaders(200, ages), refusal);
      }
    });
    test('uncached successful response headers accepted', () {
      ar.validateResponseHeaders(200, null);
      ar.validateResponseHeaders(200, ['0']);
    });
  });
  group('Token reload with entirely synthetic boundaries', () {
    const args = ar.Options(
      accountId: 'synthetic-account',
      auth: '/synthetic/auth.json',
    );
    test(
      'each read-only poll reloads token without enabling execution',
      () async {
        final tokens = ['fake-first', 'fake-refreshed'];
        final observed = <String>[];
        final apis = <FakeApi>[];
        var loads = 0;
        for (var i = 0; i < 2; i++) {
          await ar.runOnce(
            args,
            loadToken: (path, expected) {
              expect(path, args.auth);
              expect(expected, args.accountId);
              return tokens[loads++];
            },
            apiFactory: (token, account) {
              observed.add(token);
              expect(account, args.accountId);
              final api = FakeApi([0]);
              apis.add(api);
              return api;
            },
            localFactory: () => throw StateError('Local state forbidden'),
            clock: FakeClock(),
            output: (_) {},
            stopping: () => false,
          );
        }
        expect(loads, 2);
        expect(observed, tokens);
        expect(apis.every((api) => !api.posted), isTrue);
      },
    );
    test('invalid synthetic auth prevents API construction', () async {
      var constructed = false;
      await expectLater(
        ar.runOnce(
          args,
          loadToken: (_, __) => throw ar.Refusal('Invalid local auth'),
          apiFactory: (_, __) {
            constructed = true;
            return FakeApi();
          },
          localFactory: () => throw StateError('Local state forbidden'),
          clock: FakeClock(),
          output: (_) {},
          stopping: () => false,
        ),
        refusal,
      );
      expect(constructed, isFalse);
    });
  });
  group('Pure CLI background arguments', () {
    ar.Options options(List<String> extras) =>
        ar.parseOptions(['--account-id', 'synthetic-account', ...extras]);
    List<String> childCommand(
      ar.Options args,
      String handshake,
      String token, {
      String executable = '/synthetic/dart',
      String script = '/synthetic/bin/autoreset.dart',
    }) => ar.backgroundCommand(
      args,
      handshake,
      token,
      executable: executable,
      script: script,
      operatingSystem: 'linux',
      currentDirectory: '/synthetic/cwd',
      environment: const {'HOME': '/synthetic/home'},
    );
    String value(List<String> command, String flag) =>
        command[command.indexOf(flag) + 1];
    test('source child includes Dart entrypoint exactly once', () {
      final command = childCommand(
        options([]),
        '/synthetic/handshake',
        'synthetic-token',
        executable: '/synthetic/dart',
        script: '/synthetic/bin/autoreset.dart',
      );
      expect(command.take(2), [
        '/synthetic/dart',
        '/synthetic/bin/autoreset.dart',
      ]);
      expect(
        command.where((arg) => arg == '/synthetic/bin/autoreset.dart'),
        hasLength(1),
      );
    });
    test('compiled child never passes its binary as an entrypoint', () {
      final command = childCommand(
        options([]),
        '/synthetic/handshake',
        'synthetic-token',
        executable: '/synthetic/autoreset',
        script: '/synthetic/autoreset',
      );
      expect(command.first, '/synthetic/autoreset');
      expect(command[1], '--foreground');
      expect(
        command.where((arg) => arg == '/synthetic/autoreset'),
        hasLength(1),
      );
    });
    test('Windows child expands auth against injected user profile', () {
      const args = ar.Options(
        accountId: 'synthetic-account',
        auth: r'~\.codex\auth.json',
      );
      final command = ar.backgroundCommand(
        args,
        r'C:\Synthetic\ready',
        'synthetic-token',
        executable: r'C:\Synthetic\autoreset.exe',
        script: r'C:\Synthetic\autoreset.exe',
        operatingSystem: 'windows',
        currentDirectory: r'C:\Synthetic\cwd',
        environment: const {'USERPROFILE': r'C:\Synthetic\User'},
      );
      expect(command.first, r'C:\Synthetic\autoreset.exe');
      expect(command[1], '--foreground');
      expect(value(command, '--auth'), r'C:\Synthetic\User\.codex\auth.json');
      expect(command, contains('--dry-run'));
    });
    test('background defaults are read only and uncapped', () {
      final args = options(['--background']);
      expect(args.background, isTrue);
      expect(args.execute, isFalse);
      expect(args.maxResets, isNull);
    });
    test('child retains auth cap and explicit dry run', () {
      final args = options([
        '--background',
        '--auth',
        '/synthetic/auth.json',
        '--max-resets',
        '1',
      ]);
      final command = childCommand(
        args,
        '/synthetic/handshake',
        'synthetic-token',
      );
      expect(command, contains('--foreground'));
      expect(command, isNot(contains('--background')));
      expect(command, contains('--dry-run'));
      expect(command, isNot(contains('--execute')));
      expect(value(command, '--auth'), '/synthetic/auth.json');
      expect(value(command, '--max-resets'), '1');
    });
    test('live child requires explicit execute', () {
      final command = childCommand(
        options(['--execute', '--auth', '/synthetic/jcode-auth.json']),
        '/synthetic/handshake',
        'synthetic-token',
      );
      expect(command, contains('--execute'));
      expect(command, isNot(contains('--dry-run')));
      expect(value(command, '--auth'), '/synthetic/jcode-auth.json');
    });
    test('uncapped child omits budget and null string', () {
      final command = childCommand(
        options([]),
        '/synthetic/handshake',
        'synthetic-token',
      );
      expect(command, isNot(contains('--max-resets')));
      expect(command, isNot(contains('null')));
      expect(command, contains('--dry-run'));
    });
    test('explicit background budget preserved', () {
      expect(options(['--background', '--max-resets', '2']).maxResets, 2);
    });
    test('invalid explicit budgets refused', () {
      for (final value in [
        '0',
        '-1',
        '101',
        '1.5',
        'NaN',
        '999999999999999999999999',
      ]) {
        expect(() => options(['--background', '--max-resets', value]), refusal);
      }
    });
    test('conflicting modes and unknown options refused', () {
      for (final extras in [
        ['--execute', '--dry-run'],
        ['--foreground', '--background'],
        ['--unknown-option'],
      ]) {
        expect(() => options(extras), refusal);
      }
    });
    test('foreground remains read only', () {
      final args = options(['--foreground']);
      expect(args.foreground, isTrue);
      expect(args.background, isFalse);
      expect(args.execute, isFalse);
    });
    test('child auth spelling is retained without symlink resolution', () {
      final command = childCommand(
        options(['--auth', '/synthetic/link-auth.json']),
        '/synthetic/handshake',
        'synthetic-token',
      );
      expect(value(command, '--auth'), '/synthetic/link-auth.json');
    });
  });
}
