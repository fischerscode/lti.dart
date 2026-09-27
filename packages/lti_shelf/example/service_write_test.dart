import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:lti/lti.dart';
import 'package:shelf/shelf.dart';

/// Deliberate actions in a dedicated test course. Single-process example only.
final class ServiceWriteTest {
  ServiceWriteTest({
    required this.origin,
    required this.servicesFor,
    DateTime Function()? clock,
    this.maxSessions = 100,
  }) : _clock = clock ?? DateTime.now;
  final Uri origin;
  final LtiServiceClient Function(LtiResourceLaunch) servicesFor;
  final DateTime Function() _clock;
  final int maxSessions;
  final _random = Random.secure();
  final _sessions = <String, _Session>{};
  static const path = '/test/services';
  static const _headers = {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store',
    'referrer-policy': 'strict-origin',
    'x-content-type-options': 'nosniff',
    'content-security-policy':
        "default-src 'none'; base-uri 'none'; form-action 'self'",
  };
  String _token() => base64Url
      .encode(List.generate(24, (_) => _random.nextInt(256)))
      .replaceAll('=', '');
  String _escape(Object value) => const HtmlEscape().convert('$value');
  void _prune() =>
      _sessions.removeWhere((_, s) => !s.expires.isAfter(_clock()));

  Response begin(Request request, LtiResourceLaunch launch) {
    final instructor =
        launch.user != null &&
        launch.roles.any(
          (r) =>
              LtiRoles.isStandard(r) &&
              (r == LtiRoles.instructor ||
                  r.startsWith('${LtiRoles.membership}/Instructor#')),
        );
    if (!instructor) {
      return _error(403, 'Dieser Schreibtest benötigt einen Lehrkraft-Start.');
    }
    if (launch.ags?.lineItems == null ||
        !(launch.ags?.scopes.contains(LtiServiceScopes.lineItem) ?? false)) {
      return _error(
        403,
        'ByCS muss die Verwaltung von Bewertungsspalten freigeben.',
      );
    }
    _prune();
    if (_sessions.length >= maxSessions) {
      return _error(503, 'Zu viele offene Tests.');
    }
    final id = _token();
    final session = _Session(
      servicesFor(launch),
      _token(),
      _token(),
      _clock().add(const Duration(hours: 1)),
      'LTI-Dart-Test-${_token().substring(0, 12)}',
    );
    _sessions[id] = session;
    return _page(id, session, 'Bereit. Noch keine Daten geändert.').change(
      headers: {
        'set-cookie':
            '__Host-lti-write-$id=${session.binding}; Path=/; Secure; HttpOnly; SameSite=None; Partitioned; Max-Age=3600',
      },
    );
  }

  Future<Response> handle(Request request) async {
    if (request.method != 'POST') {
      return _error(
        405,
        'POST erforderlich.',
      ).change(headers: {'allow': 'POST'});
    }
    if (request.headers['origin'] != origin.origin) {
      return _error(403, 'Ungültiger Ursprung.');
    }
    if (request.headers['content-type']
            ?.split(';')
            .first
            .trim()
            .toLowerCase() !=
        'application/x-www-form-urlencoded') {
      return _error(415, 'Formular erforderlich.');
    }
    Map<String, String> fields;
    try {
      final bytes = <int>[];
      final stream = StreamIterator<List<int>>(request.read());
      final deadline = DateTime.now().add(const Duration(seconds: 5));
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
      final data = Uri(query: utf8.decode(bytes)).queryParametersAll;
      if (data.values.any((v) => v.length != 1) ||
          !data.keys.toSet().containsAll(['session', 'csrf', 'action']) ||
          data.keys.any(
            (k) => ![
              'session',
              'csrf',
              'action',
              'learner',
              'confirm',
            ].contains(k),
          )) {
        throw const FormatException();
      }
      fields = data.map((k, v) => MapEntry(k, v.single));
    } on TimeoutException {
      return _error(408, 'Zeitlimit beim Lesen des Formulars.');
    } on FormatException {
      return _error(400, 'Ungültiges Formular.');
    }
    _prune();
    final id = fields['session']!;
    final session = _sessions[id];
    final name = '__Host-lti-write-$id=';
    final cookies = (request.headers['cookie'] ?? '')
        .split(';')
        .map((s) => s.trim())
        .where((s) => s.startsWith(name))
        .toList();
    if (session == null ||
        cookies.length != 1 ||
        cookies.single.substring(name.length) != session.binding ||
        fields['csrf'] != session.csrf) {
      return _error(
        403,
        'Test abgelaufen oder Browserbindung ungültig. Eventuelle Testspalte anhand ihres Namens in ByCS entfernen.',
      );
    }
    if (session.busy) return _error(409, 'Eine Aktion läuft bereits.');
    // Rotate before the first await: double clicks and old forms cannot replay.
    session.busy = true;
    session.csrf = _token();
    var message = '';
    try {
      message = await _act(session, fields);
    } on LtiOAuthException catch (e) {
      message =
          'OAuth ${e.code.name}; HTTP ${e.statusCode ?? 'n/a'}; ${e.responseIssue?.name ?? ''}';
    } on LtiServiceException catch (e) {
      message =
          'Service ${e.code.name}; HTTP ${e.statusCode ?? 'n/a'}; ${e.responseIssue?.name ?? ''}';
    } catch (_) {
      message = 'Aktion fehlgeschlagen. Keine automatische Wiederholung.';
    } finally {
      session.busy = false;
    }
    return _page(id, session, message);
  }

  Future<String> _act(_Session s, Map<String, String> fields) async {
    final action = fields['action'];
    final ags = s.services.ags;
    if (action == 'status') {
      return s.deleted ? 'Testspalte gelöscht.' : 'Test weiterhin geöffnet.';
    }
    if (action == 'create' && !s.createAttempted) {
      // Never repeat an uncertain POST; inspect ByCS using the unique label.
      s.createAttempted = true;
      s.item = await ags.createLineItem(
        LtiLineItem(
          label: s.label,
          scoreMaximum: 100,
          resourceId: s.label,
          tag: s.label,
        ),
      );
      return 'Testspalte erstellt: ${s.label} (Maximum 100).';
    }
    if (action == 'roster') {
      final members = <LtiMember>[];
      await for (final member in s.services.nrps.allMemberships(limit: 100)) {
        if (members.length >= 1000) {
          return 'Mehr als 1000 Einträge; bitte einen kleinen Testkurs verwenden.';
        }
        members.add(member);
      }
      // Atomic replace only after complete retrieval. Opaque option keys keep
      // learner identities out of form values and prevent arbitrary user IDs.
      s.learners = {
        for (final m in members.where(
          (m) =>
              m.status == LtiMembershipStatus.active &&
              m.roles.any(
                (r) =>
                    r == LtiRoles.learner ||
                    (LtiRoles.isStandard(r) &&
                        r.startsWith('${LtiRoles.membership}/Learner#')),
              ),
        ))
          _token(): m,
      };
      return '${s.learners.length} aktive Lernendenkonten gefunden. Nur ein eigenes Testkonto auswählen.';
    }
    final item = s.item;
    if (item == null) {
      return 'Zuerst eine Testspalte erstellen. Bei unklarem Erstellungsergebnis in ByCS nach dem angezeigten Namen suchen.';
    }
    if (action == 'read') {
      final current = await ags.getLineItem(lineItem: item.id);
      return 'Testspalte gelesen: ${current.label}; Maximum ${current.scoreMaximum}.';
    }
    if (action == 'update' && !s.updateAttempted) {
      s.updateAttempted = true;
      s.item = await ags.updateLineItem(
        item,
        LtiLineItem.fromJson({...item.json, 'label': '${s.label} – geändert'}),
      );
      return 'Testspalte umbenannt. Jetzt auch im ByCS-Notenbuch prüfen.';
    }
    if (action == 'score' &&
        !s.scoreAttempted &&
        fields['confirm'] == 'yes' &&
        s.learners.containsKey(fields['learner'])) {
      final learner = s.learners[fields['learner']]!;
      s.selected = learner.userId;
      s.scoreAttempted = true;
      s.scoreMayExist = true;
      await ags.publishScore(
        LtiScore(
          userId: learner.userId,
          timestamp: s.timestamp(_clock()),
          activityProgress: LtiActivityProgress.completed,
          gradingProgress: LtiGradingProgress.fullyGraded,
          scoreGiven: 80,
          scoreMaximum: 100,
        ),
        lineItem: item.id,
      );
      return 'Testnote 80/100 übertragen. Bitte im ByCS-Notenbuch prüfen und Ergebnis abrufen.';
    }
    if (action == 'results' && s.selected != null) {
      final results = await ags
          .allResults(lineItem: item.id, userId: s.selected)
          .toList();
      final own = results.where((r) => r.userId == s.selected).toList();
      return own.isEmpty
          ? 'Kein Ergebnis für das ausgewählte Konto vorhanden.'
          : own
                .map(
                  (r) =>
                      'Ergebnis: ${r.resultScore ?? 'leer'}/${r.resultMaximum}',
                )
                .join('\n');
    }
    if (action == 'clear' && s.scoreMayExist && !s.clearAttempted) {
      s.clearAttempted = true;
      await ags.publishScore(
        LtiScore(
          userId: s.selected!,
          timestamp: s.timestamp(_clock()),
          activityProgress: LtiActivityProgress.completed,
          gradingProgress: LtiGradingProgress.notReady,
        ),
        lineItem: item.id,
      );
      s.scoreMayExist = false;
      return 'Testnote geleert. Ergebnis erneut abrufen und ByCS-Notenbuch prüfen.';
    }
    if (action == 'delete' &&
        !s.deleteAttempted &&
        (!s.scoreMayExist || fields['confirm'] == 'yes')) {
      s.deleteAttempted = true;
      await ags.deleteLineItem(lineItem: item.id);
      s.item = null;
      s.deleted = true;
      return 'Eigene Testspalte gelöscht. Bitte im ByCS-Notenbuch kontrollieren.';
    }
    return 'Aktion nicht verfügbar oder Bestätigung/Testkonto fehlt. Es wurde nichts geändert.';
  }

  Response _page(String id, _Session s, String message) {
    String form(String action, String label, [String extra = '']) =>
        '''<form method="post" action="$path">
<input type="hidden" name="session" value="$id"><input type="hidden" name="csrf" value="${s.csrf}">
$extra<button name="action" value="$action">${_escape(label)}</button></form>''';
    final item = s.item;
    final scopes = s.services.launch.ags!.scopes;
    return Response.ok(
      '''<!doctype html><html lang="de"><meta charset="utf-8"><title>AGS-Schreibtest</title><body>
<h1>AGS-Schreibtest</h1><p>${_escape(message)}</p>
<p>Testspalte: <strong>${_escape(s.label)}</strong></p>
<p>Nur in einem Testkurs verwenden. Diese Seite bis zum Aufräumen offen lassen.
Der Test gilt eine Stunde. Bei Neustart, Ablauf oder unklarem Ergebnis die Testspalte anhand dieses Namens in ByCS prüfen und manuell entfernen.</p>
${!s.createAttempted ? form('create', '1. Testspalte erstellen (100 Punkte)') : ''}
${s.createAttempted && item == null && !s.deleted ? '<p>Erstellung unklar. Nicht erneut erstellen; zuerst in ByCS prüfen.</p>' : ''}
${item != null ? form('read', 'Testspalte lesen') : ''}
${item != null && !s.updateAttempted ? form('update', '2. Testspalte umbenennen') : ''}
${item != null && s.services.launch.nrps != null && !s.scoreAttempted ? form('roster', '3. Lernendenkonten laden') : ''}
${item != null && !s.scoreAttempted && scopes.contains(LtiServiceScopes.score) && s.learners.isNotEmpty ? form('score', '4. Testnote 80/100 senden', '''<label>Testkonto <select name="learner" required><option value="">Bitte auswählen</option>${s.learners.entries.map((e) => '<option value="${e.key}">${_escape(e.value.name ?? 'Lernendenkonto')} – ID ${_escape(e.value.userId)}</option>').join()}</select></label><p><label><input type="checkbox" name="confirm" value="yes" required>Dies ist mein Testkonto; ich möchte dafür 80/100 Punkte eintragen.</label></p>''') : ''}
${item != null && s.selected != null && scopes.contains(LtiServiceScopes.resultReadonly) ? form('results', '5. Ergebnis abrufen') : ''}
${item != null && s.scoreMayExist && !s.clearAttempted ? form('clear', '6. Testnote leeren') : ''}
${item != null && !s.deleteAttempted ? form('delete', '7. Eigene Testspalte löschen', s.scoreMayExist ? '<p><label><input type="checkbox" name="confirm" value="yes" required>Auch eventuell vorhandene Testnoten dieser Spalte entfernen.</label></p>' : '') : ''}
${s.learners.isEmpty && item != null ? '<p>Für den Notentest muss ein aktives Test-Schülerkonto im Kurs eingeschrieben sein.</p>' : ''}
${form('status', 'Status anzeigen')}
<p>Nach einer fehlgeschlagenen Schreibaktion deren Ergebnis in ByCS prüfen. Schreibaktionen werden nicht automatisch wiederholt.</p>
</body></html>''',
      headers: _headers,
    );
  }

  Response _error(int status, String message) =>
      Response(status, body: _escape(message), headers: _headers);
}

final class _Session {
  _Session(this.services, this.binding, this.csrf, this.expires, this.label);
  final LtiServiceClient services;
  final String binding;
  String csrf;
  final DateTime expires;
  final String label;
  bool busy = false,
      createAttempted = false,
      updateAttempted = false,
      scoreAttempted = false,
      clearAttempted = false,
      deleteAttempted = false,
      scoreMayExist = false,
      deleted = false;
  LtiLineItem? item;
  Map<String, LtiMember> learners = {};
  String? selected;
  DateTime? lastTimestamp;
  DateTime timestamp(DateTime now) {
    final previous = lastTimestamp;
    return lastTimestamp = previous != null && !now.isAfter(previous)
        ? previous.add(const Duration(microseconds: 1))
        : now;
  }
}
