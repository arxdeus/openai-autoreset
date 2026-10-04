import 'dart:io' show FileSystemException, OSError;

import 'package:openai_autoreset/autoreset.dart' as ar;
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  group('State journal', () {
    test('state header and attempts are validated without native state', () {
      final valid = <String, dynamic>{
        'version': 1,
        'account': 'synthetic-hash',
        'attempts': <dynamic>[],
      };
      expect(ar.validateState(valid, 'synthetic-hash')['attempts'], isEmpty);
      for (final data in [
        null,
        [],
        {...valid, 'version': true},
        {...valid, 'version': 1.0},
        {...valid, 'account': 'other'},
        {...valid, 'attempts': {}},
        {
          ...valid,
          'attempts': [null],
        },
        {
          ...valid,
          'attempts': [
            {
              'status': 'unknown',
              'time': now,
              'credit_id': 'x',
              'request_id': 'r',
            },
          ],
        },
        {
          ...valid,
          'attempts': [
            {
              'status': 'pending',
              'time': -1,
              'credit_id': 'x',
              'request_id': 'r',
            },
          ],
        },
      ]) {
        expect(() => ar.validateState(data, 'synthetic-hash'), refusal);
      }
    });
    test('only genuine missing-file OS errors permit an empty journal', () {
      const absent = FileSystemException(
        'Synthetic missing',
        '/synthetic/journal',
        OSError('Synthetic ENOENT', 2),
      );
      const missingParent = FileSystemException(
        'Synthetic missing parent',
        '/synthetic/journal',
        OSError('Synthetic path missing', 3),
      );
      const denied = FileSystemException(
        'Synthetic denied',
        '/synthetic/journal',
        OSError('Synthetic access denied', 13),
      );
      const generic = FileSystemException(
        'Synthetic unknown',
        '/synthetic/journal',
      );
      for (final os in ['macos', 'linux', 'windows']) {
        expect(ar.isMissingFileError(absent, operatingSystem: os), isTrue);
        expect(ar.isMissingFileError(denied, operatingSystem: os), isFalse);
        expect(ar.isMissingFileError(generic, operatingSystem: os), isFalse);
        expect(
          ar.isMissingFileError(
            StateError('Synthetic error'),
            operatingSystem: os,
          ),
          isFalse,
        );
        expect(
          ar.isMissingFileError(missingParent, operatingSystem: os),
          os == 'windows',
        );
      }
    });
  });
}
