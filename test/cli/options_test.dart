import 'package:openai_autoreset/autoreset.dart' as ar;
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  group('Pure CLI background arguments', () {
    ar.Options options(List<String> extras) =>
        ar.parseOptions(['--account-id', 'synthetic-account', ...extras]);
    List<String> childCommand(
      ar.Options args,
      String handshake,
      String token, {
      String executable = '/synthetic/dart',
      String script = '/synthetic/bin/autoreset.dart',
    }) => ar.backgroundCommand(
      args,
      handshake,
      token,
      executable: executable,
      script: script,
      operatingSystem: 'linux',
      currentDirectory: '/synthetic/cwd',
      environment: const {'HOME': '/synthetic/home'},
    );
    String value(List<String> command, String flag) =>
        command[command.indexOf(flag) + 1];
    test('source child includes Dart entrypoint exactly once', () {
      final command = childCommand(
        options([]),
        '/synthetic/handshake',
        'synthetic-token',
        executable: '/synthetic/dart',
        script: '/synthetic/bin/autoreset.dart',
      );
      expect(command.take(2), [
        '/synthetic/dart',
        '/synthetic/bin/autoreset.dart',
      ]);
      expect(
        command.where((arg) => arg == '/synthetic/bin/autoreset.dart'),
        hasLength(1),
      );
    });
    test('compiled child never passes its binary as an entrypoint', () {
      final command = childCommand(
        options([]),
        '/synthetic/handshake',
        'synthetic-token',
        executable: '/synthetic/autoreset',
        script: '/synthetic/autoreset',
      );
      expect(command.first, '/synthetic/autoreset');
      expect(command[1], '--foreground');
      expect(
        command.where((arg) => arg == '/synthetic/autoreset'),
        hasLength(1),
      );
    });
    test('Windows child expands auth against injected user profile', () {
      const args = ar.Options(
        accountId: 'synthetic-account',
        auth: r'~\.codex\auth.json',
      );
      final command = ar.backgroundCommand(
        args,
        r'C:\Synthetic\ready',
        'synthetic-token',
        executable: r'C:\Synthetic\autoreset.exe',
        script: r'C:\Synthetic\autoreset.exe',
        operatingSystem: 'windows',
        currentDirectory: r'C:\Synthetic\cwd',
        environment: const {'USERPROFILE': r'C:\Synthetic\User'},
      );
      expect(command.first, r'C:\Synthetic\autoreset.exe');
      expect(command[1], '--foreground');
      expect(value(command, '--auth'), r'C:\Synthetic\User\.codex\auth.json');
      expect(command, contains('--dry-run'));
    });
    test('background defaults are read only and uncapped', () {
      final args = options(['--background']);
      expect(args.background, isTrue);
      expect(args.execute, isFalse);
      expect(args.maxResets, isNull);
    });
    test('child retains auth cap and explicit dry run', () {
      final args = options([
        '--background',
        '--auth',
        '/synthetic/auth.json',
        '--max-resets',
        '1',
      ]);
      final command = childCommand(
        args,
        '/synthetic/handshake',
        'synthetic-token',
      );
      expect(command, contains('--foreground'));
      expect(command, isNot(contains('--background')));
      expect(command, contains('--dry-run'));
      expect(command, isNot(contains('--execute')));
      expect(value(command, '--auth'), '/synthetic/auth.json');
      expect(value(command, '--max-resets'), '1');
    });
    test('live child requires explicit execute', () {
      final command = childCommand(
        options(['--execute', '--auth', '/synthetic/jcode-auth.json']),
        '/synthetic/handshake',
        'synthetic-token',
      );
      expect(command, contains('--execute'));
      expect(command, isNot(contains('--dry-run')));
      expect(value(command, '--auth'), '/synthetic/jcode-auth.json');
    });
    test('uncapped child omits budget and null string', () {
      final command = childCommand(
        options([]),
        '/synthetic/handshake',
        'synthetic-token',
      );
      expect(command, isNot(contains('--max-resets')));
      expect(command, isNot(contains('null')));
      expect(command, contains('--dry-run'));
    });
    test('explicit background budget preserved', () {
      expect(options(['--background', '--max-resets', '2']).maxResets, 2);
    });
    test('invalid explicit budgets refused', () {
      for (final value in [
        '0',
        '-1',
        '101',
        '1.5',
        'NaN',
        '999999999999999999999999',
      ]) {
        expect(() => options(['--background', '--max-resets', value]), refusal);
      }
    });
    test('conflicting modes and unknown options refused', () {
      for (final extras in [
        ['--execute', '--dry-run'],
        ['--foreground', '--background'],
        ['--unknown-option'],
      ]) {
        expect(() => options(extras), refusal);
      }
    });
    test('foreground remains read only', () {
      final args = options(['--foreground']);
      expect(args.foreground, isTrue);
      expect(args.background, isFalse);
      expect(args.execute, isFalse);
    });
    test('child auth spelling is retained without symlink resolution', () {
      final command = childCommand(
        options(['--auth', '/synthetic/link-auth.json']),
        '/synthetic/handshake',
        'synthetic-token',
      );
      expect(value(command, '--auth'), '/synthetic/link-auth.json');
    });
  });
}
