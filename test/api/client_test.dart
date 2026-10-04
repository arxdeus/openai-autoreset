import 'package:openai_autoreset/autoreset.dart' as ar;
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
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
}
