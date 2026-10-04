import 'dart:convert';
import 'dart:io';

import 'package:openai_autoreset/src/core/refusal.dart';
import 'package:openai_autoreset/src/state/paths.dart';

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
