import 'package:openai_autoreset/autoreset.dart' as ar;
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
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
  });
}
