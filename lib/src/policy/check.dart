import 'dart:math';

import 'package:cli_kit/cli_kit.dart';
import 'package:openai_autoreset/src/api/client.dart';
import 'package:openai_autoreset/src/api/usage.dart';
import 'package:openai_autoreset/src/core/clock.dart';
import 'package:openai_autoreset/src/core/limits.dart';
import 'package:openai_autoreset/src/core/refusal.dart';
import 'package:openai_autoreset/src/state/journal.dart';

bool preflightStale(
  Clock clock,
  double checkedAt,
  double checkedWall,
  num boundary,
) {
  final now = clock.wall();
  final elapsed = now - checkedWall;
  final monotonicDrift = clock.monotonic() - checkedAt > preflightSeconds;
  final wallDrift = elapsed < 0 || elapsed > preflightSeconds;
  final resetSoon = boundary - now <= fiveMinutes;
  return monotonicDrift || wallDrift || resetSoon;
}

List<dynamic> _executableAttempts(
  Map<String, dynamic>? state,
  StateStore? store,
  Clock clock,
  int? maxResets,
) {
  if (state == null || store == null || state['attempts'] is! List) {
    throw const Refusal('Execution requires a locked state journal.');
  }
  final attempts = state['attempts'] as List;
  if (attempts.any((attempt) => attempt['status'] == 'pending')) {
    throw const Refusal(
      'Unresolved reset attempt. Check the dashboard and journal manually. No retry.',
    );
  }
  if (maxResets != null && attempts.length >= maxResets) {
    throw const Refusal('Configured lifetime reset-attempt budget reached.');
  }
  if (attempts.isNotEmpty) {
    final latest = attempts
        .map((attempt) => number(attempt['time']))
        .reduce(max);
    if (clock.wall() - latest < sixHours) {
      throw const Refusal('Six-hour reset cooldown is active.');
    }
  }
  return attempts;
}

Future<void> _dropUnsent(
  List<dynamic> journal,
  StateStore store,
  Map<String, dynamic> state,
) async {
  journal.removeLast();
  await store.save(state);
}

/// Persist pending BEFORE the sole POST, never retry it, and only unblock after
/// explicit consumed inventory AND recovered quota. A failed/ambiguous POST
/// leaves pending permanently. Rollback is permitted only before entering POST.
Future<void> check(
  Api api, {
  required bool execute,
  int? maxResets,
  Map<String, dynamic>? state,
  StateStore? store,
  Clock? clock,
  bool Function()? stopping,
  void Function(String)? output,
  String Function()? requestId,
}) async {
  final time = clock ?? SystemClock();
  final stop = stopping ?? () => false;
  final printLine = output ?? Log.logStatus;
  if (stop())
    throw const Refusal('Monitor is stopping. No new reset requested.');
  final usage = weekly(await api.request('usage'), time.wall());
  printLine('Weekly remaining: ${usage.remaining}%');
  requireThreshold(usage.remaining);
  if (usage.resetAt - time.wall() <= fiveMinutes) {
    throw const Refusal(
      'Natural weekly reset is within five minutes. Save the reset credit.',
    );
  }
  final attempts =
      execute ? _executableAttempts(state, store, time, maxResets) : null;
  final credits = availableCredits(
    await api.request(creditsEndpoint),
    time.wall(),
  );
  if (credits.isEmpty) {
    throw const Refusal(
      'No eligible, unexpired banked reset credit available.',
    );
  }
  final creditId = credits.first.id;
  if (!execute) {
    printLine('DRY RUN: eligible at 0%-1% remaining. No reset requested.');
    return;
  }
  final journal = attempts!;
  final recorded = store!;
  final journalState = state!;
  if (journal.any((attempt) => attempt['credit_id'] == creditId)) {
    throw const Refusal(
      'Selected credit has already been attempted. No retry.',
    );
  }
  final stillListed = availableCredits(
    await api.request(creditsEndpoint),
    time.wall(),
  ).any((credit) => credit.id == creditId);
  if (!stillListed) {
    throw const Refusal('Selected credit is no longer available.');
  }
  final checkedAt = time.monotonic();
  final checkedWall = time.wall();
  final finalUsage = weekly(await api.request('usage'), time.wall());
  requireThreshold(finalUsage.remaining);
  final sameWindow = usage.resetAt == finalUsage.resetAt;
  final resetImminent = finalUsage.resetAt - time.wall() <= fiveMinutes;
  if (!sameWindow || resetImminent) {
    throw const Refusal(
      'Weekly window changed or is about to reset. No credit spent.',
    );
  }
  if (preflightStale(time, checkedAt, checkedWall, finalUsage.resetAt)) {
    throw const Refusal(
      'Preflight reading became stale. No request sent or attempt recorded.',
    );
  }
  // Deliver queued SIGINT/SIGTERM events before recording intent.
  await Future<void>.delayed(Duration.zero);
  if (stop()) {
    throw const Refusal(
      'Monitor is stopping. No request sent or attempt recorded.',
    );
  }
  final attempt = <String, dynamic>{
    'credit_id': creditId,
    'request_id': (requestId ?? randomId)(),
    'time': time.wall(),
    'status': 'pending',
  };
  journal.add(attempt);
  await recorded.save(journalState);
  await Future<void>.delayed(Duration.zero);
  final staleOrStopping =
      preflightStale(time, checkedAt, checkedWall, finalUsage.resetAt) ||
      stop();
  if (staleOrStopping) {
    await _dropUnsent(journal, recorded, journalState);
    throw const Refusal(
      'Preflight became stale or monitor is stopping. No request sent; unsent intent cancelled.',
    );
  }
  requireThreshold(finalUsage.remaining);
  final body = <String, dynamic>{
    'credit_id': creditId,
    'redeem_request_id': attempt['request_id'],
  };
  bool permit() =>
      !stop() &&
      !preflightStale(time, checkedAt, checkedWall, finalUsage.resetAt);
  try {
    if (api is GuardedApi) {
      await api.consume(body, permit: permit);
    } else {
      await api.request('$creditsEndpoint/consume', body: body);
    }
  } on ConsumeNotSent {
    await _dropUnsent(journal, recorded, journalState);
    rethrow;
  }
  await time.sleep(verifyPause);
  final afterUsage = weekly(await api.request('usage'), time.wall());
  final after = await api.request(creditsEndpoint);
  availableCredits(after, time.wall());
  final entries =
      (after['credits'] as List)
          .where((credit) => credit['id'] == creditId)
          .toList();
  final consumed =
      entries.length == 1 && entries.single['status'] == 'consumed';
  if (afterUsage.remaining <= 1 || !consumed) {
    throw const Refusal(
      'Reset outcome not verified. Journal remains blocked. Inspect dashboard, do not retry.',
    );
  }
  attempt['status'] = 'verified';
  await recorded.save(journalState);
  printLine(
    'Reset verified by recovered weekly quota and consumed credit. One credit spent.',
  );
}
