/// Conservative reset policy and portable pure-Dart persistence.
///
/// Tests should inject [Api], [Clock], [StateStore], stopping, output and
/// requestId into [check]. None of these seams require real OAuth or disk I/O.
library;

export 'src/api/auth.dart';
export 'src/api/client.dart';
export 'src/api/usage.dart';
export 'src/cli/background.dart';
export 'src/cli/options.dart';
export 'src/cli/poll.dart';
export 'src/core/clock.dart';
export 'src/core/limits.dart';
export 'src/core/refusal.dart';
export 'src/policy/check.dart';
export 'src/state/journal.dart';
export 'src/state/paths.dart' hide pathContext;
