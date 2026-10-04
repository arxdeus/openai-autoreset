/// Conservative reset policy and portable pure-Dart persistence.
///
/// Tests should inject [Api], [Clock], [StateStore], stopping, output and
/// requestId into [check]. None of these seams require real OAuth or disk I/O.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const base = 'https://chatgpt.com/backend-api/wham/';
const creditsEndpoint = 'rate-limit-reset-credits';
const week = 604800;
const pollSeconds = 60;

class Refusal implements Exception {
  final String message;
  const Refusal(this.message);
  @override
  String toString() => message;
}

num number(Object? value) {
  if (value is! num || !value.isFinite) {
    throw const Refusal('Missing or invalid numeric API field.');
  }
  return value;
}

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
  final used = number(candidates.single['used_percent']);
  final reset = number(candidates.single['reset_at']);
  if (used < 0 || used > 100 || reset <= now || reset > now + week + 300) {
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
    final raw = credit['expires_at'];
    DateTime? expiry;
    // DateTime.parse accepts naive dates and overflowed components. Reject both.
    if (raw is String && RegExp(r'(?:Z|[+-]\d{2}:?\d{2})$').hasMatch(raw)) {
      expiry = DateTime.tryParse(raw);
      final offset = RegExp(r'[+-](\d{2}):?(\d{2})$').firstMatch(raw);
      if (offset != null &&
          (int.parse(offset.group(1)!) > 23 ||
              int.parse(offset.group(2)!) > 59))
        expiry = null;
      final components = RegExp(
        r'^\d{4}-?(\d{2})-?(\d{2})[Tt ](\d{2}):?(\d{2}):?(\d{2})',
      ).firstMatch(raw);
      if (components == null) expiry = null;
      if (components != null) {
        final values = [
          for (var i = 1; i <= 5; i++) int.parse(components.group(i)!),
        ];
        final year = int.parse(raw.substring(0, 4));
        final maxDay =
            values[0] >= 1 && values[0] <= 12
                ? DateTime.utc(year, values[0] + 1, 0).day
                : 0;
        if (values[1] < 1 ||
            values[1] > maxDay ||
            values[2] > 23 ||
            values[3] > 59 ||
            values[4] > 59)
          expiry = null;
      }
    }
    if (expiry == null) throw const Refusal('Unknown reset-credit expiry.');
    final seconds = expiry.microsecondsSinceEpoch / 1000000;
    if (credit['reset_type'] == 'codex_rate_limits' && seconds > now + 60) {
      result.add(AvailableCredit(seconds, id));
    }
  }
  if (seen.length != count) {
    throw const Refusal('Reset-credit inventory and available count disagree.');
  }
  result.sort((a, b) {
    final expiry = a.expiresAt.compareTo(b.expiresAt);
    return expiry == 0 ? a.id.compareTo(b.id) : expiry;
  });
  return result;
}

String authToken(Object? data, String expected) {
  if (data is! Map) throw const Refusal('Invalid OAuth credential store.');
  Object? tokens;
  if (data.containsKey('openai_accounts')) {
    final accounts = data['openai_accounts'];
    if (accounts is! List || accounts.any((a) => a is! Map)) {
      throw const Refusal('Invalid Jcode OpenAI account list.');
    }
    final matches =
        accounts.where((a) => (a as Map)['account_id'] == expected).toList();
    if (matches.length != 1) {
      throw const Refusal(
        'Pinned account must match exactly one Jcode OpenAI account.',
      );
    }
    tokens = matches.single;
  } else {
    tokens = data.containsKey('tokens') ? data['tokens'] : data;
  }
  if (tokens is! Map ||
      tokens['access_token'] is! String ||
      (tokens['access_token'] as String).isEmpty ||
      tokens['account_id'] != expected) {
    throw const Refusal(
      'Missing OAuth token or account ID differs from --account-id.',
    );
  }
  final token = tokens['access_token'] as String;
  if ((token + expected).contains(RegExp(r'[\r\n]'))) {
    throw const Refusal('Invalid credential header.');
  }
  return token;
}

String loadAuth(String path, String expected) {
  try {
    final file = File(expandHome(path));
    if (FileSystemEntity.typeSync(file.path, followLinks: true) !=
        FileSystemEntityType.file) {
      throw const Refusal(
        'Cannot read OpenAI OAuth credentials. Sign in manually if needed.',
      );
    }
    // Credential symlinks are accepted for compatibility with explicitly
    // selected OAuth stores. Credentials are never modified by this tool.
    return authToken(jsonDecode(file.readAsStringSync()), expected);
  } on Refusal {
    rethrow;
  } catch (_) {
    throw const Refusal(
      'Cannot read OpenAI OAuth credentials. Sign in manually if needed.',
    );
  }
}

abstract interface class Api {
  Future<Map<String, dynamic>> request(
    String path, {
    Map<String, dynamic>? body,
  });
}

abstract interface class GuardedApi implements Api {
  Future<Map<String, dynamic>> consume(
    Map<String, dynamic> body, {
    required bool Function() permit,
  });
}

/// Raised only when transport proves no POST bytes were entered.
class ConsumeNotSent extends Refusal {
  const ConsumeNotSent()
    : super(
        'Preflight became stale or monitor is stopping. No request sent; unsent intent cancelled.',
      );
}

void validateResponseHeaders(int status, List<String>? ages) {
  if (status >= 300 && status < 400)
    throw const Refusal('HTTP redirect refused. No credentials forwarded.');
  if (status != 200)
    throw Refusal('HTTP $status. No retry. Check account manually.');
  if (ages != null && (ages.length != 1 || ages.single != '0'))
    throw const Refusal('Cached API response refused.');
}

/// A fresh direct client for each request eliminates reused-socket POST retries.
class HttpApi implements GuardedApi {
  final String token;
  final String account;
  HttpApi(this.token, this.account);
  @override
  Future<Map<String, dynamic>> request(
    String path, {
    Map<String, dynamic>? body,
  }) => _request(path, body: body);
  @override
  Future<Map<String, dynamic>> consume(
    Map<String, dynamic> body, {
    required bool Function() permit,
  }) => _request('$creditsEndpoint/consume', body: body, permit: permit);
  Future<Map<String, dynamic>> _request(
    String path, {
    Map<String, dynamic>? body,
    bool Function()? permit,
  }) async {
    if (![
      'usage',
      creditsEndpoint,
      '$creditsEndpoint/consume',
    ].contains(path)) {
      throw const Refusal('Endpoint not allowlisted.');
    }
    if ((body != null) != (path == '$creditsEndpoint/consume')) {
      throw const Refusal('Invalid endpoint/method pairing.');
    }
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    client.connectionTimeout = const Duration(seconds: 20);
    var cancelled = false;
    final deadline = Stopwatch()..start();
    try {
      return await (() async {
        final request = await client.openUrl(
          body == null ? 'GET' : 'POST',
          Uri.parse('$base$path'),
        );
        request.followRedirects = false;
        request.persistentConnection = false;
        if (body != null) {
          await Future<void>.delayed(Duration.zero);
          if (cancelled ||
              deadline.elapsed >= const Duration(seconds: 20) ||
              (permit != null && !permit())) {
            request.abort();
            throw const ConsumeNotSent();
          }
        }
        final headers = {
          'Authorization': 'Bearer $token',
          'ChatGPT-Account-ID': account,
          'Accept': 'application/json',
          'OpenAI-Beta': 'codex-1',
          'originator': 'Codex Desktop',
          'User-Agent': 'openai-autoreset/1.0',
          'Cache-Control': 'no-cache, no-store',
        };
        headers.forEach(request.headers.set);
        if (body != null) {
          request.headers.set('Content-Type', 'application/json');
          final payload = utf8.encode(jsonEncode(body));
          request.contentLength = payload.length;
          request.add(payload);
        }
        final response = await request.close();
        validateResponseHeaders(response.statusCode, response.headers['age']);
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 2000000)
            throw const Refusal('Oversized API response.');
          bytes.add(chunk);
        }
        final data = jsonDecode(utf8.decode(bytes.takeBytes()));
        if (data is! Map<String, dynamic>)
          throw const Refusal('Expected a JSON object.');
        return data;
      })().timeout(const Duration(seconds: 20));
    } on Refusal {
      rethrow;
    } catch (_) {
      throw const Refusal(
        'Network or JSON error. No retry. Check account manually.',
      );
    } finally {
      cancelled = true;
      client.close(force: true);
    }
  }
}

abstract interface class Clock {
  double wall();
  double monotonic();
  Future<void> sleep(Duration duration);
}

class SystemClock implements Clock {
  final Stopwatch _watch = Stopwatch()..start();
  @override
  double wall() => DateTime.now().microsecondsSinceEpoch / 1000000;
  @override
  double monotonic() => _watch.elapsedMicroseconds / 1000000;
  @override
  Future<void> sleep(Duration duration) => Future<void>.delayed(duration);
}

abstract interface class StateStore {
  Future<void> save(Map<String, dynamic> state);
}

String accountHash(String account) =>
    sha256.convert(utf8.encode(account)).toString();

Map<String, dynamic> validateState(Object? raw, String hash) {
  if (raw is! Map<String, dynamic> ||
      raw['version'] is! int ||
      raw['version'] != 1 ||
      raw['account'] != hash ||
      raw['attempts'] is! List) {
    throw const Refusal('Invalid state journal header.');
  }
  for (final item in raw['attempts'] as List) {
    if (item is! Map ||
        !['pending', 'verified'].contains(item['status']) ||
        item['credit_id'] is! String ||
        (item['credit_id'] as String).isEmpty ||
        item['request_id'] is! String ||
        (item['request_id'] as String).isEmpty) {
      throw const Refusal('Invalid state journal attempt.');
    }
    if (number(item['time']) <= 0)
      throw const Refusal('Invalid state journal timestamp.');
  }
  return raw;
}

bool preflightStale(
  Clock clock,
  double checkedAt,
  double checkedWall,
  num boundary,
) {
  final now = clock.wall();
  final elapsed = now - checkedWall;
  return clock.monotonic() - checkedAt > 5 ||
      elapsed < 0 ||
      elapsed > 5 ||
      boundary - now <= 300;
}

String randomId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
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
  final printLine = output ?? stdout.writeln;
  if (stop())
    throw const Refusal('Monitor is stopping. No new reset requested.');
  final usage = weekly(await api.request('usage'), time.wall());
  final remaining = usage.remaining;
  final boundary = usage.resetAt;
  printLine('Weekly remaining: $remaining%');
  requireThreshold(remaining);
  if (boundary - time.wall() <= 300) {
    throw const Refusal(
      'Natural weekly reset is within five minutes. Save the reset credit.',
    );
  }
  List<dynamic>? attempts;
  if (execute) {
    if (state == null || store == null || state['attempts'] is! List) {
      throw const Refusal('Execution requires a locked state journal.');
    }
    attempts = state['attempts'] as List;
    if (attempts.any((a) => a['status'] == 'pending')) {
      throw const Refusal(
        'Unresolved reset attempt. Check the dashboard and journal manually. No retry.',
      );
    }
    if (maxResets != null && attempts.length >= maxResets) {
      throw const Refusal('Configured lifetime reset-attempt budget reached.');
    }
    if (attempts.isNotEmpty &&
        time.wall() - attempts.map((a) => number(a['time'])).reduce(max) <
            21600) {
      throw const Refusal('Six-hour reset cooldown is active.');
    }
  }
  final credits = availableCredits(
    await api.request(creditsEndpoint),
    time.wall(),
  );
  if (credits.isEmpty)
    throw const Refusal(
      'No eligible, unexpired banked reset credit available.',
    );
  final creditId = credits.first.id;
  if (!execute) {
    printLine('DRY RUN: eligible at 0%-1% remaining. No reset requested.');
    return;
  }
  final journal = attempts!;
  if (journal.any((a) => a['credit_id'] == creditId)) {
    throw const Refusal(
      'Selected credit has already been attempted. No retry.',
    );
  }
  if (!availableCredits(
    await api.request(creditsEndpoint),
    time.wall(),
  ).any((c) => c.id == creditId)) {
    throw const Refusal('Selected credit is no longer available.');
  }
  final checkedAt = time.monotonic();
  final checkedWall = time.wall();
  final finalUsage = weekly(await api.request('usage'), time.wall());
  requireThreshold(finalUsage.remaining);
  if (boundary != finalUsage.resetAt ||
      finalUsage.resetAt - time.wall() <= 300) {
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
  if (stop())
    throw const Refusal(
      'Monitor is stopping. No request sent or attempt recorded.',
    );
  final attempt = <String, dynamic>{
    'credit_id': creditId,
    'request_id': (requestId ?? randomId)(),
    'time': time.wall(),
    'status': 'pending',
  };
  journal.add(attempt);
  await store!.save(state!);
  await Future<void>.delayed(Duration.zero);
  if (preflightStale(time, checkedAt, checkedWall, finalUsage.resetAt) ||
      stop()) {
    journal.removeLast();
    await store.save(state);
    throw const Refusal(
      'Preflight became stale or monitor is stopping. No request sent; unsent intent cancelled.',
    );
  }
  requireThreshold(finalUsage.remaining);
  final body = <String, dynamic>{
    'credit_id': creditId,
    'redeem_request_id': attempt['request_id'],
  };
  try {
    if (api is GuardedApi) {
      await api.consume(
        body,
        permit:
            () =>
                !stop() &&
                !preflightStale(
                  time,
                  checkedAt,
                  checkedWall,
                  finalUsage.resetAt,
                ),
      );
    } else {
      await api.request('$creditsEndpoint/consume', body: body);
    }
  } on ConsumeNotSent {
    journal.removeLast();
    await store.save(state);
    rethrow;
  }
  await time.sleep(const Duration(seconds: 3));
  final afterUsage = weekly(await api.request('usage'), time.wall());
  final after = await api.request(creditsEndpoint);
  availableCredits(after, time.wall());
  final entries =
      (after['credits'] as List).where((c) => c['id'] == creditId).toList();
  if (afterUsage.remaining <= 1 ||
      entries.length != 1 ||
      entries.single['status'] != 'consumed') {
    throw const Refusal(
      'Reset outcome not verified. Journal remains blocked. Inspect dashboard, do not retry.',
    );
  }
  attempt['status'] = 'verified';
  await store.save(state);
  printLine(
    'Reset verified by recovered weekly quota and consumed credit. One credit spent.',
  );
}

String homeFor({
  required String operatingSystem,
  required Map<String, String> environment,
}) {
  final value =
      environment[operatingSystem == 'windows' ? 'USERPROFILE' : 'HOME'];
  if (value == null || value.isEmpty)
    throw const Refusal('Home directory unavailable.');
  return value;
}

String get home => homeFor(
  operatingSystem: Platform.operatingSystem,
  environment: Platform.environment,
);
p.Context _pathContext(String operatingSystem, {String? current}) => p.Context(
  style: operatingSystem == 'windows' ? p.Style.windows : p.Style.posix,
  current: current,
);
String authPathFor({required String home, required String operatingSystem}) =>
    _pathContext(operatingSystem).join(home, '.codex', 'auth.json');

class PlatformPaths {
  final String home;
  final String auth;
  final String state;
  const PlatformPaths(this.home, this.auth, this.state);
}

PlatformPaths platformPathsFor(
  String operatingSystem,
  Map<String, String> environment,
) {
  final selectedHome = homeFor(
    operatingSystem: operatingSystem,
    environment: environment,
  );
  return PlatformPaths(
    selectedHome,
    authPathFor(home: selectedHome, operatingSystem: operatingSystem),
    stateDirectoryFor(
      home: selectedHome,
      operatingSystem: operatingSystem,
      environment: environment,
    ),
  );
}

String stateDirectoryFor({
  required String home,
  required String operatingSystem,
  Map<String, String> environment = const {},
}) {
  final paths = _pathContext(operatingSystem);
  if (operatingSystem == 'macos')
    return paths.join(
      home,
      'Library',
      'Application Support',
      'openai-autoreset',
    );
  if (operatingSystem == 'windows') {
    final local = environment['LOCALAPPDATA'];
    return paths.join(
      local == null || local.isEmpty
          ? paths.join(home, 'AppData', 'Local')
          : local,
      'openai-autoreset',
    );
  }
  final xdg = environment['XDG_STATE_HOME'];
  return paths.join(
    xdg != null && paths.isAbsolute(xdg)
        ? xdg
        : paths.join(home, '.local', 'state'),
    'openai-autoreset',
  );
}

String get defaultStateDirectory => stateDirectoryFor(
  home: home,
  operatingSystem: Platform.operatingSystem,
  environment: Platform.environment,
);
String get defaultAuth => p.join(home, '.codex', 'auth.json');
String expandHome(String path) =>
    path == '~'
        ? home
        : path.startsWith('~/') || path.startsWith('~\\')
        ? p.join(home, path.substring(2))
        : path;

/// Pure Dart cannot inspect uid, ACLs, hard-link counts or request O_NOFOLLOW.
/// These path checks are best effort against accidental unsafe files, not a
/// defense against a hostile same-user process racing filesystem operations.
bool isMissingFileError(Object error, {String? operatingSystem}) =>
    error is FileSystemException &&
    error.osError != null &&
    (error.osError!.errorCode == 2 ||
        (operatingSystem ?? Platform.operatingSystem) == 'windows' &&
            error.osError!.errorCode == 3);

void validateLocalPath(
  String path, {
  required bool directory,
  bool missingAllowed = false,
}) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound && missingAllowed) return;
  if (type !=
      (directory
          ? FileSystemEntityType.directory
          : FileSystemEntityType.file)) {
    throw const Refusal(
      'Local path must have the expected type and must not be a symlink.',
    );
  }
  if (!Platform.isWindows &&
      !directory &&
      (FileStat.statSync(path).mode & 0xf000) != 0x8000) {
    throw const Refusal(
      'Local files must be regular files, not devices, sockets, or pipes.',
    );
  }
  if (directory &&
      !Platform.isWindows &&
      FileStat.statSync(path).mode & 0x3f != 0) {
    throw const Refusal(
      'State and readiness directories must be private (0700).',
    );
  }
}

class StateLock {
  static final Set<String> _held = <String>{};
  final String path;
  final RandomAccessFile file;
  bool _closed = false;
  StateLock._(this.path, this.file);
  static StateLock acquire(String path) {
    final canonical = p.normalize(p.absolute(path));
    if (!_held.add(canonical))
      throw const Refusal(
        'Another reset checker or background monitor is running.',
      );
    RandomAccessFile? file;
    try {
      validateLocalPath(path, directory: false, missingAllowed: true);
      file = File(path).openSync(mode: FileMode.append);
      validateLocalPath(path, directory: false);
      file.lockSync(FileLock.exclusive);
      return StateLock._(canonical, file);
    } catch (_) {
      file?.closeSync();
      _held.remove(canonical);
      throw const Refusal(
        'Another reset checker or background monitor is running, or its lock is unsafe.',
      );
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      file.closeSync();
    } finally {
      _held.remove(path);
    }
  }
}

/// State root keeps files private on Unix even when their individual creation
/// mode follows umask. On Windows users must protect the root through ACLs.
/// Dart locks are NOT compatible with the old Python BSD flock locks.
class LocalState {
  final String path;
  LocalState({String? directory})
    : path = p.absolute(directory ?? defaultStateDirectory) {
    final root = Directory(path);
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      root.parent.createSync(recursive: true);
      final temporary = root.parent.createTempSync('.autoreset-state-');
      try {
        validateLocalPath(temporary.path, directory: true);
        // Do not replace an existing state directory or erase a journal.
        if (FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          validateLocalPath(path, directory: true);
        } else {
          temporary.renameSync(path);
        }
      } finally {
        if (temporary.existsSync()) temporary.deleteSync();
      }
    }
    validate();
  }
  void validate() => validateLocalPath(path, directory: true);
  StateLock lock([String name = 'lock']) {
    if (!['lock', 'background.lock'].contains(name))
      throw const Refusal('Invalid lock name.');
    validate();
    return StateLock.acquire(p.join(path, name));
  }

  Map<String, dynamic> read(String hash) {
    validate();
    final file = File(p.join(path, '$hash.json'));
    validateLocalPath(file.path, directory: false, missingAllowed: true);
    try {
      // type/exists map permission failures to notFound. Only an actual
      // ENOENT (or Windows PATH_NOT_FOUND) from opening proves absence.
      if (file.lengthSync() > 16000000)
        throw const Refusal('Invalid state journal.');
      final raw = file.readAsStringSync();
      validateLocalPath(file.path, directory: false);
      return validateState(jsonDecode(raw), hash);
    } on FileSystemException catch (error) {
      if (isMissingFileError(error)) {
        validate();
        return {'version': 1, 'account': hash, 'attempts': <dynamic>[]};
      }
      throw const Refusal(
        'Invalid state journal. Refusing to forget previous attempts.',
      );
    } on Refusal {
      rethrow;
    } catch (_) {
      throw const Refusal(
        'Invalid state journal. Refusing to forget previous attempts.',
      );
    }
  }

  LocalStateStore store(String hash) => LocalStateStore(this, hash);
  IOSink openLog() {
    validate();
    final file = File(p.join(path, 'background.log'));
    validateLocalPath(file.path, directory: false, missingAllowed: true);
    return file.openWrite(mode: FileMode.append);
  }
}

/// Flush and same-filesystem rename give ordinary process-crash persistence.
/// Pure dart:io does NOT expose directory fsync or macOS F_FULLFSYNC, so no
/// power-loss durability equivalent to the previous Python implementation.
class LocalStateStore implements StateStore {
  final LocalState local;
  final String hash;
  LocalStateStore(this.local, this.hash);
  @override
  Future<void> save(Map<String, dynamic> state) async {
    validateState(state, hash);
    local.validate();
    final destination = p.join(local.path, '$hash.json');
    validateLocalPath(destination, directory: false, missingAllowed: true);
    final temporary = Directory(local.path).createTempSync('journal-');
    final file = File(p.join(temporary.path, 'data'));
    RandomAccessFile? handle;
    try {
      validateLocalPath(temporary.path, directory: true);
      handle = file.openSync(mode: FileMode.writeOnly);
      handle.writeStringSync(const JsonEncoder.withIndent('  ').convert(state));
      handle.flushSync();
      handle.closeSync();
      handle = null;
      local.validate();
      validateLocalPath(destination, directory: false, missingAllowed: true);
      file.renameSync(destination);
    } finally {
      handle?.closeSync();
      if (file.existsSync()) file.deleteSync();
      if (temporary.existsSync()) temporary.deleteSync();
    }
  }
}

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
    if (equals >= 0 &&
        [
          '--execute',
          '--dry-run',
          '--background',
          '--foreground',
          '--help',
          '-h',
        ].contains(key))
      throw const Refusal('Flag does not accept a value.');
  }
  if (execute && dry || background && foreground)
    throw const Refusal('Mutually exclusive command-line options.');
  if (!help &&
      (account == null ||
          account.isEmpty ||
          account.contains(RegExp(r'[\r\n\x00]')) ||
          maxResets != null && (maxResets < 1 || maxResets > 100))) {
    throw const Refusal(
      'Account ID required. An optional reset-attempt budget must be 1-100.',
    );
  }
  if ((handshake == null) != (token == null) ||
      handshake != null &&
          (!foreground ||
              background ||
              handshake.isEmpty ||
              !p.isAbsolute(handshake) ||
              token == null ||
              !RegExp(r'^[a-f0-9-]{36}$').hasMatch(token))) {
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
Usage: autoreset --account-id ACCOUNT [--auth PATH] [--execute | --dry-run]
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
  final paths = _pathContext(os, current: currentDirectory);
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

String errorMessage(Object error) =>
    error is Refusal
        ? error.message
        : 'Local I/O failure. Reset automation stopped.';
void reportError(Object error) => stderr.writeln(errorMessage(error));

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
  final printLine = output ?? stdout.writeln;
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
  if (file.lengthSync() > 160)
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
  while (!signals.stopped && deadline.elapsed < const Duration(seconds: 10)) {
    validateLocalPath(directory, directory: true);
    final ack = _readReadyFile(p.join(directory, 'ack'));
    if (ack != null) {
      if (ack != 'ACK ${args.workerToken}\n')
        throw const Refusal('Background readiness was not accepted.');
      _publishReady(directory, 'received', 'RECEIVED ${args.workerToken}\n');
      return;
    }
    await signals.wait(const Duration(milliseconds: 25));
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
    if (logFailure != null)
      throw const Refusal(
        'Background log I/O failure. Reset automation stopped.',
      );
    (log ?? stdout).writeln(text);
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
        if (logFailure != null)
          throw const Refusal(
            'Background log I/O failure. Reset automation stopped.',
          );
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
    return stop.interrupted ? 130 : 0;
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
    child = await Process.start(
      command.first,
      command.skip(1).toList(),
      mode: ProcessStartMode.detached,
    );
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < const Duration(seconds: 10)) {
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
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    if (!accepted)
      throw const Refusal(
        'Background monitor did not start. Check background.log. No automatic retry.',
      );
    // Do not remove the ACK before the worker has consumed it.
    while (deadline.elapsed < const Duration(seconds: 10)) {
      final received = _readReadyFile(p.join(readyDirectory.path, 'received'));
      if (received == 'RECEIVED $token\n') break;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    if (_readReadyFile(p.join(readyDirectory.path, 'received')) !=
        'RECEIVED $token\n') {
      throw const Refusal('Background readiness acknowledgement failed.');
    }
    stdout.writeln(
      'Background monitor started. PID: ${child.pid}. Log: ${p.join(local.path, 'background.log')}',
    );
    stdout.writeln(
      'To stop, verify this PID still belongs to autoreset, then use your OS process tools.',
    );
  } catch (_) {
    if (child != null) child.kill();
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
      stdout.write(usageText);
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
        if (signals.interrupted) return 130;
        rethrow;
      } finally {
        await signals.close();
      }
      if (signals.interrupted) return 130;
    }
    return 0;
  } catch (error) {
    reportError(error);
    return 2;
  }
}
