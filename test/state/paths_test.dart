import 'package:openai_autoreset/autoreset.dart' as ar;
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  group('Pure portable state directory paths', () {
    test('home selection uses HOME on Unix and USERPROFILE on Windows', () {
      const env = {
        'HOME': '/synthetic/unix',
        'USERPROFILE': r'C:\Synthetic\User',
      };
      expect(
        ar.homeFor(operatingSystem: 'linux', environment: env),
        '/synthetic/unix',
      );
      expect(
        ar.homeFor(operatingSystem: 'macos', environment: env),
        '/synthetic/unix',
      );
      expect(
        ar.homeFor(operatingSystem: 'windows', environment: env),
        r'C:\Synthetic\User',
      );
    });
    test('missing or empty platform home is refused', () {
      for (final os in ['macos', 'linux', 'windows']) {
        expect(() => ar.homeFor(operatingSystem: os, environment: {}), refusal);
        expect(
          () => ar.homeFor(
            operatingSystem: os,
            environment: {'HOME': '', 'USERPROFILE': ''},
          ),
          refusal,
        );
      }
    });
    test('default auth path retains Codex location on every OS', () {
      for (final os in ['macos', 'linux']) {
        expect(
          ar.authPathFor(home: '/synthetic/home', operatingSystem: os),
          '/synthetic/home/.codex/auth.json',
        );
      }
      expect(
        ar.authPathFor(home: r'C:\Synthetic\User', operatingSystem: 'windows'),
        r'C:\Synthetic\User\.codex\auth.json',
      );
    });
    test('aggregate platform paths use only supplied environment', () {
      final paths = ar.platformPathsFor('windows', {
        'USERPROFILE': r'C:\Synthetic\User',
        'LOCALAPPDATA': r'C:\Synthetic\Local',
      });
      expect(paths.home, r'C:\Synthetic\User');
      expect(paths.auth, r'C:\Synthetic\User\.codex\auth.json');
      expect(paths.state, r'C:\Synthetic\Local\openai-autoreset');
    });
    test('macOS retains legacy journal directory', () {
      expect(
        ar.stateDirectoryFor(home: '/synthetic/home', operatingSystem: 'macos'),
        '/synthetic/home/Library/Application Support/openai-autoreset',
      );
    });
    test('Linux uses absolute XDG_STATE_HOME', () {
      expect(
        ar.stateDirectoryFor(
          home: '/synthetic/home',
          operatingSystem: 'linux',
          environment: {'XDG_STATE_HOME': '/synthetic/state'},
        ),
        '/synthetic/state/openai-autoreset',
      );
    });
    test('Linux ignores relative or empty XDG overrides', () {
      for (final env in <Map<String, String>>[
        {},
        {'XDG_STATE_HOME': ''},
        {'XDG_STATE_HOME': 'relative'},
      ]) {
        expect(
          ar.stateDirectoryFor(
            home: '/synthetic/home',
            operatingSystem: 'linux',
            environment: env,
          ),
          '/synthetic/home/.local/state/openai-autoreset',
        );
      }
    });
    test('Windows uses LOCALAPPDATA with Windows separators', () {
      expect(
        ar.stateDirectoryFor(
          home: r'C:\Synthetic\User',
          operatingSystem: 'windows',
          environment: {'LOCALAPPDATA': r'C:\Synthetic\Local'},
        ),
        r'C:\Synthetic\Local\openai-autoreset',
      );
    });
    test('Windows falls back to supplied user profile AppData', () {
      for (final env in <Map<String, String>>[
        {},
        {'LOCALAPPDATA': ''},
      ]) {
        expect(
          ar.stateDirectoryFor(
            home: r'C:\Synthetic\User',
            operatingSystem: 'windows',
            environment: env,
          ),
          r'C:\Synthetic\User\AppData\Local\openai-autoreset',
        );
      }
    });
  });
}
