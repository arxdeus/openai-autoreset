import 'dart:io';

import 'package:openai_autoreset/src/core/refusal.dart';
import 'package:path/path.dart' as p;

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
p.Context pathContext(String operatingSystem, {String? current}) => p.Context(
  style: operatingSystem == 'windows' ? p.Style.windows : p.Style.posix,
  current: current,
);
String authPathFor({required String home, required String operatingSystem}) =>
    pathContext(operatingSystem).join(home, '.codex', 'auth.json');

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
  final paths = pathContext(operatingSystem);
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
