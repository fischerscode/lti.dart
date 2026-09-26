import 'package:lti/lti.dart';
import 'package:test/test.dart';

import 'support/platform.dart';

void main() {
  late TestPlatform platform;
  setUp(() => platform = TestPlatform());
  tearDown(() => platform.client.close());

  for (final canonical in LtiContextTypes.standard) {
    final name = Uri.parse(canonical).fragment;
    for (final wire in [
      canonical,
      name,
      'urn:lti:context-type:ims/lis/$name',
    ]) {
      test('normalizes $wire while retaining signed claims', () async {
        final login = await platform.begin();
        final rawTypes = [wire, 'https://vendor.example/context'];
        final claims = platform.claims(login)
          ..[LtiClaims.context] = {'id': 'course', 'type': rawTypes};
        final launch = await platform.complete(login, claims: claims);
        expect(launch.context!.types, [
          canonical,
          'https://vendor.example/context',
        ]);
        expect((launch.claims[LtiClaims.context]! as Map)['type'], rawTypes);
        expect(
          () => launch.context!.types.add('other'),
          throwsUnsupportedError,
        );
      });
    }
  }

  test(
    'accepts a Moodle-style context in a verified Deep Linking request',
    () async {
      final login = await platform.begin();
      final claims = platform.claims(login)
        ..[LtiClaims.messageType] = 'LtiDeepLinkingRequest'
        ..remove(LtiClaims.resourceLink)
        ..[LtiClaims.context] = {
          'id': 'course',
          'type': ['CourseSection'],
        }
        ..[LtiDeepLinkingClaims.settings] = {
          'deep_link_return_url': 'https://platform.example/return',
          'accept_types': ['ltiResourceLink'],
          'accept_presentation_document_targets': ['window'],
        };
      final launch = await platform.tool.completeLaunch(
        state: login.state,
        browserBinding: login.browserBinding,
        idToken: platform.sign(claims),
      );
      expect(launch, isA<LtiDeepLinkingLaunch>());
      expect(launch.context!.types, [LtiContextTypes.courseSection]);
    },
  );

  for (final types in [
    ['coursesection'],
    ['CourseSection', 'InventedType'],
    ['urn:lti:context-type:ims/lis/InventedType'],
    ['https://vendor.example/OnlyCustom'],
  ]) {
    test('still rejects unrecognized context vocabulary: $types', () async {
      final login = await platform.begin();
      await expectLater(
        platform.complete(
          login,
          claims: platform.claims(login)
            ..[LtiClaims.context] = {'id': 'course', 'type': types},
        ),
        throwsA(
          isA<LtiException>().having(
            (e) => e.code,
            'code',
            LtiErrorCode.invalidClaims,
          ),
        ),
      );
    });
  }
}
