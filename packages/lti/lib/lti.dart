/// @docImport 'src/models.dart';
/// @docImport 'src/store.dart';
/// @docImport 'src/tool.dart';
/// @docImport 'src/jwks.dart';
/// @docImport 'src/signing.dart';
/// @docImport 'src/deep_linking.dart';
/// @docImport 'src/services.dart';
///
/// Server-side LTI 1.3 tool implementation with LTI Advantage services.
///
/// Start with [LtiRegistration], trusted [LtiRegistrationStore] and atomic
/// [LtiTransactionStore] implementations, then construct [LtiTool] with a
/// [RemoteJwksVerifier]. Bind each login to the initiating browser before
/// completing it. A verified [LtiLaunch] still needs application authorization.
///
/// Use [LtiJwtSigner] for tool signatures, [LtiContentItem] for Deep Linking,
/// and [LtiServiceClient] for AGS/NRPS. Service destinations must be allowlisted
/// independently of launch claims. Keep signing keys, bearer tokens and login
/// bindings on the server. Memory stores are intended for a single process;
/// production hosts own durable state, user sessions and authorization.
///
/// For an HTTP adapter, use the separate `lti_shelf` package.
library;

export 'src/errors.dart';
export 'src/jwks.dart';
export 'src/models.dart'
    show
        LtiClaims,
        LtiRegistration,
        LtiLoginRequest,
        LtiLoginRedirect,
        LtiUser,
        LtiResourceLink,
        LtiContext,
        LtiPlatformInstance,
        LtiLaunchPresentation,
        LtiDocumentTarget,
        LtiLis;
export 'src/store.dart'
    show
        LtiRegistrationStore,
        MemoryLtiRegistrationStore,
        LtiLoginTransaction,
        LtiTransactionStore,
        MemoryLtiTransactionStore;
export 'src/tool.dart';
export 'src/vocabularies.dart';
export 'src/signing.dart';
export 'src/deep_linking.dart';

export 'src/oauth.dart';

export 'src/service_models.dart'
    show
        LtiServiceScopes,
        LtiServiceClaims,
        LtiAgsEndpoints,
        LtiNrpsEndpoint,
        LtiLineItem,
        LtiScore,
        LtiActivityProgress,
        LtiGradingProgress,
        LtiResult,
        LtiMember,
        LtiMemberField,
        LtiMembershipStatus,
        LtiServicePage;
export 'src/services.dart';
