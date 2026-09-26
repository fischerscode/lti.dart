/// LTI 1.3 Appendix A vocabularies. URI values are case-sensitive.
/// Deprecated simple names and URNs are deliberately not normalized.
abstract final class LtiRoles {
  static const membership = 'http://purl.imsglobal.org/vocab/lis/v2/membership';
  static const instructor = '$membership#Instructor';
  static const learner = '$membership#Learner';
  static const mentor = '$membership#Mentor';
  static const testUser =
      'http://purl.imsglobal.org/vocab/lti/system/person#TestUser';

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

  static bool isStandard(String role) => standard.contains(role);

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

  static const courseTemplate =
      'http://purl.imsglobal.org/vocab/lis/v2/course#CourseTemplate';
  static const courseOffering =
      'http://purl.imsglobal.org/vocab/lis/v2/course#CourseOffering';
  static const courseSection =
      'http://purl.imsglobal.org/vocab/lis/v2/course#CourseSection';
  static const group = 'http://purl.imsglobal.org/vocab/lis/v2/course#Group';
  static const standard = {
    courseTemplate,
    courseOffering,
    courseSection,
    group,
  };
}
