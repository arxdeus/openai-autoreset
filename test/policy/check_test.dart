import 'dart:async';

import 'package:openai_autoreset/autoreset.dart' as ar;
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  group('Preflight', () {
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
}
