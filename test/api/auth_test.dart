import 'package:openai_autoreset/autoreset.dart' as ar;
import 'package:test/test.dart';

import '../support/fixtures.dart';

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
}
