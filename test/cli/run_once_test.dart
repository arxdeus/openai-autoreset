import 'package:openai_autoreset/autoreset.dart' as ar;
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
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
}
