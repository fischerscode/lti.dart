import 'dart:io';

final subjectPattern = RegExp(
  r'^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)'
  r'(\([^()\r\n]+\))?!?: \S.*$',
);

Future<void> main(List<String> args) async {
  List<String> messages;
  if (args.length == 2 && args.first == '--file') {
    messages = [await File(args[1]).readAsString()];
  } else if (args.length == 2 && args.first == '--range') {
    final result = await Process.run('git', [
      'log',
      '--no-merges',
      '--format=%B%x00',
      args[1],
      '--',
    ]);
    if (result.exitCode != 0) {
      stderr.write(result.stderr);
      exitCode = result.exitCode;
      return;
    }
    messages = (result.stdout as String)
        .split('\u0000')
        .where((s) => s.trim().isNotEmpty)
        .toList();
  } else {
    stderr.writeln(
      'Usage: dart run tool/check_commits.dart --file FILE | --range BASE..HEAD',
    );
    exitCode = 64;
    return;
  }
  for (final message in messages) {
    final lines = message.trim().split('\n');
    if (!subjectPattern.hasMatch(lines.first) ||
        (lines.length > 1 && lines[1].trim().isNotEmpty)) {
      stderr.writeln(
        'Expected a Conventional Commit subject, e.g. feat(lti): add deep linking, followed by a blank line before any body.',
      );
      exitCode = 1;
      return;
    }
  }
}
