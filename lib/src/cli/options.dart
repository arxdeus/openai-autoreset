import 'dart:io';

import 'package:openai_autoreset/src/core/refusal.dart';
import 'package:openai_autoreset/src/state/paths.dart';
import 'package:path/path.dart' as p;

class Options {
  final String accountId;
  final String auth;
  final bool execute;
  final bool background;
  final bool foreground;
  final int? maxResets;
  final String? workerHandshake;
  final String? workerToken;
  final bool help;
  const Options({
    required this.accountId,
    required this.auth,
    this.execute = false,
    this.background = false,
    this.foreground = false,
    this.maxResets,
    this.workerHandshake,
    this.workerToken,
    this.help = false,
  });
}

const _bareFlags = {
  '--execute',
  '--dry-run',
  '--background',
  '--foreground',
  '--help',
  '-h',
};

bool _accountRejected(String? account, int? maxResets) {
  final missing = account == null || account.isEmpty;
  final unsafe = account != null && account.contains(RegExp(r'[\r\n\x00]'));
  final budget = maxResets != null && (maxResets < 1 || maxResets > 100);
  return missing || unsafe || budget;
}

bool _workerRejected({
  required String? handshake,
  required String? token,
  required bool foreground,
  required bool background,
}) {
  if ((handshake == null) != (token == null)) return true;
  if (handshake == null) return false;
  final misplaced = !foreground || background;
  final badPath = handshake.isEmpty || !p.isAbsolute(handshake);
  final badToken = token == null || !RegExp(r'^[a-f0-9-]{36}$').hasMatch(token);
  return misplaced || badPath || badToken;
}

Options parseOptions(List<String> arguments) {
  String? account;
  var auth = defaultAuth;
  var execute = false,
      dry = false,
      background = false,
      foreground = false,
      help = false;
  int? maxResets;
  String? handshake, token;
  final seen = <String>{};
  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    final equals = argument.indexOf('=');
    final key = equals < 0 ? argument : argument.substring(0, equals);
    if (!seen.add(key)) throw const Refusal('Duplicate command-line option.');
    String value() {
      if (equals >= 0) return argument.substring(equals + 1);
      if (++i >= arguments.length || arguments[i].startsWith('--'))
        throw const Refusal('Missing command-line option value.');
      return arguments[i];
    }

    switch (key) {
      case '--execute':
        execute = true;
      case '--dry-run':
        dry = true;
      case '--background':
        background = true;
      case '--foreground':
        foreground = true;
      case '--help':
      case '-h':
        help = true;
      case '--account-id':
        account = value();
      case '--auth':
        auth = value();
      case '--max-resets':
        final raw = value();
        if (!RegExp(r'^[+-]?\d+$').hasMatch(raw) ||
            (maxResets = int.tryParse(raw)) == null)
          throw const Refusal('Invalid reset-attempt budget.');
      case '--worker-handshake':
        handshake = value();
      case '--worker-token':
        token = value();
      default:
        throw const Refusal('Unknown command-line option.');
    }
    if (equals >= 0 && _bareFlags.contains(key)) {
      throw const Refusal('Flag does not accept a value.');
    }
  }
  if ((execute && dry) || (background && foreground)) {
    throw const Refusal('Mutually exclusive command-line options.');
  }
  if (!help && _accountRejected(account, maxResets)) {
    throw const Refusal(
      'Account ID required. An optional reset-attempt budget must be 1-100.',
    );
  }
  if (_workerRejected(
    handshake: handshake,
    token: token,
    foreground: foreground,
    background: background,
  )) {
    throw const Refusal('Invalid internal background readiness arguments.');
  }
  if (auth.isEmpty || auth.contains('\u0000'))
    throw const Refusal('Invalid auth path.');
  return Options(
    accountId: account ?? '',
    auth: expandHome(auth),
    execute: execute,
    background: background,
    foreground: foreground,
    maxResets: maxResets,
    workerHandshake: handshake,
    workerToken: token,
    help: help,
  );
}

const usageText = '''Opt-in Codex reset-credit automation. Default: read-only.
Usage: openai-autoreset --account-id ACCOUNT [--auth PATH] [--execute | --dry-run]
                        [--background | --foreground] [--max-resets 1-100]
--execute       ALLOW spending a banked reset, only at 0%-1% weekly remaining
--dry-run       Read only (the default)
--background    Detach and check every 60 seconds
--foreground    Check every 60 seconds without detaching
--auth PATH     OAuth store (default ~/.codex/auth.json)
--max-resets N  Optional lifetime reset-attempt budget. Omit for no cap.
Stop all Python monitors/checkers/launchd jobs before migrating. Locks differ.
''';

List<String> backgroundCommand(
  Options args,
  String handshake,
  String token, {
  String? executable,
  String? script,
  String? operatingSystem,
  String? currentDirectory,
  Map<String, String>? environment,
}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  final paths = pathContext(os, current: currentDirectory);
  var auth = args.auth;
  if (auth == '~' || auth.startsWith('~/') || auth.startsWith('~\\')) {
    final selectedHome = homeFor(
      operatingSystem: os,
      environment: environment ?? Platform.environment,
    );
    auth =
        auth == '~'
            ? selectedHome
            : paths.join(selectedHome, auth.substring(2));
  }
  final entry = script ?? Platform.script.toFilePath();
  return [
    executable ?? Platform.resolvedExecutable,
    if (entry.endsWith('.dart') || entry.endsWith('.snapshot')) entry,
    '--foreground',
    '--worker-handshake',
    handshake,
    '--worker-token',
    token,
    '--account-id',
    args.accountId,
    '--auth',
    paths.absolute(auth),
    args.execute ? '--execute' : '--dry-run',
    if (args.maxResets != null) ...['--max-resets', '${args.maxResets}'],
  ];
}
