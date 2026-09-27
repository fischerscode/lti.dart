import 'dart:io';

import 'package:test/test.dart';

import '../tool/release.dart';

void main() {
  late Directory root;

  void writePackage(String name, {String version = '0.2.0-dev.2'}) {
    final directory = Directory('${root.path}/packages/$name')
      ..createSync(recursive: true);
    File('${directory.path}/pubspec.yaml').writeAsStringSync('''
name: $name
version: $version
repository: https://github.com/example/tools
${name == 'lti_shelf' ? 'dependencies:\n  lti: ^0.2.0-dev.2' : ''}
''');
    File('${directory.path}/LICENSE').writeAsStringSync('Test fixture license');
    File('${directory.path}/CHANGELOG.md')
        .writeAsStringSync('## $version - 2026-09-27\n\n- Test release.\n');
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('lti-release-test-');
    writePackage('lti');
    writePackage('lti_shelf');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('accepts independent package tags and prereleases', () {
    expect(validateRelease(root, 'lti-v0.2.0-dev.2'), 'lti');
    expect(validateRelease(root, 'lti_shelf-v0.2.0-dev.2'), 'lti_shelf');
    writePackage('lti', version: '0.2.0');
    expect(validateRelease(root, 'lti-v0.2.0'), 'lti');
  });

  test('rejects unknown packages, malformed and mismatched versions', () {
    for (final tag in [
      'other-v0.2.0',
      'lti-vbad',
      'lti-v0.2.1',
      '../lti-v0.2.0',
    ]) {
      expect(() => validateRelease(root, tag), throwsFormatException);
    }
  });

  test('requires current release notes instead of an unreleased heading', () {
    File('${root.path}/packages/lti/CHANGELOG.md')
        .writeAsStringSync('## Unreleased\n\n- Pending\n\n## 0.2.0-dev.2\n');
    expect(
      () => validateRelease(root, 'lti-v0.2.0-dev.2'),
      throwsFormatException,
    );
  });

  test('requires a license', () {
    File('${root.path}/packages/lti/LICENSE').deleteSync();
    expect(
      () => validateRelease(root, 'lti-v0.2.0-dev.2'),
      throwsFormatException,
    );
  });

  test('rejects an incompatible workspace dependency', () {
    writePackage('lti', version: '0.3.0');
    expect(
      () => validateRelease(root, 'lti_shelf-v0.2.0-dev.2'),
      throwsFormatException,
    );
  });

  test('rejects private packages', () {
    File('${root.path}/packages/lti/pubspec.yaml')
        .writeAsStringSync('publish_to: none\n', mode: FileMode.append);
    expect(
      () => validateRelease(root, 'lti-v0.2.0-dev.2'),
      throwsFormatException,
    );
  });
}
