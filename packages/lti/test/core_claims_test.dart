import 'package:lti/lti.dart';
import 'package:test/test.dart';

import 'support/platform.dart';

void main() {
  late TestPlatform platform;
  setUp(() => platform = TestPlatform());
  tearDown(() => platform.client.close());
  final invalidClaims = throwsA(
    isA<LtiException>().having(
      (e) => e.code,
      'code',
      LtiErrorCode.invalidClaims,
    ),
  );

  test('rejects untrusted extra audiences even with correct azp', () async {
    final login = await platform.begin();
    await expectLater(
      platform.complete(
        login,
        claims: platform.claims(login)
          ..['aud'] = ['client', 'untrusted']
          ..['azp'] = 'client',
      ),
      invalidClaims,
    );
  });

  test(
    'parses optional metadata and retains unknown nested extensions',
    () async {
      final login = await platform.begin();
      final claims = platform.claims(login)
        ..['given_name'] = 'Example'
        ..['family_name'] = 'Student'
        ..['locale'] = 'de-DE'
        ..[LtiClaims.roles] = [
          LtiRoles.mentor,
          LtiRoles.testUser,
          'https://vendor.example/Observer',
        ]
        ..[LtiClaims.roleScopeMentor] = ['student-1', 'student-2']
        ..[LtiClaims.toolPlatform] = {
          'guid': 'instance',
          'name': 'Example LMS',
          'url': 'https://platform.example/',
          'contact_email': 'admin@example.test',
          'description': 'Test platform',
          'product_family_code': 'example',
          'version': '1',
          'extension': {'value': true},
        }
        ..[LtiClaims.launchPresentation] = {
          'document_target': 'iframe',
          'height': 600,
          'width': 800.0,
          'locale': 'de-DE',
          'return_url':
              'https://platform.example/course?keep=1&keep=2#activity',
        }
        ..[LtiClaims.lis] = {
          'person_sourcedid': 'sis-user',
          'course_offering_sourcedid': 'offering',
          'course_section_sourcedid': 'section',
        }
        ..[LtiClaims.context] = {
          'id': 'course',
          'type': [
            LtiContextTypes.courseOffering,
            'https://vendor.example/Seminar',
          ],
        };
      final launch = await platform.complete(login, claims: claims);
      expect(launch.user!.givenName, 'Example');
      expect(launch.user!.familyName, 'Student');
      expect(launch.user!.locale, 'de-DE');
      expect(launch.platform!.guid, 'instance');
      expect(launch.platform!.url, Uri.parse('https://platform.example/'));
      expect(launch.platform!.productFamilyCode, 'example');
      expect(launch.presentation!.documentTarget, LtiDocumentTarget.iframe);
      expect(launch.presentation!.height, 600);
      expect(launch.presentation!.width, 800);
      final returnUri = launch.presentation!.returnUri(
        message: 'Saved + done',
        errorLog: 'code=example',
      )!;
      expect(returnUri.queryParametersAll['keep'], ['1', '2']);
      expect(returnUri.queryParameters['lti_msg'], 'Saved + done');
      expect(returnUri.queryParameters['lti_errorlog'], 'code=example');
      expect(returnUri.fragment, 'activity');
      expect(launch.lis!.personSourcedId, 'sis-user');
      expect(launch.lis!.courseOfferingSourcedId, 'offering');
      expect(launch.lis!.courseSectionSourcedId, 'section');
      expect(launch.mentorSubjectIds, ['student-1', 'student-2']);
      expect(
        () => launch.mentorSubjectIds.add('other'),
        throwsUnsupportedError,
      );
      expect((launch.claims[LtiClaims.toolPlatform]! as Map)['extension'], {
        'value': true,
      });
    },
  );

  test(
    'optional claims may be absent; custom substitutions stay opaque',
    () async {
      final login = await platform.begin();
      final launch = await platform.complete(
        login,
        claims: platform.claims(login)
          ..remove(LtiClaims.context)
          ..[LtiClaims.custom] = {
            'empty': '',
            'unresolved': r'$CourseSection.timeFrame.begin',
          },
      );
      expect(launch.platform, isNull);
      expect(launch.presentation, isNull);
      expect(launch.lis, isNull);
      expect(launch.context, isNull);
      expect(launch.custom['empty'], '');
      expect(launch.custom['unresolved'], r'$CourseSection.timeFrame.begin');
    },
  );

  test(
    'recognizes principal, non-core, sub- and system/institution roles',
    () async {
      for (final role in [
        LtiRoles.instructor,
        '${LtiRoles.membership}#Officer',
        '${LtiRoles.membership}/Instructor#TeachingAssistant',
        'http://purl.imsglobal.org/vocab/lis/v2/system/person#SysAdmin',
        'http://purl.imsglobal.org/vocab/lis/v2/institution/person#Student',
      ]) {
        final login = await platform.begin();
        final launch = await platform.complete(
          login,
          claims: platform.claims(login)..[LtiClaims.roles] = [role],
        );
        expect(launch.roles, [role]);
      }
    },
  );

  final invalid = <String, List<Object?>>{
    LtiClaims.roles: [
      ['https://vendor.example/OnlyCustom'],
      ['${LtiRoles.membership}#invented'],
      ['Instructor'],
    ],
    LtiClaims.context: [
      null,
      {'id': 'c', 'type': <String>[]},
      {
        'id': 'c',
        'type': ['https://vendor.example/OnlyCustom'],
      },
    ],
    LtiClaims.toolPlatform: [
      null,
      {},
      {'guid': 'x' * 256},
      {'guid': 'é'},
      {'guid': 'ok', 'url': 'http://platform.example'},
    ],
    LtiClaims.launchPresentation: [
      null,
      {'document_target': 'popup'},
      {'height': '600'},
      {'width': -1},
      {'width': 1.5},
      {'return_url': '/relative'},
      {'return_url': 'javascript:alert(1)'},
    ],
    LtiClaims.lis: [
      null,
      {'person_sourcedid': 123},
    ],
    LtiClaims.roleScopeMentor: [
      null,
      ['student'],
    ],
    LtiClaims.custom: [
      null,
      {'value': null},
    ],
  };
  for (final entry in invalid.entries) {
    for (var i = 0; i < entry.value.length; i++) {
      test('rejects malformed ${entry.key} case $i', () async {
        final login = await platform.begin();
        await expectLater(
          platform.complete(
            login,
            claims: platform.claims(login)..[entry.key] = entry.value[i],
          ),
          invalidClaims,
        );
      });
    }
  }

  test('empty mentor scope is allowed without extra grants', () async {
    final login = await platform.begin();
    final launch = await platform.complete(
      login,
      claims: platform.claims(login)..[LtiClaims.roleScopeMentor] = <String>[],
    );
    expect(launch.mentorSubjectIds, isEmpty);
  });
}
