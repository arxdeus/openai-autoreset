import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:openai_autoreset/src/core/limits.dart';
import 'package:openai_autoreset/src/core/refusal.dart';
import 'package:openai_autoreset/src/state/paths.dart';
import 'package:path/path.dart' as p;

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

/// Pure Dart cannot inspect uid, ACLs, hard-link counts or request O_NOFOLLOW.
/// These path checks are best effort against accidental unsafe files, not a
/// defense against a hostile same-user process racing filesystem operations.
bool isMissingFileError(Object error, {String? operatingSystem}) {
  if (error is! FileSystemException || error.osError == null) return false;
  final code = error.osError!.errorCode;
  final windows = (operatingSystem ?? Platform.operatingSystem) == 'windows';
  return code == 2 || (windows && code == 3);
}

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
  if (!Platform.isWindows) {
    final mode = FileStat.statSync(path).mode;
    final regularFile = (mode & 0xf000) == 0x8000;
    final privateDirectory = (mode & 0x3f) == 0;
    if (!directory && !regularFile) {
      throw const Refusal(
        'Local files must be regular files, not devices, sockets, or pipes.',
      );
    }
    if (directory && !privateDirectory) {
      throw const Refusal(
        'State and readiness directories must be private (0700).',
      );
    }
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
      if (file.lengthSync() > maxJournalBytes)
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
