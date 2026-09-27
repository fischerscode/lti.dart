import 'dart:convert';
import 'dart:io';

import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

/// Checks a package tag and waits for workspace dependencies before publishing.
/// Run from the repository root; this command never publishes or creates tags.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('Usage: dart run tool/release.dart PACKAGE-vVERSION');
    exitCode = 64;
    return;
  }
  try {
    final package = validateRelease(Directory.current, args.single);
    final output = Platform.environment['GITHUB_OUTPUT'];
    if (output != null) {
      File(output)
          .writeAsStringSync('package=$package\n', mode: FileMode.append);
    }
    if (package == 'lti_shelf') {
      final core = _manifest(Directory.current, 'lti');
      final version = core['version'] as String;
      stdout.writeln(
        'Waiting for lti $version to become available on pub.dev.',
      );
      await _waitForPublishedVersion('lti', version);
    }
    stdout.writeln('Release ${args.single} is ready for a publish dry run.');
  } on Exception catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}

/// Validates the tag, changelog and package metadata, returning the package name.
/// Throws [FormatException] for a mismatch or incomplete release metadata.
String validateRelease(Directory root, String tag) {
  final match = RegExp(r'^(lti|lti_shelf)-v(.+)$').firstMatch(tag);
  if (match == null) throw const FormatException('Unknown package tag.');
  final package = match[1]!;
  final version = Version.parse(match[2]!);
  final manifest = _manifest(root, package);
  if (manifest['name'] != package ||
      manifest['version'] != version.toString() ||
      tag != '$package-v${manifest['version']}') {
    throw const FormatException('Tag must exactly match the package version.');
  }
  if (manifest['publish_to'] != null &&
      manifest['publish_to'] != 'https://pub.dev') {
    throw const FormatException('Package is not configured for pub.dev.');
  }
  final repository = manifest['repository'];
  if (repository is! String || !repository.startsWith('https://github.com/')) {
    throw const FormatException('Configure the package GitHub repository URL.');
  }
  final directory = Directory('${root.path}/packages/$package');
  final license = File('${directory.path}/LICENSE');
  if (!license.existsSync() || license.readAsStringSync().trim().isEmpty) {
    throw const FormatException('A package LICENSE is required.');
  }
  final changelog = File('${directory.path}/CHANGELOG.md').readAsStringSync();
  final firstHeading = RegExp(
    r'^## (.+)$',
    multiLine: true,
  ).firstMatch(changelog)?[1];
  if (firstHeading != '$version' &&
      !(firstHeading?.startsWith('$version - ') ?? false)) {
    throw const FormatException('The latest changelog must match the version.');
  }
  if (package == 'lti_shelf') {
    final dependencies = manifest['dependencies'] as YamlMap;
    final constraint = dependencies['lti'];
    final core = _manifest(root, 'lti');
    if (constraint is! String ||
        !VersionConstraint.parse(constraint)
            .allows(Version.parse(core['version'] as String))) {
      throw const FormatException(
        'lti_shelf must accept the workspace lti version.',
      );
    }
  }
  return package;
}

YamlMap _manifest(Directory root, String package) => loadYaml(
  File('${root.path}/packages/$package/pubspec.yaml').readAsStringSync(),
) as YamlMap;

Future<void> _waitForPublishedVersion(String package, String version) async {
  // Two package-tag workflows can start together. Only the dependency tag's
  // workflow may publish that dependency; this job waits and never publishes it.
  final uri = Uri.https('pub.dev', '/api/packages/$package/versions/$version');
  for (var attempt = 0; attempt < 40; attempt++) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final found = await (() async {
        final request = await client.getUrl(uri);
        final response = await request.close();
        if (response.statusCode == 200) {
          final body = await utf8.decoder.bind(response).join();
          final data = jsonDecode(body) as Map<String, dynamic>;
          return data['version'] == version;
        }
        if (response.statusCode != 404 && response.statusCode < 500) {
          throw HttpException(
            'pub.dev returned ${response.statusCode}.',
            uri: uri,
          );
        }
        await response.drain<void>();
        return false;
      })().timeout(const Duration(seconds: 15));
      if (found) return;
    } finally {
      client.close(force: true);
    }
    if (attempt < 39) await Future<void>.delayed(const Duration(seconds: 15));
  }
  throw FormatException(
    '$package $version is not available. Publish its tag first, then rerun this job.',
  );
}
