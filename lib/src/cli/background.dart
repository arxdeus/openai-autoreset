import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:openai_autoreset/src/api/auth.dart';
import 'package:openai_autoreset/src/cli/options.dart';
import 'package:openai_autoreset/src/cli/poll.dart';
import 'package:openai_autoreset/src/core/clock.dart';
import 'package:openai_autoreset/src/core/limits.dart';
import 'package:openai_autoreset/src/core/refusal.dart';
import 'package:openai_autoreset/src/state/journal.dart';
import 'package:path/path.dart' as p;

class _StopSignals {
  bool stopped = false;
  bool interrupted = false;
  final Completer<void> _done = Completer<void>();
  final List<StreamSubscription<ProcessSignal>> subscriptions = [];
  _StopSignals({bool detached = false}) {
    if (Platform.isWindows && detached) return;
    for (final signal in [
      ProcessSignal.sigint,
      if (!Platform.isWindows) ProcessSignal.sigterm,
    ]) {
      subscriptions.add(
        signal.watch().listen((_) {
          stopped = true;
          if (signal == ProcessSignal.sigint) interrupted = true;
          if (!_done.isCompleted) _done.complete();
        }),
      );
    }
  }
  Future<void> wait(Duration duration) async {
    Timer? timer;
    final timeout = Completer<void>();
    try {
      timer = Timer(duration, timeout.complete);
      await Future.any([timeout.future, _done.future]);
    } finally {
      timer?.cancel();
    }
  }

  Future<void> close() async {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }
}

bool validReadyMessage(String message, String token, int workerPid) =>
    message == 'READY $token $workerPid\n';

String? _readReadyFile(String path) {
  validateLocalPath(path, directory: false, missingAllowed: true);
  final file = File(path);
  if (!file.existsSync()) return null;
  if (file.lengthSync() > maxReadyBytes)
    throw const Refusal('Invalid background readiness message.');
  final message = file.readAsStringSync();
  validateLocalPath(path, directory: false);
  return message;
}

void _publishReady(String directory, String name, String text) {
  validateLocalPath(directory, directory: true);
  final temporary = File(p.join(directory, '$name-${randomId()}'));
  final destination = p.join(directory, name);
  validateLocalPath(destination, directory: false, missingAllowed: true);
  final handle = temporary.openSync(mode: FileMode.writeOnly);
  try {
    handle.writeStringSync(text);
    handle.flushSync();
  } finally {
    handle.closeSync();
  }
  temporary.renameSync(destination);
}

Future<void> _workerReady(Options args, _StopSignals signals) async {
  final directory = args.workerHandshake!;
  validateLocalPath(directory, directory: true);
  _publishReady(directory, 'ready', 'READY ${args.workerToken} $pid\n');
  final deadline = Stopwatch()..start();
  while (!signals.stopped && deadline.elapsed < handshakeLimit) {
    validateLocalPath(directory, directory: true);
    final ack = _readReadyFile(p.join(directory, 'ack'));
    if (ack != null) {
      if (ack != 'ACK ${args.workerToken}\n')
        throw const Refusal('Background readiness was not accepted.');
      _publishReady(directory, 'received', 'RECEIVED ${args.workerToken}\n');
      return;
    }
    await signals.wait(handshakeInterval);
  }
  throw const Refusal(
    'Background readiness was not accepted. No API request sent.',
  );
}

Future<int> pollForever(Options args) async {
  final local = LocalState();
  IOSink? log;
  Object? logFailure;
  StateLock? backgroundLock;
  _StopSignals? signals;
  void printLine(String text) {
    if (logFailure != null) throw const Refusal(logIoFailure);
    if (log != null) {
      log.writeln(text);
      return;
    }
    Log.logStatus(text);
  }

  try {
    if (args.workerHandshake != null) {
      log = local.openLog();
      unawaited(
        log.done.catchError((Object error) {
          logFailure = error;
        }),
      );
      await log.flush();
    }
    backgroundLock = local.lock('background.lock');
    signals = _StopSignals(detached: args.workerHandshake != null);
    final stop = signals;
    await localStartup(
      authCheck: () {
        loadAuth(args.auth, args.accountId);
      },
      stateCheck:
          args.execute
              ? () {
                final lock = local.lock();
                try {
                  local.read(accountHash(args.accountId));
                } finally {
                  lock.close();
                }
              }
              : null,
      ready:
          args.workerHandshake == null ? null : () => _workerReady(args, stop),
    );
    printLine('Polling every $pollSeconds seconds. PID: $pid');
    await log?.flush();
    await pollLoop(
      run: () async {
        if (logFailure != null) throw const Refusal(logIoFailure);
        await runOnce(
          args,
          stopping: () => stop.stopped || logFailure != null,
          output: printLine,
        );
        await log?.flush();
      },
      stopping: () => stop.stopped || logFailure != null,
      wait: stop.wait,
      output: printLine,
      afterPoll: () async {
        await log?.flush();
      },
      onError: (error) {
        printLine(errorMessage(error));
      },
    );
    printLine('Background monitor stopped.');
    return stop.interrupted ? interruptedStatus : 0;
  } catch (error) {
    if (log != null && logFailure == null) {
      log.writeln(errorMessage(error));
      await log.flush();
    }
    rethrow;
  } finally {
    if (signals != null) await signals.close();
    backgroundLock?.close();
    if (log != null) await log.close();
  }
}

Future<void> launchBackground(Options args) async {
  final local = LocalState();
  Directory? readyDirectory;
  Process? child;
  var accepted = false;
  try {
    final log = local.openLog();
    await log.flush();
    await log.close();
    readyDirectory = Directory(local.path).createTempSync('ready-');
    validateLocalPath(readyDirectory.path, directory: true);
    final token = randomId();
    final command = backgroundCommand(args, readyDirectory.path, token);
    Log.logTrace(
      ProcessRunner.commandLine(command.first, command.skip(1).toList()),
    );
    child = await Process.start(
      command.first,
      command.skip(1).toList(),
      mode: ProcessStartMode.detached,
    );
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < handshakeLimit) {
      validateLocalPath(readyDirectory.path, directory: true);
      final message = _readReadyFile(p.join(readyDirectory.path, 'ready'));
      if (message != null) {
        if (!validReadyMessage(message, token, child.pid))
          throw const Refusal('Invalid background readiness message.');
        // The parent accepts local startup before publishing permission for
        // the first authenticated request. Worker remains blocked until ACK.
        accepted = true;
        _publishReady(readyDirectory.path, 'ack', 'ACK $token\n');
        break;
      }
      await Future<void>.delayed(handshakeInterval);
    }
    if (!accepted)
      throw const Refusal(
        'Background monitor did not start. Check background.log. No automatic retry.',
      );
    // Do not remove the ACK before the worker has consumed it.
    while (deadline.elapsed < handshakeLimit) {
      final received = _readReadyFile(p.join(readyDirectory.path, 'received'));
      if (received == 'RECEIVED $token\n') break;
      await Future<void>.delayed(handshakeInterval);
    }
    if (_readReadyFile(p.join(readyDirectory.path, 'received')) !=
        'RECEIVED $token\n') {
      throw const Refusal('Background readiness acknowledgement failed.');
    }
    Log.logDone(
      'Background monitor started. PID: ${child.pid}. Log: ${p.join(local.path, 'background.log')}',
    );
    Log.logStatus(
      'To stop, verify this PID still belongs to autoreset, then use your OS process tools.',
    );
  } catch (_) {
    if (child != null) {
      try {
        await ProcessRunner.killTree(child);
      } on Object {
        // Keep the start-failure message if cleanup itself fails.
      }
    }
    throw const Refusal(
      'Background monitor did not start. Check background.log. No automatic retry.',
    );
  } finally {
    if (readyDirectory != null && readyDirectory.existsSync()) {
      // Delete only our one-use directory, never journals or locks.
      validateLocalPath(readyDirectory.path, directory: true);
      readyDirectory.deleteSync(recursive: true);
    }
  }
}

Future<int> mainEntry(List<String> arguments) async {
  try {
    final args = parseOptions(arguments);
    if (args.help) {
      final lines = usageText.split('\n');
      if (lines.last.isEmpty) lines.removeLast();
      for (final line in lines) {
        Log.logStatus(line);
      }
      return 0;
    }
    if (args.background) {
      await launchBackground(args);
    } else if (args.foreground) {
      return await pollForever(args);
    } else {
      final signals = _StopSignals();
      try {
        await runOnce(args, stopping: () => signals.stopped);
      } catch (error) {
        if (signals.interrupted) return interruptedStatus;
        rethrow;
      } finally {
        await signals.close();
      }
      if (signals.interrupted) return interruptedStatus;
    }
    return 0;
  } catch (error) {
    reportError(error);
    return 2;
  }
}
