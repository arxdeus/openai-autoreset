import 'package:openai_autoreset/src/core/limits.dart';
import 'package:openai_autoreset/src/core/refusal.dart';

class WeeklyUsage {
  final num remaining;
  final num resetAt;
  const WeeklyUsage(this.remaining, this.resetAt);
}

WeeklyUsage weekly(Object? data, num now) {
  if (data is! Map || data['rate_limit'] is! Map) {
    throw const Refusal('Unknown usage response schema.');
  }
  final rate = data['rate_limit'] as Map;
  final candidates = <Map>[];
  for (final name in ['primary_window', 'secondary_window']) {
    final window = rate[name];
    if (window is Map && window['limit_window_seconds'] == week) {
      candidates.add(window);
    }
  }
  if (candidates.length != 1) {
    throw const Refusal('Expected exactly one general seven-day usage window.');
  }
  final window = candidates.single;
  final used = number(window['used_percent']);
  final reset = number(window['reset_at']);
  final withinWeek = reset > now && reset <= now + week + fiveMinutes;
  if (used < 0 || used > 100 || !withinWeek) {
    throw const Refusal('Invalid or expired weekly usage window.');
  }
  return WeeklyUsage(100 - used, reset);
}

void requireThreshold(num remaining) {
  if (number(remaining) < 0 || remaining > 1) {
    throw Refusal(
      'WARNING: weekly remaining is $remaining%, above 1%. Reset refused.',
    );
  }
}

class AvailableCredit {
  final double expiresAt;
  final String id;
  const AvailableCredit(this.expiresAt, this.id);
}

// DateTime.parse accepts naive timestamps and overflowed calendar fields.
final _zonedTimestamp = RegExp(r'(?:Z|[+-]\d{2}:?\d{2})$');
final _offsetClock = RegExp(r'[+-](\d{2}):?(\d{2})$');
final _timestampFields = RegExp(
  r'^\d{4}-?(\d{2})-?(\d{2})[Tt ](\d{2}):?(\d{2}):?(\d{2})',
);

double? _expirySeconds(Object? raw) {
  if (raw is! String || !_zonedTimestamp.hasMatch(raw)) return null;
  var expiry = DateTime.tryParse(raw);
  final offset = _offsetClock.firstMatch(raw);
  if (offset != null &&
      (int.parse(offset.group(1)!) > 23 || int.parse(offset.group(2)!) > 59)) {
    expiry = null;
  }
  final fields = _timestampFields.firstMatch(raw);
  if (fields == null || _timestampOverflows(raw, fields)) expiry = null;
  return expiry == null ? null : expiry.microsecondsSinceEpoch / 1000000;
}

bool _timestampOverflows(String raw, RegExpMatch fields) {
  final month = int.parse(fields.group(1)!);
  final day = int.parse(fields.group(2)!);
  final hour = int.parse(fields.group(3)!);
  final minute = int.parse(fields.group(4)!);
  final second = int.parse(fields.group(5)!);
  final year = int.parse(raw.substring(0, 4));
  final maxDay =
      month >= 1 && month <= 12 ? DateTime.utc(year, month + 1, 0).day : 0;
  return day < 1 || day > maxDay || hour > 23 || minute > 59 || second > 59;
}

List<AvailableCredit> availableCredits(Object? data, num now) {
  if (data is! Map || data['credits'] is! List) {
    throw const Refusal('Unknown reset-credit response schema.');
  }
  final count = data['available_count'];
  if (count is! int || count < 0) {
    throw const Refusal('Unknown reset-credit count.');
  }
  final result = <AvailableCredit>[];
  final seen = <String>{};
  for (final credit in data['credits'] as List) {
    if (credit is! Map) throw const Refusal('Malformed reset-credit entry.');
    if (credit['status'] != 'available') continue;
    final id = credit['id'];
    if (id is! String || id.isEmpty || !seen.add(id)) {
      throw const Refusal('Missing or duplicate available credit ID.');
    }
    final seconds = _expirySeconds(credit['expires_at']);
    if (seconds == null) throw const Refusal('Unknown reset-credit expiry.');
    final eligible =
        credit['reset_type'] == 'codex_rate_limits' &&
        seconds > now + creditGraceSeconds;
    if (eligible) result.add(AvailableCredit(seconds, id));
  }
  if (seen.length != count) {
    throw const Refusal('Reset-credit inventory and available count disagree.');
  }
  result.sort((a, b) {
    final byExpiry = a.expiresAt.compareTo(b.expiresAt);
    return byExpiry == 0 ? a.id.compareTo(b.id) : byExpiry;
  });
  return result;
}
