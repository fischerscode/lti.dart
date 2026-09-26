import 'package:lti/lti.dart';
import 'package:lti_shelf/lti_shelf.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../../lti/test/support/platform.dart';

void main() {
  late TestPlatform platform;
  setUp(() => platform = TestPlatform());
  tearDown(() => platform.client.close());

  final cases = <String, MapEntry<String, Object?>>{
    'Nonce mismatch.': const MapEntry('nonce', 'PRIVATE_VALUE'),
    'Target link URI differs from login target or is missing.': const MapEntry(
      LtiClaims.targetLinkUri,
      'https://example.test/PRIVATE_VALUE',
    ),
    'Invalid numeric date: iat.': const MapEntry('iat', 'PRIVATE_VALUE'),
    'Invalid optional string field: given_name.': const MapEntry('given_name', [
      'PRIVATE_VALUE',
    ]),
    'Expected a JSON object in field: ${LtiClaims.context}.': const MapEntry(
      LtiClaims.context,
      'PRIVATE_VALUE',
    ),
    'Expected an array of strings in field: ${LtiClaims.roles}.':
        const MapEntry(LtiClaims.roles, ['PRIVATE_VALUE', 7]),
  };
  for (final entry in cases.entries) {
    test('reports ${entry.key} only to the observer', () async {
      final errors = <LtiException>[];
      final adapter = LtiShelf(
        tool: platform.tool,
        publicOrigin: Uri.parse('https://tool.example'),
        onProtocolError: errors.add,
        onResourceLaunch: (_, _) =>
            throw StateError('Invalid launch was accepted'),
      );
      final login = await platform.begin();
      final claims = platform.claims(login)
        ..[entry.value.key] = entry.value.value;
      final token = platform.sign(claims);
      final response = await adapter.handler(
        Request(
          'POST',
          Uri.parse('https://tool.example/lti/launch'),
          headers: {
            'content-type': 'application/x-www-form-urlencoded',
            'cookie': '__Host-lti-${login.state}=${login.browserBinding}',
          },
          body: Uri(queryParameters: {'state': login.state, 'id_token': token})
              .query,
        ),
      );
      expect(response.statusCode, 401);
      expect(
        await response.readAsString(),
        'LTI request rejected: invalidClaims',
      );
      expect(response.headers['set-cookie'], contains('Max-Age=0'));
      expect(errors.single.code, LtiErrorCode.invalidClaims);
      expect(errors.single.message, entry.key);
      expect(errors.single.toString(), isNot(contains('PRIVATE_VALUE')));
      expect(errors.single.toString(), isNot(contains(token)));
      await expectLater(
        platform.complete(login),
        throwsA(
          isA<LtiException>().having(
            (e) => e.code,
            'code',
            LtiErrorCode.invalidState,
          ),
        ),
      );
    });
  }
}
