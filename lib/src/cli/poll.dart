import 'dart:io';
import 'dart:math';

import 'package:cli_kit/cli_kit.dart';
import 'package:openai_autoreset/src/api/auth.dart';
import 'package:openai_autoreset/src/api/client.dart';
import 'package:openai_autoreset/src/cli/options.dart';
import 'package:openai_autoreset/src/core/clock.dart';
import 'package:openai_autoreset/src/core/limits.dart';
import 'package:openai_autoreset/src/core/refusal.dart';
import 'package:openai_autoreset/src/policy/check.dart';
import 'package:openai_autoreset/src/state/journal.dart';

String errorMessage(Object error) => switch (error) {
  Refusal(:final message) => message,
  CliError(:final message) => message,
  _ => 'Local I/O failure. Reset automation stopped.',
};
void reportError(Object error) => Log.logError(errorMessage(error));

/// Injection of credentials/API is intended for synthetic polling tests. Real
/// invocations reload only the pinned local store, without any refresh flow.
Future<void> runOnce(
  Options args, {
  Clock? clock,
  bool Function()? stopping,
  String Function(String, String)? loadToken,
  Api Function(String, String)? apiFactory,
  LocalState Function()? localFactory,
  void Function(String)? output,
}) async {
  final token = (loadToken ?? loadAuth)(args.auth, args.accountId);
  final api = (apiFactory ?? HttpApi.new)(token, args.accountId);
  if (!args.execute) {
    await check(
      api,
      execute: false,
      maxResets: args.maxResets,
      clock: clock,
      stopping: stopping,
      output: output,
    );
    return;
  }
  final local = (localFactory ?? LocalState.new)();
  final lock = local.lock();
  try {
    final hash = accountHash(args.accountId);
    await check(
      api,
      execute: true,
      maxResets: args.maxResets,
      state: local.read(hash),
      store: local.store(hash),
      clock: clock,
      stopping: stopping,
      output: output,
    );
  } finally {
    lock.close();
  }
}

Future<void> localStartup({
  required void Function() authCheck,
  void Function()? stateCheck,
  Future<void> Function()? ready,
}) async {
  authCheck();
  stateCheck?.call();
  if (ready != null) await ready();
}

Future<void> pollLoop({
  required Future<void> Function() run,
  required bool Function() stopping,
  Clock? clock,
  Future<void> Function(Duration)? wait,
  void Function(String)? output,
  void Function(Object)? onError,
  Future<void> Function()? afterPoll,
}) async {
  final time = clock ?? SystemClock();
  final printLine = output ?? Log.logStatus;
  while (!stopping()) {
    final started = time.monotonic();
    printLine(
      DateTime.fromMicrosecondsSinceEpoch(
        (time.wall() * 1000000).round(),
      ).toLocal().toIso8601String(),
    );
    try {
      await run();
    } on Refusal catch (error) {
      (onError ?? reportError)(error);
    } on FileSystemException catch (error) {
      (onError ?? reportError)(error);
    }
    if (afterPoll != null) await afterPoll();
    if (stopping()) break;
    final delay = max(0.0, pollSeconds - (time.monotonic() - started));
    await (wait ?? time.sleep)(
      Duration(microseconds: (delay * 1000000).round()),
    );
  }
}
