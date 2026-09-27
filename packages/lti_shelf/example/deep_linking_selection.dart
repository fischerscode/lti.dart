import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:lti/lti.dart';
import 'package:lti_shelf/lti_shelf.dart';
import 'package:shelf/shelf.dart';

/// Bounded, single-process selection sessions for the integration example only.
/// Verified launches remain server-side; each browser-bound choice is single-use.
final class DeepLinkingSelection {
  DeepLinkingSelection({
    required this.tool,
    required this.origin,
    DateTime Function()? clock,
    this.maxSessions = 1000,
    this.partitionedCookies = false,
  }) : _clock = clock ?? DateTime.now;
  final LtiTool tool;
  final Uri origin;
  final DateTime Function() _clock;
  final int maxSessions;
  final bool partitionedCookies;
  final _random = Random.secure();
  final _sessions = <String, _SelectionSession>{};
  static const path = '/test/deep-linking';
  static const _headers = {
    'cache-control': 'no-store',
    'referrer-policy': 'no-referrer',
    'x-content-type-options': 'nosniff',
  };

  String _token() => base64Url
      .encode(List.generate(32, (_) => _random.nextInt(256)))
      .replaceAll('=', '');
  void _prune() => _sessions.removeWhere(
    (_, session) => !session.expiresAt.isAfter(_clock()),
  );
  String _cookie(String id, String value, int age) =>
      '__Host-lti-selection-$id=$value; Path=/; Secure; HttpOnly; SameSite=None; Max-Age=$age'
      '${partitionedCookies ? '; Partitioned' : ''}';

  Response begin(Request request, LtiDeepLinkingLaunch launch) {
    if (tool.signer == null) {
      return _error(503, 'Tool signing is not configured.');
    }
    // Deliberate policy for this test UI, not a universal LTI authorization rule.
    final canSelect =
        launch.user != null &&
        launch.roles.any(
          (role) =>
              LtiRoles.standard.contains(role) &&
              [
                LtiRoles.instructor,
                '${LtiRoles.membership}#ContentDeveloper',
                '${LtiRoles.membership}#Administrator',
              ].any(
                (base) =>
                    role == base ||
                    role.startsWith('${base.replaceFirst('#', '/')}#'),
              ),
        );
    if (!canSelect) {
      return _error(
        403,
        'This test selection requires an authenticated instructor, content developer or context administrator.',
      );
    }
    _prune();
    if (_sessions.length >= maxSessions) {
      return _error(503, 'Too many pending selections. Try again later.');
    }
    final id = _token();
    final binding = _token();
    final csrf = _token();
    _sessions[id] = _SelectionSession(
      launch,
      binding,
      csrf,
      _clock().add(const Duration(minutes: 10)),
    );
    final supported = launch.settings.acceptTypes.contains('ltiResourceLink');
    return Response.ok(
      '''<!doctype html><html lang="de"><meta charset="utf-8">
<title>LTI-Testinhalt auswählen</title><body>
<h1>LTI-Testinhalt auswählen</h1>
<p>Wähle den Testinhalt aus oder kehre ohne Auswahl zur Lernplattform zurück.</p>
${supported ? '<p>Testinhalt: LTI Dart – Deep-Linking-Test</p>' : '<p>Die Lernplattform akzeptiert hier keine LTI-Ressourcenlinks.</p>'}
<form method="post" action="$path">
<input type="hidden" name="session" value="$id">
<input type="hidden" name="csrf" value="$csrf">
${supported ? '<button type="submit" name="choice" value="select">Testinhalt hinzufügen</button>' : ''}
<button type="submit" name="choice" value="cancel">Abbrechen</button>
</form></body></html>''',
      headers: {
        ..._headers,
        'content-type': 'text/html; charset=utf-8',
        'content-security-policy':
            "default-src 'none'; base-uri 'none'; form-action 'self'",
        'set-cookie': _cookie(id, binding, 600),
      },
    );
  }

  Future<Response> complete(Request request) async {
    _prune();
    if (request.method != 'POST') {
      return Response(405, headers: {..._headers, 'allow': 'POST'});
    }
    if (request.headers['origin'] != origin.origin) {
      return _error(403, 'Selection origin mismatch.');
    }
    if (request.headers['content-type']
            ?.split(';')
            .first
            .trim()
            .toLowerCase() !=
        'application/x-www-form-urlencoded') {
      return _error(415, 'Expected a form POST.');
    }
    Map<String, String> fields;
    try {
      final bytes = <int>[];
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      final stream = StreamIterator<List<int>>(request.read());
      try {
        while (await stream.moveNext().timeout(
          deadline.difference(DateTime.now()),
        )) {
          bytes.addAll(stream.current);
          if (bytes.length > 4096) throw const FormatException();
        }
      } finally {
        await stream.cancel();
      }
      final values = Uri(query: utf8.decode(bytes)).queryParametersAll;
      if (values.length != 3 ||
          values.values.any((v) => v.length != 1) ||
          !values.keys.toSet().containsAll(['session', 'csrf', 'choice'])) {
        throw const FormatException();
      }
      fields = values.map((k, v) => MapEntry(k, v.single));
    } on FormatException {
      return _error(400, 'Invalid selection form.');
    } on TimeoutException {
      return _error(408, 'Selection request timed out.');
    }
    final id = fields['session']!;
    final session = _sessions[id];
    final choice = fields['choice'];
    final name = '__Host-lti-selection-$id=';
    final cookies = (request.headers['cookie'] ?? '')
        .split(';')
        .map((s) => s.trim())
        .where((s) => s.startsWith(name))
        .toList();
    if (session == null ||
        !session.expiresAt.isAfter(_clock()) ||
        cookies.length != 1 ||
        !_same(cookies.single.substring(name.length), session.binding) ||
        !_same(fields['csrf']!, session.csrf)) {
      return _error(
        403,
        'Selection expired or browser binding invalid. Restart from ByCS.',
      );
    }
    if (choice != 'select' && choice != 'cancel') {
      return _error(400, 'Unknown selection.');
    }
    if (choice == 'select' &&
        !session.launch.settings.acceptTypes.contains('ltiResourceLink')) {
      return _error(400, 'LTI resource links are not accepted.');
    }
    // Consume synchronously before awaiting signing to prevent concurrent replay.
    _sessions.remove(id);
    try {
      final message = await tool.createDeepLinkingResponse(
        launch: session.launch,
        items: choice == 'cancel'
            ? const []
            : [
                LtiContentItem.ltiResourceLink(
                  url: origin.resolve('/activity'),
                  title: 'LTI Dart – Deep-Linking-Test',
                  custom: const {'lti_dart_test': 'deep-linking-v1'},
                ),
              ],
      );
      return deepLinkingFormResponse(message)
          .change(headers: {'set-cookie': _cookie(id, '', 0)});
    } catch (_) {
      return _error(
        502,
        'Selection could not be signed. Restart from ByCS.',
      ).change(headers: {'set-cookie': _cookie(id, '', 0)});
    }
  }

  Response _error(int status, String text) => Response(
    status,
    body: text,
    headers: {..._headers, 'content-type': 'text/plain; charset=utf-8'},
  );
  bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }
}

final class _SelectionSession {
  const _SelectionSession(this.launch, this.binding, this.csrf, this.expiresAt);
  final LtiDeepLinkingLaunch launch;
  final String binding;
  final String csrf;
  final DateTime expiresAt;
}
