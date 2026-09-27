/// LTI 1.3 Appendix A vocabularies. URI values are case-sensitive.
/// Legacy context names can be explicitly normalized for service responses.
abstract final class LtiRoles {
  /// Namespace prefix for standard context-role URIs.
  static const membership = 'http://purl.imsglobal.org/vocab/lis/v2/membership';

  /// Standard context role for a teacher or instructor.
  static const instructor = '$membership#Instructor';

  /// Standard context role for a learner.
  static const learner = '$membership#Learner';

  /// Standard context role for a mentor.
  static const mentor = '$membership#Mentor';

  /// Standard LTI system role identifying a platform test user.
  static const testUser =
      'http://purl.imsglobal.org/vocab/lti/system/person#TestUser';

  /// Immutable set of supported standard system, institution and context roles.
  static final Set<String> standard = Set.unmodifiable({
    for (final role in [
      'Administrator',
      'None',
      'AccountAdmin',
      'Creator',
      'SysAdmin',
      'SysSupport',
      'User',
    ])
      'http://purl.imsglobal.org/vocab/lis/v2/system/person#$role',
    for (final role in [
      'Administrator',
      'Faculty',
      'Guest',
      'None',
      'Other',
      'Staff',
      'Student',
      'Alumni',
      'Instructor',
      'Learner',
      'Member',
      'Mentor',
      'Observer',
      'ProspectiveStudent',
    ])
      'http://purl.imsglobal.org/vocab/lis/v2/institution/person#$role',
    for (final role in _subRoles.keys) '$membership#$role',
    for (final entry in _subRoles.entries)
      for (final subRole in entry.value) '$membership/${entry.key}#$subRole',
    testUser,
  });

  /// Whether [role] is an exact standard URI, including defined sub-roles.
  /// Unknown extension roles and short names return false; this is not an
  /// application authorization decision.
  static bool isStandard(String role) => standard.contains(role);

  /// Recognize only the eight deprecated context role names in Core A.2.3.
  /// Matching is case-sensitive; unknown names and extension URIs are preserved.
  static String normalizeContextRole(String role) =>
      _subRoles.containsKey(role) ? '$membership#$role' : role;

  static const _subRoles = {
    'Administrator': [
      'Administrator',
      'Developer',
      'ExternalDeveloper',
      'ExternalSupport',
      'ExternalSystemAdministrator',
      'Support',
      'SystemAdministrator',
    ],
    'ContentDeveloper': [
      'ContentDeveloper',
      'ContentExpert',
      'ExternalContentExpert',
      'Librarian',
    ],
    'Instructor': [
      'ExternalInstructor',
      'Grader',
      'GuestInstructor',
      'Lecturer',
      'PrimaryInstructor',
      'SecondaryInstructor',
      'TeachingAssistant',
      'TeachingAssistantGroup',
      'TeachingAssistantOffering',
      'TeachingAssistantSection',
      'TeachingAssistantSectionAssociation',
      'TeachingAssistantTemplate',
    ],
    'Learner': [
      'ExternalLearner',
      'GuestLearner',
      'Instructor',
      'Learner',
      'NonCreditLearner',
    ],
    'Manager': [
      'AreaManager',
      'CourseCoordinator',
      'ExternalObserver',
      'Manager',
      'Observer',
    ],
    'Member': ['Member'],
    'Mentor': [
      'Advisor',
      'Auditor',
      'ExternalAdvisor',
      'ExternalAuditor',
      'ExternalLearningFacilitator',
      'ExternalMentor',
      'ExternalReviewer',
      'ExternalTutor',
      'LearningFacilitator',
      'Mentor',
      'Reviewer',
      'Tutor',
    ],
    'Officer': [
      'Chair',
      'Communications',
      'Secretary',
      'Treasurer',
      'Vice-Chair',
    ],
  };
}

/// Standard context type URIs and narrowly defined legacy aliases.
abstract final class LtiContextTypes {
  /// Normalize only the deprecated context aliases listed in Core Appendix A.1.
  /// Unknown extension URIs are preserved; arbitrary short names are not mapped.
  static String normalize(String type) => _legacyAliases[type] ?? type;

  static const _legacyAliases = {
    'CourseTemplate': courseTemplate,
    'CourseOffering': courseOffering,
    'CourseSection': courseSection,
    'Group': group,
    'urn:lti:context-type:ims/lis/CourseTemplate': courseTemplate,
    'urn:lti:context-type:ims/lis/CourseOffering': courseOffering,
    'urn:lti:context-type:ims/lis/CourseSection': courseSection,
    'urn:lti:context-type:ims/lis/Group': group,
  };

  /// Standard type URI for a reusable course template.
  static const courseTemplate =
      'http://purl.imsglobal.org/vocab/lis/v2/course#CourseTemplate';

  /// Standard type URI for a particular offering of a course.
  static const courseOffering =
      'http://purl.imsglobal.org/vocab/lis/v2/course#CourseOffering';

  /// Standard type URI for a course section.
  static const courseSection =
      'http://purl.imsglobal.org/vocab/lis/v2/course#CourseSection';

  /// Standard type URI for a group context.
  static const group = 'http://purl.imsglobal.org/vocab/lis/v2/course#Group';

  /// The four standard context type URIs accepted by launch validation.
  static const standard = {
    courseTemplate,
    courseOffering,
    courseSection,
    group,
  };
}
