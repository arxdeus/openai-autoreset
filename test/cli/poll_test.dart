import 'dart:async';

import 'package:openai_autoreset/autoreset.dart' as ar;
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
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
}
